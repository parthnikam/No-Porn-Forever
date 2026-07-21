const params = new URLSearchParams(location.search);
const host = params.get("host") || "(unknown)";
document.getElementById("host").textContent = host;

chrome.runtime.sendMessage({ type: "status" }, (status) => {
  if (chrome.runtime.lastError) return;
  const lvl = status?.proxy?.levelOfControl;
  // controlled_by_other_extensions = typical browser VPN extension
  if (
    lvl === "controlled_by_other_extensions" ||
    lvl === "controlled_by_this_extension"
  ) {
    const el = document.getElementById("proxyWarn");
    if (el) el.style.display = "block";
  }
});
