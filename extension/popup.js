function refresh() {
  chrome.runtime.sendMessage({ type: "status" }, (s) => {
    if (chrome.runtime.lastError) {
      document.getElementById("list").textContent =
        "Error: " + chrome.runtime.lastError.message;
      return;
    }
    const listEl = document.getElementById("list");
    if (s.listReady) {
      listEl.innerHTML =
        'List: <span class="ok">ready</span> (' +
        s.listCount.toLocaleString() +
        " domains)";
    } else {
      listEl.innerHTML =
        'List: <span class="bad">not loaded</span> ' +
        (s.loadError || "run scripts/sync-list.ps1");
    }

    const lvl = s.proxy?.levelOfControl || "unknown";
    const proxyEl = document.getElementById("proxy");
    if (lvl === "controlled_by_other_extensions") {
      proxyEl.innerHTML =
        'Proxy: <span class="warn">VPN/proxy extension active</span>';
      document.getElementById("hint").textContent =
        "Domain Guard still blocks by URL. Keep this extension enabled.";
    } else if (lvl === "controlled_by_this_extension") {
      proxyEl.innerHTML = 'Proxy: <span class="ok">this extension</span>';
    } else {
      proxyEl.innerHTML =
        'Proxy: <span class="ok">' + lvl.replaceAll("_", " ") + "</span>";
      document.getElementById("hint").textContent =
        "Pair with filterd run -protect for system-wide DNS.";
    }
  });
}

document.getElementById("reload").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "reload" }, () => refresh());
});

refresh();
