/**
 * Scan page images, ask the background (→ local ML API) to classify them,
 * and remove anything that is not labeled "Normal".
 *
 * Fail-open: if the API is down, images stay visible.
 */

(() => {
  const MIN_EDGE = 48; // skip icons / tracking pixels
  const MAX_CONCURRENT = 2;
  const QUEUE_CAP = 80;

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
    // Prefer currentSrc (handles srcset), then src, then data-src lazy attrs.
    const raw =
      el.currentSrc ||
      el.src ||
      el.getAttribute("data-src") ||
      el.getAttribute("data-lazy-src") ||
      el.getAttribute("data-original") ||
      "";
    if (!raw || raw.startsWith("data:image/svg")) return "";
    // Tiny 1x1 GIF / empty placeholders
    if (raw.startsWith("data:") && raw.length < 200) return "";
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

    const w = img.naturalWidth || img.width || 0;
    const h = img.naturalHeight || img.height || 0;
    // If not loaded yet, still queue if CSS size is large enough or unknown.
    if (w > 0 && h > 0 && (w < MIN_EDGE || h < MIN_EDGE)) return false;

    const src = absoluteSrc(img);
    if (!src) return false;
    if (src.startsWith("chrome-extension://")) return false;
    return true;
  }

  function removeImage(img, label) {
    img.dataset.epGuard = "removed";
    img.dataset.epLabel = label || "";
    img.style.setProperty("filter", "blur(24px)", "important");
    img.style.setProperty("visibility", "hidden", "important");
    img.style.setProperty("pointer-events", "none", "important");
    // Replace with empty transparent pixel so layout doesn't jump as much.
    try {
      img.removeAttribute("srcset");
      img.src =
        "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
      img.alt = "[image removed by Content Guard]";
    } catch {
      /* ignore */
    }
    // Also hide parent <picture> wrappers if they only hold this image.
    const pic = img.closest("picture");
    if (pic) {
      pic.style.setProperty("display", "none", "important");
    }
  }

  function markKept(img, label) {
    img.dataset.epGuard = "done";
    img.dataset.epLabel = label || "Normal";
  }

  /**
   * @param {HTMLImageElement} img
   */
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
      // Re-check still in document
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
          // Fail-open
          markKept(img, "api-error");
          return;
        }

        urlCache.set(src, { keep: !!result.keep, label: result.label });
        if (urlCache.size > 400) {
          const first = urlCache.keys().next().value;
          urlCache.delete(first);
        }

        if (result.keep) {
          markKept(img, result.label);
        } else {
          removeImage(img, result.label);
        }
      } catch {
        markKept(img, "error");
      }
    });
  }

  function scan(root = document) {
    const imgs = root.querySelectorAll ? root.querySelectorAll("img") : [];
    for (const img of imgs) {
      processImage(img);
    }
  }

  // Initial pass
  scan(document);

  // Late-loading images (lazy, SPA, infinite scroll)
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
        // Allow re-check when src changes
        const img = m.target;
        if (img.dataset.epGuard === "done" || img.dataset.epGuard === "removed") {
          delete img.dataset.epGuard;
          seen.delete(img);
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

  // Images that load after we measured 0×0 size
  document.addEventListener(
    "load",
    (ev) => {
      if (ev.target instanceof HTMLImageElement) {
        const img = ev.target;
        if (img.dataset.epGuard === "pending" || !img.dataset.epGuard) {
          if (img.dataset.epGuard === "pending") {
            delete img.dataset.epGuard;
            seen.delete(img);
          }
          processImage(img);
        }
      }
    },
    true
  );
})();
