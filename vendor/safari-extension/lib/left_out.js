// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function applyList({
    epoch,
    rev,
    savedEpoch,
    savedRev,
    savedList = [],
    savedRawList = null,
    localExcluded = [],
    frameList = [],
    acceptHost = null,
    normalizeHost = null,
  } = {}) {
    const H = globalThis.SolstoneHosts;
    const normalize = normalizeHost || ((h) => (H?.excludedHostname ? H.excludedHostname(h) : (typeof acceptHost === "function" && acceptHost(h) ? h : null)));

    const seenRaw = new Set();
    const frameRaw = [];
    const frameNorm = [];
    for (const raw of frameList || []) {
      if (typeof raw !== "string") continue;
      const norm = normalize(raw);
      if (norm) {
        if (!seenRaw.has(raw)) {
          seenRaw.add(raw);
          frameRaw.push(raw);
        }
        if (!frameNorm.includes(norm)) {
          frameNorm.push(norm);
        }
      }
    }

    const savedRaw = Array.isArray(savedRawList) ? [...new Set(savedRawList)] : [...new Set(savedList || [])];
    const saved = [...new Set(savedList || [])];
    const local = [...new Set(localExcluded || [])];
    const currentRev = typeof rev === "number" ? rev : 0;
    const priorRev = typeof savedRev === "number" ? savedRev : 0;

    // Case 1: No saved epoch
    if (savedEpoch == null) {
      return {
        list: [...frameNorm].sort(),
        rawList: frameRaw,
        epoch: epoch || null,
        rev: currentRev,
        localExcluded: local.sort(),
        migrated: [],
        haveSavedList: true,
      };
    }

    const sameEpoch = epoch != null && epoch === savedEpoch;

    // Case 2: Same epoch, equal rev -> additions only
    if (sameEpoch && currentRev === priorRev) {
      const unionNorm = [...new Set([...saved, ...frameNorm])].sort();
      const unionRaw = [...savedRaw];
      for (const r of frameRaw) {
        if (!unionRaw.includes(r)) unionRaw.push(r);
      }
      return {
        list: unionNorm,
        rawList: unionRaw,
        epoch: savedEpoch,
        rev: priorRev,
        localExcluded: local.sort(),
        migrated: [],
        haveSavedList: true,
      };
    }

    // Case 3: Same epoch, higher rev
    if (sameEpoch && currentRev > priorRev) {
      const frameRawSet = new Set(frameRaw);
      const removedRawStrings = new Set(savedRaw.filter((r) => !frameRawSet.has(r)));
      const nextLocal = local.filter((h) => !removedRawStrings.has(h)).sort();
      return {
        list: [...frameNorm].sort(),
        rawList: frameRaw,
        epoch,
        rev: currentRev,
        localExcluded: nextLocal,
        migrated: [],
        haveSavedList: true,
      };
    }

    // Case 4: Epoch differs, or rev lower
    const frameRawSet = new Set(frameRaw);
    const missingRaw = savedRaw.filter((r) => !frameRawSet.has(r));
    const migrated = missingRaw.map((r) => normalize(r)).filter(Boolean);
    const nextLocal = [...new Set([...local, ...migrated])].sort();
    return {
      list: [...frameNorm].sort(),
      rawList: frameRaw,
      epoch: epoch || null,
      rev: currentRev,
      localExcluded: nextLocal,
      migrated: [...new Set(migrated)].sort(),
      haveSavedList: true,
    };
  }

  function noteAck({ outstandingId, ackId } = {}) {
    if (typeof outstandingId === "number" && typeof ackId === "number" && ackId === outstandingId) {
      return "settled";
    }
    return "pending";
  }

  function ruleResult({ outstanding, frameList = [] } = {}) {
    if (!outstanding) return "applied";
    const hosts = new Set(frameList || []);
    const present = hosts.has(outstanding.host);
    if (outstanding.out === true && !present) return "refused";
    if (outstanding.out === false && present) return "refused";
    return "applied";
  }

  function nextMigration({ queue = [], refused = new Set(), outstanding = null, now = 0, lastSentAt = null, blocked = false } = {}) {
    if (blocked || outstanding != null) return null;
    if (lastSentAt != null && now - lastSentAt < 1000) return null;
    const ref = refused instanceof Set ? refused : new Set(refused || []);
    for (const host of queue) {
      if (!ref.has(host)) return host;
    }
    return null;
  }

  function migrationBlocked(outstanding, now = 0) {
    if (outstanding && typeof outstanding.sentAt === "number") {
      return now - outstanding.sentAt >= 10000;
    }
    return false;
  }

  globalThis.SolstoneLeftOut = {
    applyList,
    noteAck,
    ruleResult,
    nextMigration,
    migrationBlocked,
  };
})();
