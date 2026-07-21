function setApiRow(apiStatus) {
  const apiEl = document.getElementById("api");
  if (!apiStatus) {
    apiEl.innerHTML = 'Classifier API: <span class="warn">unknown</span>';
    return;
  }
  if (apiStatus.ok) {
    apiEl.innerHTML =
      'Classifier API: <span class="ok">online</span> · ' +
      (apiStatus.detail || "");
  } else {
    apiEl.innerHTML =
      'Classifier API: <span class="bad">offline</span><br/>' +
      '<span class="hint">' +
      (apiStatus.detail || "start classifier-api/run.ps1") +
      "</span>";
  }
}

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

    setApiRow(s.apiStatus);

    const lvl = s.proxy?.levelOfControl || "unknown";
    const proxyEl = document.getElementById("proxy");
    if (lvl === "controlled_by_other_extensions") {
      proxyEl.innerHTML =
        'Proxy: <span class="warn">VPN/proxy extension active</span>';
      document.getElementById("hint").textContent =
        "Domain + text + image guards still run. Keep this extension enabled.";
    } else if (lvl === "controlled_by_this_extension") {
      proxyEl.innerHTML = 'Proxy: <span class="ok">this extension</span>';
    } else {
      proxyEl.innerHTML =
        'Proxy: <span class="ok">' + lvl.replaceAll("_", " ") + "</span>";
      document.getElementById("hint").textContent =
        "Text/image ML need classifier-api on :8765. Pair with filterd for system DNS.";
    }
  });
}

document.getElementById("reload").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "reload" }, () => refresh());
});

document.getElementById("ping").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "ping-api" }, (s) => {
    setApiRow(s);
    refresh();
  });
});

refresh();
