function setStatus(el, ok, text) {
  const cls = ok === true ? "ok" : ok === false ? "bad" : "warn";
  el.innerHTML = '<span class="dot ' + cls + '"></span>' + text;
}

function setApiRow(apiStatus) {
  const apiEl = document.getElementById("api");
  if (!apiStatus) {
    setStatus(apiEl, null, "unknown");
    return;
  }
  if (apiStatus.ok) {
    setStatus(apiEl, true, "online");
  } else {
    setStatus(apiEl, false, "offline");
  }
}

function refresh() {
  chrome.runtime.sendMessage({ type: "status" }, (s) => {
    if (chrome.runtime.lastError) {
      document.getElementById("list").textContent =
        chrome.runtime.lastError.message;
      return;
    }
    const listEl = document.getElementById("list");
    if (s.listReady) {
      setStatus(
        listEl,
        true,
        "ready · " + s.listCount.toLocaleString()
      );
    } else {
      setStatus(listEl, false, "not loaded");
    }

    setApiRow(s.apiStatus);

    const lvl = s.proxy?.levelOfControl || "unknown";
    const proxyEl = document.getElementById("proxy");
    if (lvl === "controlled_by_other_extensions") {
      setStatus(proxyEl, null, "other extension");
    } else if (lvl === "controlled_by_this_extension") {
      setStatus(proxyEl, true, "active");
    } else {
      setStatus(proxyEl, true, "ok");
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
