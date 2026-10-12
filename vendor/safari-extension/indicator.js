// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// indicator.js — the optional on-page "observing" marker: the official sol ring
// mark + a label, in a closed shadow root (so page CSS can't restyle or hide
// it), reflecting the paused state when the owner enables the marker.
//
// Classic content script -> publishes `globalThis.SolstoneIndicator`.

(function () {
  "use strict";

  const HOST_ID = "solstone-observer-indicator-host";
  // the official sol ring mark (gold rays + orange ring), inline so no resource fetch
  const RAYS =
    "M16 2.5 Q17.057687783 5.007810543 18.589661566 7.257449068 A9.118033989 9.118033989 0 0 0 13.410338434 7.257449068 Q14.942312217 5.007810543 16 2.5 Z M23.935100906 5.078270576 Q23.316734245 7.728825204 23.233822722 10.449292599 A9.118033989 9.118033989 0 0 0 19.043662288 7.404962845 Q21.605359462 6.485438643 23.935100906 5.078270576 Z M28.83926297 11.828270576 Q26.781036911 13.609147511 25.114909466 15.761317696 A9.118033989 9.118033989 0 0 0 23.514410599 10.83548868 Q26.127349912 11.597305794 28.83926297 11.828270576 Z M28.83926297 20.171729424 Q26.127349912 20.402694206 23.514410599 21.16451132 A9.118033989 9.118033989 0 0 0 25.114909466 16.238682304 Q26.781036911 18.390852489 28.83926297 20.171729424 Z M23.935100906 26.921729424 Q21.605359462 25.514561357 19.043662288 24.595037155 A9.118033989 9.118033989 0 0 0 23.233822722 21.550707401 Q23.316734245 24.271174796 23.935100906 26.921729424 Z M16 29.5 Q14.942312217 26.992189457 13.410338434 24.742550932 A9.118033989 9.118033989 0 0 0 18.589661566 24.742550932 Q17.057687783 26.992189457 16 29.5 Z M8.064899094 26.921729424 Q8.683265755 24.271174796 8.766177278 21.550707401 A9.118033989 9.118033989 0 0 0 12.956337712 24.595037155 Q10.394640538 25.514561357 8.064899094 26.921729424 Z M3.16073703 20.171729424 Q5.218963089 18.390852489 6.885090534 16.238682304 A9.118033989 9.118033989 0 0 0 8.485589401 21.16451132 Q5.872650088 20.402694206 3.16073703 20.171729424 Z M3.16073703 11.828270576 Q5.872650088 11.597305794 8.485589401 10.83548868 A9.118033989 9.118033989 0 0 0 6.885090534 15.761317696 Q5.218963089 13.609147511 3.16073703 11.828270576 Z M8.064899094 5.078270576 Q10.394640538 6.485438643 12.956337712 7.404962845 A9.118033989 9.118033989 0 0 0 8.766177278 10.449292599 Q8.683265755 7.728825204 8.064899094 5.078270576 Z";
  const SOL_RING =
    `<svg width="15" height="15" viewBox="2.5 2.5 27 27" aria-hidden="true">` +
    `<path fill="#FFCC33" d="${RAYS}"/>` +
    `<circle cx="16" cy="16" r="6.5" fill="none" stroke="#E8913A" stroke-width="1.736067977"/></svg>`;
  const TITLE_ON = "the solstone app takes in what you share with it on this page. all of it goes into your journal.";
  const TITLE_PAUSED = "this page is paused.";

  let hostEl = null;
  let labelEl = null;
  let pillEl = null;

  function ensure() {
    if (hostEl && document.documentElement.contains(hostEl)) return;
    hostEl = document.createElement("div");
    hostEl.id = HOST_ID;
    hostEl.style.cssText = "all:initial;position:fixed;bottom:14px;right:14px;z-index:2147483647;";
    const shadow = hostEl.attachShadow ? hostEl.attachShadow({ mode: "closed" }) : null;
    const root = shadow || hostEl;
    const pill = document.createElement("div");
    pill.style.cssText = [
      "font:600 12px/1 -apple-system,BlinkMacSystemFont,'Inter','Segoe UI',sans-serif",
      "display:flex;align-items:center;gap:7px",
      "padding:6px 11px 6px 8px;border-radius:999px",
      "background:rgba(26,26,26,0.92);color:#FAF3E4",
      "box-shadow:0 2px 10px rgba(0,0,0,0.35);user-select:none;cursor:default",
    ].join(";");
    pillEl = pill;
    const mark = document.createElement("span");
    mark.style.cssText = "display:flex;align-items:center";
    mark.innerHTML = SOL_RING;
    labelEl = document.createElement("span");
    labelEl.textContent = "on";
    pill.appendChild(mark);
    pill.appendChild(labelEl);
    root.appendChild(pill);
    (document.body || document.documentElement).appendChild(hostEl);
  }

  function show(paused) {
    ensure();
    if (labelEl) labelEl.textContent = paused ? "paused" : "on";
    if (pillEl) pillEl.style.background = paused ? "rgba(91,82,70,0.95)" : "rgba(26,26,26,0.92)";
    if (pillEl) pillEl.title = paused ? TITLE_PAUSED : TITLE_ON;
    if (hostEl) hostEl.style.opacity = "1";
  }

  function remove() {
    if (hostEl && hostEl.parentNode) hostEl.parentNode.removeChild(hostEl);
    hostEl = null;
    labelEl = null;
    pillEl = null;
  }

  globalThis.SolstoneIndicator = { show, remove };
})();
