/**
 * Scan page images, classify via local ML API, and hide hard-NSFW results.
 *
 * Critical UX rules:
 *  - Never kill pointer-events (image links must stay clickable)
 *  - Never display:none parent wrappers (breaks cards / galleries)
 *  - Fail-open if the API is down
 */

(() => {
  const MIN_EDGE = 64;
  const MAX_CONCURRENT = 2;
  const QUEUE_CAP = 60;

  /** @type {WeakSet<Element>} */
  const seen = new WeakSet();
  /** @type {Map<string, { keep: boolean, label: string }>} */
  const urlCache = new Map();

  let inFlight = 0;
  /** @type {Array<() => void>} */
  const queue = [];

  function schedule(fn) {
    queue.push(fn);
    while (queue.length > QUEUE_CAP) queue.shift();
    pump();
  }

  function pump() {
    while (inFlight < MAX_CONCURRENT && queue.length) {
      const job = queue.shift();
      inFlight++;
      Promise.resolve()
        .then(job)
        .finally(() => {
          inFlight--;
          pump();
        });
    }
  }

  function absoluteSrc(el) {
    const raw =
      el.currentSrc ||
      el.src ||
      el.getAttribute("data-src") ||
      el.getAttribute("data-lazy-src") ||
      el.getAttribute("data-original") ||
      "";
    if (!raw || raw.startsWith("data:image/svg")) return "";
    if (raw.startsWith("data:") && raw.length < 200) return "";
    // Skip our own placeholder
    if (raw.startsWith("data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP")) return "";
    try {
      return new URL(raw, location.href).href;
    } catch {
      return "";
    }
  }

  function isCandidate(img) {
    if (!(img instanceof HTMLImageElement)) return false;
    if (seen.has(img)) return false;
    if (img.dataset.epGuard === "done" || img.dataset.epGuard === "pending") {
      return false;
    }
    if (img.dataset.epGuard === "removed") return false;

    const w = img.naturalWidth || img.width || 0;
    const h = img.naturalHeight || img.height || 0;
    if (w > 0 && h > 0 && (w < MIN_EDGE || h < MIN_EDGE)) return false;

    const src = absoluteSrc(img);
    if (!src) return false;
    if (src.startsWith("chrome-extension://")) return false;
    return true;
  }

  /**
   * Soft hide — keeps layout and parent <a> clickable.
   * Do NOT set pointer-events:none or display:none on parents.
   */
  function removeImage(img, label) {
    img.dataset.epGuard = "removed";
    img.dataset.epLabel = label || "";
    img.style.setProperty("filter", "blur(28px) brightness(0.35)", "important");
    img.style.setProperty("opacity", "0.35", "important");
    // Keep pointer-events so gallery / card links still work.
    img.setAttribute("alt", "");
    img.setAttribute("title", "Hidden by NoPornForever");
  }

  function markKept(img, label) {
    img.dataset.epGuard = "done";
    img.dataset.epLabel = label || "Normal";
  }

  function processImage(img) {
    if (!isCandidate(img)) return;
    seen.add(img);
    img.dataset.epGuard = "pending";

    const src = absoluteSrc(img);
    if (!src) {
      markKept(img, "skip");
      return;
    }

    if (urlCache.has(src)) {
      const c = urlCache.get(src);
      if (c.keep) markKept(img, c.label);
      else removeImage(img, c.label);
      return;
    }

    schedule(async () => {
      if (!img.isConnected) return;

      try {
        const result = await chrome.runtime.sendMessage({
          type: "classify-image",
          url: src.startsWith("data:") ? undefined : src,
          image_b64: src.startsWith("data:") ? src : undefined,
        });

        if (chrome.runtime.lastError) {
          markKept(img, "error");
          return;
        }

        if (!result || result.ok === false) {
          markKept(img, "api-error");
          return;
        }

        const keep = result.keep !== false;
        urlCache.set(src, { keep, label: result.label });
        if (urlCache.size > 400) {
          const first = urlCache.keys().next().value;
          urlCache.delete(first);
        }

        if (keep) markKept(img, result.label);
        else removeImage(img, result.label);
      } catch {
        markKept(img, "error");
      }
    });
  }

  function scan(root = document) {
    const imgs = root.querySelectorAll ? root.querySelectorAll("img") : [];
    for (const img of imgs) processImage(img);
  }

  scan(document);

  const mo = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (!(node instanceof Element)) continue;
        if (node.tagName === "IMG") processImage(node);
        else if (node.querySelectorAll) scan(node);
      }
      if (
        m.type === "attributes" &&
        m.target instanceof HTMLImageElement &&
        (m.attributeName === "src" || m.attributeName === "srcset")
      ) {
        const img = m.target;
        // Don't re-process images we already soft-hid (src may change under us).
        if (img.dataset.epGuard === "removed") return;
        if (img.dataset.epGuard === "done") {
          // Real navigation of src on a kept image — recheck.
          delete img.dataset.epGuard;
          seen.delete(img);
        } else if (img.dataset.epGuard === "pending") {
          return;
        }
        processImage(img);
      }
    }
  });

  mo.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["src", "srcset", "data-src"],
  });

  document.addEventListener(
    "load",
    (ev) => {
      if (!(ev.target instanceof HTMLImageElement)) return;
      const img = ev.target;
      if (img.dataset.epGuard === "removed" || img.dataset.epGuard === "done") {
        return;
      }
      if (img.dataset.epGuard === "pending") {
        // Size now known — leave pending job; only re-queue if never scheduled.
        return;
      }
      processImage(img);
    },
    true
  );
})();
