/**
 * Pull free-text search intent from a navigation URL.
 * Prefer query params from known engines; fall back to generic ?q= style params.
 */

const SEARCH_PARAM_KEYS = [
  "q",
  "query",
  "p",
  "text",
  "wd",
  "search_query",
  "search",
  "k",
  "keyword",
  "keywords",
  "terms",
];

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
  { host: "youtube.com", params: ["search_query", "q"] },
  { host: "reddit.com", params: ["q"] },
  { host: "twitter.com", params: ["q"] },
  { host: "x.com", params: ["q"] },
  { host: "amazon.", params: ["k", "field-keywords"] },
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
    if (host.includes(eng.host) || host.endsWith(eng.host.replace(/^\./, ""))) {
      for (const key of eng.params) {
        const v = u.searchParams.get(key);
        if (v && v.trim()) {
          return { query: v.trim(), source: `${host}:${key}` };
        }
      }
    }
  }

  // Generic fallback: common search param names on any host.
  for (const key of SEARCH_PARAM_KEYS) {
    const v = u.searchParams.get(key);
    if (v && v.trim() && v.trim().length >= 2) {
      return { query: v.trim(), source: `${host}:${key}` };
    }
  }

  return null;
}

/**
 * Lightweight keyword bag from path when there is no search box query.
 * Only used when path looks like free text (rare); mostly search params matter.
 * @param {string} urlString
 * @returns {string}
 */
export function extractUrlKeywords(urlString) {
  try {
    const u = new URL(urlString);
    const parts = decodeURIComponent(u.pathname)
      .split(/[\/_\-+.]+/)
      .filter((p) => p.length > 2 && !/^\d+$/.test(p) && !/^(www|com|org|net|html|php|aspx)$/i.test(p));
    // Avoid classifying every path segment on normal sites — only if several words.
    if (parts.length >= 2 && parts.join(" ").length >= 8) {
      return parts.slice(0, 12).join(" ");
    }
  } catch {
    /* ignore */
  }
  return "";
}
