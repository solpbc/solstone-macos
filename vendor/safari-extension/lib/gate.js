// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const CONSENT_VERSION = 1;

  function runIfPermitted(decision, hooks) {
    if (!decision || decision.open !== true) {
      return null;
    }
    if (!hooks || typeof hooks !== "object") {
      return null;
    }
    const result = {};
    if (typeof hooks.discover === "function") {
      result.root = hooks.discover();
    }
    if (typeof hooks.readMeta === "function") {
      result.meta = hooks.readMeta();
    }
    if (typeof hooks.skim === "function") {
      result.blocks = hooks.skim(result.root);
    }
    return result;
  }

  function evaluateLease(lease, now) {
    if (!lease || !lease.token || !lease.generation) {
      return { ok: false, reason: "disconnected" };
    }
    const codec = globalThis.SolstoneNativeBrowser;
    if (!codec || typeof codec.freshnessAuthorizesSkim !== "function") {
      return { ok: false, reason: "stale" };
    }
    const receivedAt = Number(lease.receivedAt || 0);
    const freshnessMs = Number(lease.freshnessMs || 0);
    const nowMs = Number(now !== undefined ? now : (typeof performance !== "undefined" && performance.now ? performance.now() : Date.now()));
    if (!codec.freshnessAuthorizesSkim(receivedAt, freshnessMs, nowMs)) {
      return { ok: false, reason: "stale" };
    }
    return { ok: true, lease };
  }

  function computeDecision({ lease, paused, consentVersion, originGranted, pressure, now, hostCapture, capturePermitted } = {}) {
    if (paused) {
      return { open: false, reason: "extension-paused" };
    }
    if (consentVersion !== CONSENT_VERSION) {
      return { open: false, reason: "missing-consent" };
    }
    if (!originGranted) {
      return { open: false, reason: "origin" };
    }
    if (pressure && pressure.active) {
      return { open: false, reason: "pressure" };
    }
    if (hostCapture === "intake_off") {
      return { open: false, reason: "intake-off" };
    }
    if (hostCapture === "not_paired") {
      return { open: false, reason: "not-paired" };
    }
    if (hostCapture === "paused") {
      return { open: false, reason: "host-paused" };
    }
    if (hostCapture === "unavailable" || hostCapture == null) {
      return { open: false, reason: "host-unavailable" };
    }
    if (hostCapture !== "permitted") {
      return { open: false, reason: "host-unavailable" };
    }
    if (capturePermitted !== true) {
      return { open: false, reason: "custody-full" };
    }
    const evaluated = evaluateLease(lease, now);
    if (!evaluated.ok) {
      return { open: false, reason: evaluated.reason };
    }
    return { open: true, reason: "open" };
  }

  globalThis.SolstoneCaptureGate = {
    CONSENT_VERSION,
    runIfPermitted,
    evaluateLease,
    computeDecision,
  };
})();
