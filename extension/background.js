/**
 * Browser-layer domain blocker.
 *
 * Why this exists: system DNS (filterd) never sees traffic that a browser VPN
 * extension tunnels through a remote proxy. The destination URL is still
 * visible to extensions, so we cancel / redirect those navigations here.
 */

const BLOCK_PAGE = chrome.runtime.getURL("blocked.html");
const LIST_URL = chrome.runtime.getURL("nsfw.txt");

/** @type {Set<string>} */
let blocked = new Set();
let listReady = false;
let listCount = 0;
let loadError = "";

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
  // Walk parents: a.b.example.com → a.b.example.com, b.example.com, example.com
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
    console.log(`[domain-guard] loaded ${listCount} blocked domains`);
  } catch (err) {
    loadError = String(err?.message || err);
    listReady = false;
    await chrome.storage.session.set({
      listCount: 0,
      listReady: false,
      loadError,
    });
    console.error("[domain-guard] list load failed:", loadError);
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

function redirectToBlock(tabId, host, url) {
  const dest =
    BLOCK_PAGE +
    "?host=" +
    encodeURIComponent(host) +
    "&from=" +
    encodeURIComponent(url);
  chrome.tabs.update(tabId, { url: dest }).catch(() => {});
}

// Main navigations (address bar, links, redirects).
chrome.webNavigation.onBeforeNavigate.addListener((details) => {
  if (!listReady) return;
  if (details.frameId !== 0) return; // top-level only; subframes handled below optionally
  if (shouldIgnoreUrl(details.url)) return;

  const host = hostFromUrl(details.url);
  if (!host) return;
  if (!isBlockedHost(host)) return;

  console.log(`[domain-guard] BLOCK navigation ${host} (tab ${details.tabId})`);
  redirectToBlock(details.tabId, host, details.url);
});

// Some SPA / extension navigations skip onBeforeNavigate timing; catch committed main-frame loads.
chrome.webNavigation.onCommitted.addListener((details) => {
  if (!listReady) return;
  if (details.frameId !== 0) return;
  if (shouldIgnoreUrl(details.url)) return;

  const host = hostFromUrl(details.url);
  if (!host || !isBlockedHost(host)) return;

  console.log(`[domain-guard] BLOCK committed ${host}`);
  redirectToBlock(details.tabId, host, details.url);
});

// Popup / status messaging
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === "status") {
    chrome.proxy.settings.get({}, (config) => {
      sendResponse({
        listReady,
        listCount,
        loadError,
        proxy: config || null,
      });
    });
    return true; // async
  }
  if (msg?.type === "check") {
    sendResponse({ blocked: isBlockedHost(msg.host || ""), host: msg.host });
    return false;
  }
  if (msg?.type === "reload") {
    loadBlocklist().then(() => sendResponse({ ok: true, listCount, loadError }));
    return true;
  }
  return false;
});

chrome.runtime.onInstalled.addListener(() => {
  loadBlocklist();
});

chrome.runtime.onStartup.addListener(() => {
  loadBlocklist();
});

// Periodic reload in case list file was updated after sync
chrome.alarms.create("reload-list", { periodInMinutes: 60 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "reload-list") loadBlocklist();
});

loadBlocklist();
