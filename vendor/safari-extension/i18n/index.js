// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
(() => {
  "use strict";
  const api = globalThis.SolstoneI18nBundles.browser;
  const contracts = globalThis.SolstoneI18nContracts;
  const locale = "en-US";
  function t(id, input = {}) {
    const args = { ...input };
    const selector = contracts[id]?.selector?.name;
    if (selector === "place" && typeof args.place === "string") args.place = args.place.replace(/^this /, "");
    if (selector === "browser" && typeof args.browser === "string") args.browser = args.browser.toLowerCase();
    return api.render(locale, id, Object.entries(args), { useIsolating: locale !== "en-US" });
  }
  function localize(root = document) {
    for (const element of root.querySelectorAll("[data-i18n]")) element.textContent = t(element.dataset.i18n, JSON.parse(element.getAttribute("data-i18n-args") || "{}"));
    for (const attribute of ["aria-label", "title", "placeholder"]) {
      for (const element of root.querySelectorAll(`[data-i18n-${attribute}]`)) element.setAttribute(attribute, t(element.getAttribute(`data-i18n-${attribute}`)));
    }
  }
  globalThis.SolstoneI18n = Object.freeze({ t, localize, ids: Object.freeze(Object.keys(contracts)) });
  if (typeof document !== "undefined") localize();
})();
