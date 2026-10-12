// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const H = globalThis.SolstoneHosts;

  function permissionExemptOrigins(_cfg) {
    return [];
  }

  function reconcile({ granted, manifestOrigins, exemptOrigins, exemptPatterns, allowlist, pausedHosts } = {}) {
    if (granted === null) return [];

    const groups = new Map();
    for (const entry of allowlist || []) {
      const matchHost = H.matchHostFor(entry);
      if (!groups.has(matchHost)) groups.set(matchHost, []);
      groups.get(matchHost).push(entry);
    }

    const grantedSet = new Set(granted || []);
    const paused = pausedHosts || {};
    const actions = [];
    for (const matchHost of [...groups.keys()].sort()) {
      const entries = groups.get(matchHost);
      const hasGrant = grantedSet.has(H.matchPatternFor(matchHost));
      if (hasGrant && paused[matchHost]) actions.push({ op: "resume", matchHost, entries });
      else if (!hasGrant && !paused[matchHost]) actions.push({ op: "pause", matchHost, entries });
    }

    const claimedOrigins = new Set([
      ...(manifestOrigins || []),
      ...(exemptOrigins || []),
      ...(exemptPatterns || []),
      ...[...groups.keys()].map((matchHost) => H.matchPatternFor(matchHost)),
    ]);
    for (const origin of [...grantedSet].sort()) {
      if (!claimedOrigins.has(origin)) actions.push({ op: "release", origin });
    }
    return actions;
  }

  globalThis.SolstoneReconcile = { permissionExemptOrigins, reconcile };
})();
