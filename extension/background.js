/**
 * EasyPeasy Content Guard — service worker.
 *
 * Layers:
 *  1) Domain blocklist (nsfw.txt) — instant URL host match
 *  2) Text / search-query classifier via local ML API
 *  3) Image classification proxy for the content script
 */

import { extractSearchQuery } from "./lib/search-extract.js";
import { API_BASE, classifyText, classifyImage, healthCheck } from "./lib/api.js";

const BLOCK_PAGE = chrome.runtime.getURL("blocked.html");
const LIST_URL = chrome.runtime.getURL("nsfw.txt");

/** Only "Normal" images are kept (user request). */
const ALLOWED_IMAGE_LABELS = new Set(["Normal"]);

/** Text labels that trigger a block. */
const BLOCK_TEXT_LABELS = new Set(["nsfw"]);

/** Min score to trust a text NSFW prediction. */
const TEXT_NSFW_MIN_SCORE = 0.55;

/** @type {Set<string>} */
let blocked = new Set();
let listReady = false;
let listCount = 0;
let loadError = "";

/** @type {{ ok: boolean, detail?: string, checkedAt: number }} */
let apiStatus = { ok: false, detail: "not checked", checkedAt: 0 };

/** In-memory text decisions: query → { nsfw, score, label } */
const textDecisionCache = new Map();

/** tabId → last classified query (avoid re-block loops) */
const pendingTextJobs = new Map();

// ── Domain list (unchanged semantics) ──────────────────────────────────────

function normalizeHost(host) {
  if (!host) return "";
  return host.trim().toLowerCase().replace(/^\.+|\.+$/g, "");
}

function parseListLine(line) {
  line = line.trim();
  if (!line || line[0] === "!" || line[0] === "[" || line[0] === "#") {
    return "";
  }
  if (line.startsWith("||")) {
    let rest = line.slice(2);
    for (const sep of ["^", "$", "/", "*"]) {
      const i = rest.indexOf(sep);
      if (i === 0 && sep === "*") continue;
      if (i >= 0) {
        rest = rest.slice(0, i);
        break;
      }
    }
    rest = rest.split(/\s/)[0] || "";
    if (rest.startsWith("*.")) rest = rest.slice(2);
    return normalizeHost(rest);
  }
  const fields = line.split(/\s+/);
  if (
    fields.length >= 2 &&
    (fields[0] === "0.0.0.0" || fields[0] === "127.0.0.1")
  ) {
    return normalizeHost(fields[1]);
  }
  if (fields.length === 1 && fields[0].includes(".")) {
    return normalizeHost(fields[0]);
  }
  return "";
}

function isBlockedHost(host) {
  host = normalizeHost(host);
  if (!host || !listReady) return false;
  for (;;) {
    if (blocked.has(host)) return true;
    const i = host.indexOf(".");
    if (i < 0) return false;
    host = host.slice(i + 1);
    if (!host) return false;
  }
}

function hostFromUrl(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return "";
    return normalizeHost(u.hostname);
  } catch {
    return "";
  }
}

