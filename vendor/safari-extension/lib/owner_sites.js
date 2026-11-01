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

  function grantLevelFor(origin, livePatterns, marked = false) {
    const host = originHost(origin);
    const hosts = globalThis.SolstoneHosts;
    if (!host) return null;
    let scheme = null;
    try { scheme = new URL(origin).protocol.replace(":", ""); } catch (_e) {}
    if (hosts?.grantLevel) return hosts.grantLevel(host, livePatterns, marked, scheme);
    const live = new Set(livePatterns || []);
    return live.has("*://*/*") || live.has(matchPatternFor(origin)) ? "site" : null;
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
          broadAlreadyLive: event.broadAlreadyLive === true,
        };
        break;
      case "drop-reservation":
        state.reservation = null;
        break;
      case "owner-remove":
        state.grantEpoch++;
        state.chosen = state.chosen.filter((item) => item !== origin);
        state.granted = state.granted.filter((item) => item !== origin);
        state.exactOnly = (state.exactOnly || []).filter((item) => item !== origin);
        state.siteWide = (state.siteWide || []).filter((item) => item !== origin);
        if (state.reservation?.origin === origin) state.reservation = null;
        state.declinedHosts = state.declinedHosts ? new Set(state.declinedHosts) : new Set();
        try {
          const uh = new URL(origin).hostname;
          if (uh) {
            state.declinedHosts.add(uh);
          }
        } catch (_e) {}
        if (Array.isArray(event.coveringHosts)) {
          for (const h of event.coveringHosts) {
            if (h) state.declinedHosts.add(h);
          }
        }
        effects.push("publish-closed");
        break;
      case "decline-offer":
        state.grantEpoch++;
        state.declinedHosts = state.declinedHosts ? new Set(state.declinedHosts) : new Set();
        if (event.host) state.declinedHosts.add(event.host);
        break;
      case "selected-leave-out":
        state.grantEpoch++;
        state.declinedHosts = state.declinedHosts ? new Set(state.declinedHosts) : new Set();
        if (event.host) state.declinedHosts.add(event.host);
        if (Array.isArray(event.coveringHosts)) {
          for (const h of event.coveringHosts) state.declinedHosts.add(h);
        }
        break;
      case "drop-declines":
        if (state.declinedHosts && Array.isArray(event.hosts)) {
          for (const h of event.hosts) state.declinedHosts.delete(h);
        }
        break;
      case "browser-removed":
        state.permissionEpoch++;
        state.granted = state.granted.filter((item) => !event.patterns.some((pattern) => patternMatches(pattern, item)));
        state.exactOnly = (state.exactOnly || []).filter((item) => state.granted.includes(item));
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
          // A site is granted under its own pattern (it and its subdomains) or,
          // from before sites covered subdomains, under its exact host alone.
          const siteWideSet = new Set(state.siteWide || []);
          const levels = new Map(state.chosen.map((chosenOrigin) => [
            chosenOrigin,
            grantLevelFor(chosenOrigin, event.livePatterns, siteWideSet.has(chosenOrigin)),
          ]));
          state.granted = state.chosen.filter((chosenOrigin) => levels.get(chosenOrigin));
          // An exact-only entry whose grant lapsed keeps its mark, so allowing it
          // again asks for the same exact address, never the whole site.
          const priorExact = new Set(state.exactOnly || []);
          state.exactOnly = state.chosen.filter((chosenOrigin) => levels.get(chosenOrigin) === "exact" ||
            (!levels.get(chosenOrigin) && priorExact.has(chosenOrigin)));
        }
        break;
      case "begin-add":
        if (state.grantEpoch !== event.capturedGrantEpoch || state.permissionEpoch !== event.capturedPermissionEpoch) {
          state.reservation = null;
          result = { ok: false, error: "capture_unavailable" };
        } else if (event.consent !== true) {
          state.reservation = null;
          result = { ok: false, error: "missing_consent" };
        } else if (!event.hasPerm) {
          state.reservation = null;
          result = { ok: false, error: "permission_not_granted" };
        }
        break;
      case "begin-adopt":
        if (state.grantEpoch !== event.capturedGrantEpoch || state.permissionEpoch !== event.capturedPermissionEpoch) {
          effects.push("stale");
          result = { ok: false, stale: true };
        }
        break;
      case "fence-adopt": {
        if (event.phase !== "after-choice-write") {
          result = { ok: false, error: "invalid_phase" };
          break;
        }
        const originList = (event.origins || []).map((it) => (typeof it === "string" ? it : it.origin));
        if (state.grantEpoch !== event.capturedGrantEpoch) {
          if (originList.some((o) => !state.chosen.includes(o))) {
            effects.push("align-durable-to-memory");
          }
          state.reservation = null;
          result = { ok: false, error: "capture_unavailable" };
        } else if (state.permissionEpoch !== event.capturedPermissionEpoch) {
          state.reservation = null;
          result = { ok: false, error: "capture_unavailable" };
        } else {
          if (!Array.isArray(state.siteWide)) state.siteWide = [];
          for (const item of event.origins || []) {
            const o = typeof item === "string" ? item : item.origin;
            const isSiteWide = typeof item === "object" && item.siteWide === true;
            if (!state.chosen.includes(o)) state.chosen.push(o);
            if (isSiteWide && !state.siteWide.includes(o)) state.siteWide.push(o);
            if (state.reservation?.origin === o) state.reservation = null;
          }
        }
        break;
      }
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
