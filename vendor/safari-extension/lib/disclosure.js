// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function firstRun(status) {
    const C = globalThis.SolstoneCopy;
    return {
      kinship: C ? C.WARM_CARD : [],
      body: C ? C.DISCLOSURE_BODY : "",
    };
  }

  globalThis.SolstoneDisclosure = { firstRun };
})();