async function loadBlocklist() {
  listReady = false;
  loadError = "";
  try {
    const res = await fetch(LIST_URL);
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} loading nsfw.txt — run scripts/sync-list.ps1`);
    }
    const text = await res.text();
    const next = new Set();
    for (const line of text.split(/\r?\n/)) {
      const d = parseListLine(line);
      if (d) next.add(d);
    }
    blocked = next;
    listCount = next.size;
    listReady = true;
    await chrome.storage.session.set({
      listCount,
      listReady: true,
      loadError: "",
      loadedAt: Date.now(),
    });
    console.log(`[content-guard] loaded ${listCount} blocked domains`);
  } catch (err) {
    loadError = String(err?.message || err);
    listReady = false;
    await chrome.storage.session.set({
      listCount: 0,
      listReady: false,
      loadError,
    });
    console.error("[content-guard] list load failed:", loadError);
  }
}

function shouldIgnoreUrl(url) {
  if (!url) return true;
  if (url.startsWith(BLOCK_PAGE)) return true;
  if (url.startsWith("chrome://") || url.startsWith("chrome-extension://")) return true;
  if (url.startsWith("edge://") || url.startsWith("about:")) return true;
  if (url.startsWith("devtools://") || url.startsWith("moz-extension://")) return true;
  return false;
}

/**
 * @param {number} tabId
 * @param {object} opts
 */
function redirectToBlock(tabId, opts) {
  const params = new URLSearchParams();
  if (opts.host) params.set("host", opts.host);
  if (opts.from) params.set("from", opts.from);
  if (opts.reason) params.set("reason", opts.reason);
  if (opts.detail) params.set("detail", opts.detail);
  if (opts.score != null) params.set("score", String(opts.score));
  const dest = BLOCK_PAGE + "?" + params.toString();
  chrome.tabs.update(tabId, { url: dest }).catch(() => {});
}

// ── Local API health ───────────────────────────────────────────────────────

async function refreshApiStatus() {
  try {
    const h = await healthCheck();
    apiStatus = {
      ok: !!h.ok,
      detail: h.ok
        ? `API up · text=${h.text_device || "?"} · image=${h.image_device || "?"}`
        : "API unhealthy",
      checkedAt: Date.now(),
      raw: h,
    };
  } catch (err) {
    apiStatus = {
      ok: false,
      detail: String(err?.message || err),
      checkedAt: Date.now(),
    };
  }
  await chrome.storage.session.set({ apiStatus });
  return apiStatus;
}

// ── Text / search classification ───────────────────────────────────────────

/**
 * @param {string} query
 * @returns {Promise<{nsfw: boolean, label: string, score: number}>}
 */
async function decideText(query) {
  const key = query.toLowerCase().trim();
  if (textDecisionCache.has(key)) {
    return textDecisionCache.get(key);
  }

  const result = await classifyText(query);
  const label = String(result.label || "").toLowerCase();
  const score = Number(result.score) || 0;
  const nsfw =
    BLOCK_TEXT_LABELS.has(label) && score >= TEXT_NSFW_MIN_SCORE;

  const decision = { nsfw, label, score };
  textDecisionCache.set(key, decision);
  if (textDecisionCache.size > 500) {
    const first = textDecisionCache.keys().next().value;
    textDecisionCache.delete(first);
  }
  return decision;
}

/**
 * Extract search text from URL and block the tab if classifier says NSFW.
 * @param {number} tabId
 * @param {string} url
 */
async function maybeBlockBySearchText(tabId, url) {
  const extracted = extractSearchQuery(url);
  if (!extracted) return;

  const { query, source } = extracted;
  if (query.length < 2) return;

  // Deduplicate in-flight jobs for same tab+query.
  const jobKey = `${tabId}:${query.toLowerCase()}`;
  if (pendingTextJobs.get(tabId) === jobKey) return;
  pendingTextJobs.set(tabId, jobKey);

  try {
    // Fast path: cache
    const cached = textDecisionCache.get(query.toLowerCase().trim());
    if (cached?.nsfw) {
      console.log(`[content-guard] TEXT BLOCK (cache) "${query}"`);
      redirectToBlock(tabId, {
        host: hostFromUrl(url) || "search",
        from: url,
        reason: "text",
        detail: query,
        score: cached.score,
      });
      return;
    }

    if (!apiStatus.ok) {
      // Best-effort health; still try classify (user may have just started API).
      await refreshApiStatus();
    }

    const decision = await decideText(query);
    console.log(
      `[content-guard] text classify "${query}" → ${decision.label} (${decision.score.toFixed(3)}) via ${source}`
    );

    if (decision.nsfw) {
      redirectToBlock(tabId, {
        host: hostFromUrl(url) || "search",
        from: url,
        reason: "text",
        detail: query,
        score: decision.score,
      });
    }
  } catch (err) {
    console.warn("[content-guard] text classify failed:", err?.message || err);
    // Fail-open on API errors so browsing is not bricked.
  } finally {
    if (pendingTextJobs.get(tabId) === jobKey) {
      pendingTextJobs.delete(tabId);
    }
  }
}

// ── Navigation hooks ───────────────────────────────────────────────────────

function handleNavigation(details) {
  if (details.frameId !== 0) return;
  if (shouldIgnoreUrl(details.url)) return;

  const host = hostFromUrl(details.url);
  if (host && listReady && isBlockedHost(host)) {
    console.log(`[content-guard] DOMAIN BLOCK ${host} (tab ${details.tabId})`);
    redirectToBlock(details.tabId, {
      host,
      from: details.url,
      reason: "domain",
      detail: host,
    });
    return;
  }

  // Search / query text layer (async — may redirect shortly after load starts).
  maybeBlockBySearchText(details.tabId, details.url);
}

chrome.webNavigation.onBeforeNavigate.addListener(handleNavigation);
chrome.webNavigation.onCommitted.addListener(handleNavigation);

// ── Messaging (popup + content script) ─────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg?.type === "status") {
    chrome.proxy.settings.get({}, (config) => {
      sendResponse({
        listReady,
        listCount,
        loadError,
        proxy: config || null,
        apiStatus,
        apiBase: API_BASE,
        allowedImageLabels: [...ALLOWED_IMAGE_LABELS],
      });
    });
    return true;
  }

  if (msg?.type === "check") {
    sendResponse({ blocked: isBlockedHost(msg.host || ""), host: msg.host });
    return false;
  }

  if (msg?.type === "reload") {
    Promise.all([loadBlocklist(), refreshApiStatus()]).then(() =>
      sendResponse({ ok: true, listCount, loadError, apiStatus })
    );
    return true;
  }

  if (msg?.type === "ping-api") {
    refreshApiStatus().then((s) => sendResponse(s));
    return true;
  }

  if (msg?.type === "classify-image") {
    const { url, image_b64 } = msg;
    (async () => {
      try {
        const result = await classifyImage({ url, image_b64 });
        // Soft-fail from API: { ok:false, keep:true, error:"..." }
        if (result && result.ok === false) {
          sendResponse({
            ok: false,
            error: result.error || "classify soft-fail",
            keep: true,
            label: result.label || "error",
          });
          return;
        }
        const label = result.label || "";
        const keep = ALLOWED_IMAGE_LABELS.has(label);
        sendResponse({
          ok: true,
          label,
          score: result.score,
          keep,
          scores: result.scores,
          ms: result.ms,
          cached: result.cached,
        });
      } catch (err) {
        sendResponse({
          ok: false,
          error: String(err?.message || err),
          // Fail-open: keep image if classifier is down.
          keep: true,
        });
      }
    })();
    return true;
  }

  if (msg?.type === "classify-text") {
    (async () => {
      try {
        const decision = await decideText(msg.text || "");
        sendResponse({ ok: true, ...decision });
      } catch (err) {
        sendResponse({ ok: false, error: String(err?.message || err), nsfw: false });
      }
    })();
    return true;
  }

  return false;
});

chrome.runtime.onInstalled.addListener(() => {
  loadBlocklist();
  refreshApiStatus();
});

chrome.runtime.onStartup.addListener(() => {
  loadBlocklist();
  refreshApiStatus();
});

chrome.alarms.create("reload-list", { periodInMinutes: 60 });
chrome.alarms.create("ping-api", { periodInMinutes: 2 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "reload-list") loadBlocklist();
  if (a.name === "ping-api") refreshApiStatus();
});

loadBlocklist();
refreshApiStatus();
