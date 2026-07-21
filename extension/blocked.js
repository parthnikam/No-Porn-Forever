const params = new URLSearchParams(location.search);
const host = params.get("host") || "(unknown)";
const reason = params.get("reason") || "domain";
const detail = params.get("detail") || "";
const score = params.get("score");

document.getElementById("host").textContent = host;

const reasonBadge = document.getElementById("reasonBadge");
const title = document.getElementById("title");
const message = document.getElementById("message");
const detailLine = document.getElementById("detailLine");

if (reason === "text") {
  reasonBadge.textContent = "search text";
  title.textContent = "Search blocked";
  message.textContent =
    "Your search query was classified as NSFW by the local text model, so this page was not allowed to load.";
  if (detail) {
    detailLine.style.display = "block";
    const sc = score != null ? ` (confidence ${Number(score).toFixed(2)})` : "";
    detailLine.textContent = `Query: “${detail}”${sc}`;
  }
} else if (reason === "domain") {
  reasonBadge.textContent = "domain list";
  title.textContent = "Site blocked";
  message.textContent =
    "The domain is on your local NSFW blocklist. This still applies when a VPN extension tunnels traffic past system DNS.";
  if (detail) {
    detailLine.style.display = "block";
    detailLine.textContent = `Matched host: ${detail}`;
  }
} else {
  reasonBadge.textContent = reason;
}

chrome.runtime.sendMessage({ type: "status" }, (status) => {
  if (chrome.runtime.lastError) return;
  const lvl = status?.proxy?.levelOfControl;
  if (
    lvl === "controlled_by_other_extensions" ||
    lvl === "controlled_by_this_extension"
  ) {
    const el = document.getElementById("proxyWarn");
    if (el) el.style.display = "block";
  }
});
