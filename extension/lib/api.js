/** Local classifier API client (runs in the service worker). */

export const API_BASE = "http://127.0.0.1:8765";

/**
 * @param {string} path
 * @param {RequestInit} [init]
 */
async function apiFetch(path, init = {}) {
  const res = await fetch(API_BASE + path, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const j = await res.json();
      detail = j.detail || JSON.stringify(j);
    } catch {
      /* ignore */
    }
    throw new Error(`API ${res.status}: ${detail}`);
  }
  return res.json();
}

export async function healthCheck() {
  return apiFetch("/health");
}

/**
 * @param {string} text
 * @returns {Promise<{label: string, score: number, ms?: number, cached?: boolean}>}
 */
export async function classifyText(text) {
  return apiFetch("/classify/text", {
    method: "POST",
    body: JSON.stringify({ text }),
  });
}

/**
 * @param {{ url?: string, image_b64?: string }} body
 * @returns {Promise<{label: string, score: number, scores?: object, ms?: number, cached?: boolean}>}
 */
export async function classifyImage(body) {
  return apiFetch("/classify/image", {
    method: "POST",
    body: JSON.stringify(body),
  });
}
