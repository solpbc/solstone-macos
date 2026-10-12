// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function addSite(host, status) {
    const brand = typeof status === "string" ? status : status?.brand;
    const C = globalThis.SolstoneCopy;
    if (C && C.sheetCopy) return C.sheetCopy(host, brand);
    return {
      title: `add ${host}?`,
      what: "",
      unsent: "",
      destinationLabel: "it goes to",
      destination: "your journal, through the solstone app on this computer",
      destinationDetail: "nothing leaves this browser except to the solstone app on this computer.",
      browser: "your browser will ask you to allow this next.",
      confirmLabel: "add this site",
      cancelLabel: "cancel",
    };
  }

  function firstRun(status) {
    const C = globalThis.SolstoneCopy;
    return {
      kinship: C ? C.WARM_CARD : [],
      body: C ? C.DISCLOSURE_BODY : "",
    };
  }

  globalThis.SolstoneDisclosure = { addSite, firstRun };
})();
