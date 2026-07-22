/**
 * Pull free-text search intent from a navigation URL.
 * Only known search engines — never generic ?q= on every site (that was
 * hijacking normal links that happen to use q/search/text params).
 */

/** Host suffixes → preferred param order (first hit wins). */
const ENGINE_PARAMS = [
  { host: "google.", params: ["q", "query"] },
  { host: "bing.com", params: ["q"] },
  { host: "duckduckgo.com", params: ["q"] },
  { host: "yahoo.", params: ["p", "q"] },
  { host: "yandex.", params: ["text", "q"] },
  { host: "baidu.com", params: ["wd", "word"] },
  { host: "ecosia.org", params: ["q"] },
  { host: "search.brave.com", params: ["q"] },
  { host: "startpage.com", params: ["query", "q"] },
  { host: "youtube.com", params: ["search_query"] }, // not plain ?q= watch URLs
  { host: "www.youtube.com", params: ["search_query"] },
];

/**
 * @param {string} urlString
 * @returns {{ query: string, source: string } | null}
 */
export function extractSearchQuery(urlString) {
  let u;
  try {
    u = new URL(urlString);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;

  const host = u.hostname.toLowerCase();

  for (const eng of ENGINE_PARAMS) {
    const needle = eng.host.replace(/^\./, "");
    if (host === needle || host.endsWith("." + needle) || host.includes(needle)) {
      // YouTube: only /results search pages, not every watch URL.
      if (needle.includes("youtube") && !u.pathname.includes("/results")) {
        continue;
      }
      // Google: skip pure static/account hosts if they appear.
      if (needle === "google.") {
        if (
          host.startsWith("accounts.") ||
          host.startsWith("mail.") ||
          host.startsWith("drive.") ||
          host.startsWith("docs.")
        ) {
          continue;
        }
      }
      for (const key of eng.params) {
        const v = u.searchParams.get(key);
        if (v && v.trim().length >= 2) {
          return { query: v.trim(), source: `${host}:${key}` };
        }
      }
    }
  }

  // No generic ?q= fallback — too many sites use q/search for filters/nav.
  return null;
}

/**
 * @param {string} urlString
 * @returns {string}
 */
export function extractUrlKeywords(urlString) {
  // Intentionally unused for auto-block — path keywords caused false positives.
  return "";
}
