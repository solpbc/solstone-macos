// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function classify(raw, statusOrBrand) {
    const brand = typeof statusOrBrand === "string" ? statusOrBrand : (statusOrBrand && statusOrBrand.brand) || "";
    const C = globalThis.SolstoneCopy;
    if (C && C.classifyFailure) return C.classifyFailure(raw, brand);
    return `something went wrong: ${raw}`;
  }

  function contentScriptRegistrationSatisfied(id, registeredScripts) {
    return Array.isArray(registeredScripts) && registeredScripts.some((script) => script && script.id === id);
  }

  globalThis.SolstoneFailures = { classify, contentScriptRegistrationSatisfied };
})();
