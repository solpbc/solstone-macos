// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function originHost(origin) {
    try { return new URL(origin).host; } catch (_e) { return ""; }
  }

  function matchPatternFor(origin) {
    const host = originHost(origin);
    if (!host) return "";
    const hosts = globalThis.SolstoneHosts;
    return hosts?.matchPatternFor ? hosts.matchPatternFor(host) : `*://${host.replace(/:\d+$/, "")}/*`;
  }

  function patternMatches(pattern, origin) {
    try {
      const url = new URL(origin);
      if (pattern === "<all_urls>") return url.protocol === "http:" || url.protocol === "https:";
      const match = /^(\*|https?):\/\/([^/]+)\/\*/.exec(pattern);
      if (!match) return false;
      if (match[1] !== "*" && `${match[1]}:` !== url.protocol) return false;
      const host = match[2].toLowerCase();
      return host === "*" || url.hostname.toLowerCase() === host ||
        (host.startsWith("*.") && (url.hostname.toLowerCase() === host.slice(2) || url.hostname.toLowerCase().endsWith(host.slice(1))));
    } catch (_e) { return false; }
  }

  function cloneMap(value) {
    return value && typeof value === "object" && !Array.isArray(value) ? { ...value } : {};
  }

  function apply(state, event) {
    const effects = [];
    let result = { ok: true };
    const origin = event.origin;

    switch (event.type) {
      case "reserve":
        state.reservation = {
          origin, pattern: event.pattern, expiresAt: event.now + 120000,
          grantEpoch: state.grantEpoch, permissionEpoch: state.permissionEpoch,
        };
        break;
      case "drop-reservation":
        state.reservation = null;
        break;
      case "owner-remove":
        state.grantEpoch++;
        state.chosen = state.chosen.filter((item) => item !== origin);
        state.granted = state.granted.filter((item) => item !== origin);
        if (state.reservation?.origin === origin) state.reservation = null;
        effects.push("publish-closed");
        break;
      case "browser-removed":
        state.permissionEpoch++;
        state.granted = state.granted.filter((item) => !event.patterns.some((pattern) => patternMatches(pattern, item)));
        effects.push("publish-closed");
        break;
      case "browser-added-sync": {
        const pending = state.reservation && event.now < state.reservation.expiresAt;
        const matches = pending && event.patterns.length > 0 && event.patterns.every((pattern) => pattern === state.reservation.pattern);
        if (!matches) state.permissionEpoch++;
        result = { ok: true, epochAtStart: state.permissionEpoch, reservation: matches ? state.reservation : null };
        break;
      }
      case "publish-grants":
        if (state.permissionEpoch !== event.epochAtStart) {
          effects.push("stale");
          result = { ok: false, stale: true };
        } else {
          const live = new Set(event.livePatterns || []);
          state.granted = state.chosen.filter((chosenOrigin) => {
            const pattern = matchPatternFor(chosenOrigin);
            return live.has(pattern) || live.has("*://*/*");
          });
        }
        break;
      case "begin-add":
        if (state.grantEpoch !== event.capturedGrantEpoch || state.permissionEpoch !== event.capturedPermissionEpoch || !event.liveAuth) {
          state.reservation = null;
          result = { ok: false, error: "capture_unavailable" };
        } else if (!event.hasPerm) {
          state.reservation = null;
          result = { ok: false, error: "permission_not_granted" };
        }
        break;
      case "fence-add":
        if (event.phase !== "after-choice-write") {
          result = { ok: false, error: "invalid_phase" };
          break;
        }
        if (state.grantEpoch !== event.capturedGrantEpoch) {
          if (!state.chosen.includes(origin)) effects.push("align-durable-to-memory");
          state.reservation = null;
          result = { ok: false, error: "capture_unavailable" };
        } else if (state.permissionEpoch !== event.capturedPermissionEpoch) {
          if (!state.chosen.includes(origin)) state.chosen.push(origin);
          state.reservation = null;
          result = { ok: false, error: "capture_unavailable" };
        } else {
          if (!state.chosen.includes(origin)) state.chosen.push(origin);
        }
        break;
      case "note-registration":
        if (state.grantEpoch !== event.capturedGrantEpoch || state.permissionEpoch !== event.capturedPermissionEpoch) {
          effects.push("stale");
          result = { ok: false, stale: true };
        } else {
          state.registration = cloneMap(state.registration);
          if (event.status === "failed") state.registration[origin] = "failed";
          else if (event.status === "reload") state.registration[origin] = "reload";
          else if (event.status === "ready") delete state.registration[origin];
        }
        break;
      default:
        result = { ok: false, error: "unknown_event" };
    }
    return { state, effects, result };
  }

  globalThis.SolstoneOwnerSites = { apply };
})();
