// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const Blocks = globalThis.SolstoneBlocks;
  const DB = globalThis.SolstoneDB;
  const Gate = globalThis.SolstoneCaptureGate;
  const Outbox = globalThis.SolstoneNativeOutbox;
  const H = globalThis.SolstoneHosts;
  const OwnerSites = globalThis.SolstoneOwnerSites;

  const frameBindings = new Map(); // key -> binding
  const frameChallenges = new Map(); // tabId:frameId -> challenge
  let ctxCounter = 0;
  let grantChain = Promise.resolve();
  let grantChainDepth = 0;
  function enqueueGrant(work, { wait = true, chain = true } = {}) {
    const run = async () => {
      grantChainDepth++;
      try { return await work(); }
      finally { grantChainDepth--; }
    };
    const operation = wait
      ? grantChain.catch(() => {}).then(run)
      : run();
    if (chain) grantChain = operation;
    return operation;
  }
  let pauseEpoch = 0;

  function originGranted(port, origin) {
    return H.originGranted(port, origin);
  }

  function siteKeyFor(port, origin) {
    if (port.siteMode === "all") return origin;
    return H.siteForOrigin(port.chosenOrigins, origin, port.exactOnlyOrigins, port.siteWideOrigins) || origin;
  }

  function ownerStateFor(port) {
    const current = port.ownerSites || {};
    return {
      grantEpoch: Number.isSafeInteger(current.grantEpoch) ? current.grantEpoch : 0,
      permissionEpoch: Number.isSafeInteger(port.permissionEpoch) ? port.permissionEpoch : 0,
      chosen: Array.from(port.chosenOrigins || []),
      granted: Array.from(port.grantedOrigins || []),
      exactOnly: Array.from(port.exactOnlyOrigins || []),
      exactOnlyKnown: port.exactOnlyKnown !== false,
      siteWide: Array.from(port.siteWideOrigins || current.siteWide || []),
      declinedHosts: new Set(port.declinedHosts || current.declinedHosts || []),
      reservation: current.reservation || null,
      registration: { ...(port.registration || current.registration || {}) },
      enqueue: { ...(port.enqueue || current.enqueue || {}) },
    };
  }

  function applyOwnerEvent(port, event) {
    if (!OwnerSites?.apply) throw new Error("missing SolstoneOwnerSites");
    const transition = OwnerSites.apply(ownerStateFor(port), event);
    const state = transition.state;
    port.ownerSites = {
      grantEpoch: state.grantEpoch,
      reservation: state.reservation,
      registration: state.registration,
      enqueue: state.enqueue,
      siteWide: state.siteWide,
      declinedHosts: state.declinedHosts,
    };
    port.permissionEpoch = state.permissionEpoch;
    port.chosenOrigins = new Set(state.chosen);
    port.grantedOrigins = new Set(state.granted);
    const priorExact = Array.from(port.exactOnlyOrigins || []).sort();
    port.exactOnlyOrigins = new Set(state.exactOnly || []);
    const nextExact = Array.from(port.exactOnlyOrigins).sort();
    const exactChanged = priorExact.length !== nextExact.length || priorExact.some((o, i) => o !== nextExact[i]);
    if (event.type === "publish-grants" && transition.result?.ok !== false) port.exactOnlyKnown = true;
    // A removal saves its mark with the rest of the list in one write.
    if (exactChanged && event.type !== "owner-remove" && typeof port.onExactOnlyChange === "function") {
      try { port.onExactOnlyChange(nextExact); } catch (_e) {}
    }
    if (state.siteWide) port.siteWideOrigins = Array.from(state.siteWide);
    if (state.declinedHosts) port.declinedHosts = Array.from(state.declinedHosts);
    port.registration = state.registration;
    port.enqueue = state.enqueue;
    return transition;
  }

  function mintCtx() {
    ctxCounter++;
    const random = new Uint8Array(8);
    crypto.getRandomValues(random);
    const randHex = [...random].map((b) => b.toString(16).padStart(2, "0")).join("");
    return `ctx-${ctxCounter}-${randHex}`;
  }

  function frameKeyFor(tabId, frameId, documentId) {
    if (documentId) {
      return `${tabId}:${frameId || 0}:${documentId}`;
    }
    return `${tabId}:${frameId || 0}`;
  }

  function destroyBinding(tabId, frameId) {
    if (tabId !== undefined && frameId !== undefined) {
      const prefix = `${tabId}:${frameId}`;
      for (const key of frameBindings.keys()) {
        if (key === prefix || key.startsWith(prefix + ":")) {
          const b = frameBindings.get(key);
          if (b && Outbox.pruneCursor) Outbox.pruneCursor(b.inst, b.ctx).catch(() => {});
          frameBindings.delete(key);
        }
      }
      frameChallenges.delete(`${tabId}:${frameId}`);
    } else if (tabId !== undefined) {
      for (const [key, binding] of frameBindings) {
        if (binding.tabId === tabId) {
          if (binding && Outbox.pruneCursor) Outbox.pruneCursor(binding.inst, binding.ctx).catch(() => {});
          frameBindings.delete(key);
        }
      }
      for (const key of frameChallenges.keys()) {
        if (key.startsWith(`${tabId}:`)) frameChallenges.delete(key);
      }
    }
    Outbox.checkAuthorization?.();
  }

  function normalizeOrigin(input) {
    if (typeof input !== "string" || !input.trim()) return null;
    try {
      const u = new URL(input.trim());
      if (u.protocol !== "http:" && u.protocol !== "https:") return null;
      return u.origin;
    } catch (_e) {
      return null;
    }
  }

  function isExtensionPageSender(sender, runtimeId) {
    if (!sender) return false;
    if (sender.id !== runtimeId) return false;
    try {
      // Options pages opened in a tab also carry sender.tab. Authenticate the
      // browser-supplied extension URL instead of treating every tab as content.
      const expected = new URL(typeof chrome !== "undefined" && chrome.runtime?.getURL
        ? chrome.runtime.getURL("/") : `chrome-extension://${runtimeId}/`);
      const actual = new URL(sender.url || "");
      return ["chrome-extension:", "moz-extension:", "safari-web-extension:"].includes(expected.protocol) &&
        actual.protocol === expected.protocol && actual.host === expected.host &&
        !actual.username && !actual.password;
    } catch (_err) { return false; }
  }

  function addGrantedOrigin(origin, deps, reservation = null) {
    const port = deps.port;
    // Capture withdrawal authority at command admission, including time
    // queued behind another add or an already-dispatched browser effect.
    const start = ownerStateFor(port);
    const capturedGrantEpoch = reservation ? reservation.grantEpoch : start.grantEpoch;
    const capturedPermissionEpoch = reservation ? reservation.permissionEpoch : start.permissionEpoch;
    return enqueueGrant(async () => {
      await deps.settlePermissionEffects?.();
      if (Array.isArray(port.pendingRemoveOrigins) && port.pendingRemoveOrigins.includes(origin)) {
        applyOwnerEvent(port, { type: "drop-reservation" });
        return { ok: false, error: "capture_unavailable" };
      }
      if (reservation && (port.ownerSites?.reservation !== reservation || port.now() >= reservation.expiresAt)) {
        return { ok: false, error: "capture_unavailable" };
      }
      let host = "";
      try {
        host = new URL(origin).host;
      } catch (_e) {
        applyOwnerEvent(port, { type: "drop-reservation" });
        return { ok: false, error: "invalid_origin" };
      }

      // The site's own pattern, or an older exact-host grant the browser still
      // holds (the site then covers that host alone until it's widened).
      const patterns = H && H.sitePatternsFor ? H.sitePatternsFor(host) : [`*://${host}/*`];
      let hasPerm = false;
      try {
        if (typeof chrome !== "undefined" && chrome.permissions?.contains) {
          for (const pat of patterns) {
            if (await chrome.permissions.contains({ origins: [pat] })) { hasPerm = true; break; }
          }
        } else if (typeof chrome !== "undefined" && chrome.permissions?.getAll) {
          const perms = await chrome.permissions.getAll();
          hasPerm = Array.isArray(perms?.origins) && (patterns.some((pat) => perms.origins.includes(pat)) || perms.origins.includes("*://*/*"));
        } else {
          hasPerm = false;
        }
      } catch (_e) {
        hasPerm = false;
      }

      if (reservation && (port.ownerSites?.reservation !== reservation || port.now() >= reservation.expiresAt)) {
        return { ok: false, error: "capture_unavailable" };
      }
      const consent = port.consentVersion === Gate.CONSENT_VERSION;
      const admission = applyOwnerEvent(port, {
        type: "begin-add", origin, now: port.now(), consent: !!consent, hasPerm,
        capturedGrantEpoch, capturedPermissionEpoch,
      });
      if (!admission.result.ok) return admission.result;

      const nextChosen = Array.from(new Set([...Array.from(port.chosenOrigins || []), origin]));
      const nextOffered = (port.offeredOrigins || []).filter((o) => o !== origin);
      try {
        if (deps.setCfg) {
          const patch = { chosenOrigins: nextChosen };
          if (nextOffered.length !== (port.offeredOrigins || []).length) {
            patch.offeredOrigins = nextOffered;
          }
          await deps.setCfg(patch);
        }
      } catch (_e) {
        applyOwnerEvent(port, { type: "drop-reservation" });
        return { ok: false, error: "storage_error" };
      }
      port.offeredOrigins = nextOffered;

      if (Array.isArray(port.pendingRemoveOrigins) && port.pendingRemoveOrigins.includes(origin)) {
        if (deps.setCfg) {
          try { await deps.setCfg({ chosenOrigins: Array.from(port.chosenOrigins || []) }); }
          catch (_e) { return { ok: false, error: "storage_error" }; }
        }
        applyOwnerEvent(port, { type: "drop-reservation" });
        port.notify();
        return { ok: false, error: "capture_unavailable" };
      }

      const fence = applyOwnerEvent(port, {
        type: "fence-add", origin, capturedGrantEpoch, capturedPermissionEpoch, phase: "after-choice-write",
      });
      if (!fence.result.ok) {
        if (fence.effects.includes("align-durable-to-memory") && deps.setCfg) {
          try { await deps.setCfg({ chosenOrigins: Array.from(port.chosenOrigins || []) }); }
          catch (_e) { return { ok: false, error: "storage_error" }; }
        }
        port.notify();
        return fence.result;
      }

      let livePerms;
      try {
        const perms = typeof chrome !== "undefined" && chrome.permissions?.getAll ? await chrome.permissions.getAll() : null;
        if (!Array.isArray(perms?.origins)) throw new Error("permission snapshot unavailable");
        livePerms = perms.origins;
      } catch (_e) {
        const moved = ownerStateFor(port).grantEpoch !== capturedGrantEpoch;
        if (moved && !port.chosenOrigins.has(origin) && deps.setCfg) {
          try { await deps.setCfg({ chosenOrigins: Array.from(port.chosenOrigins || []) }); }
          catch (_err) { applyOwnerEvent(port, { type: "drop-reservation" }); return { ok: false, error: "storage_error" }; }
        }
        applyOwnerEvent(port, { type: "drop-reservation" });
        port.notify();
        return { ok: false, error: "capture_unavailable" };
      }

      const published = applyOwnerEvent(port, {
        type: "publish-grants", livePatterns: livePerms, epochAtStart: capturedPermissionEpoch,
      });
      if (!published.result.ok) {
        applyOwnerEvent(port, { type: "drop-reservation" });
        port.notify();
        return { ok: false, error: "capture_unavailable" };
      }

      let regStatus = "ready";
      if (typeof deps.registerSite === "function") {
        try {
          regStatus = await deps.registerSite(host);
        } catch (_e) {
          regStatus = "failed";
        }
      }

      const registered = applyOwnerEvent(port, {
        type: "note-registration", origin, status: regStatus, capturedGrantEpoch, capturedPermissionEpoch,
      });
      if (!registered.result.ok) {
        applyOwnerEvent(port, { type: "drop-reservation" });
        port.notify();
        deps.refreshOpenTabs?.();
        return { ok: false, error: "capture_unavailable" };
      }

      if (regStatus === "failed") {
        if (port.setRegistration) await port.setRegistration(origin, "failed");
        applyOwnerEvent(port, { type: "drop-reservation" });
        port.notify();
        deps.refreshOpenTabs?.();
        return { ok: false, error: "registration_failed", registration: "failed" };
      }

      if (port.setRegistration) await port.setRegistration(origin, regStatus);

      applyOwnerEvent(port, { type: "drop-reservation" });
      port.notify();
      deps.refreshOpenTabs?.();
      const final = ownerStateFor(port);
      if (final.grantEpoch !== capturedGrantEpoch || final.permissionEpoch !== capturedPermissionEpoch || !port.grantedOrigins.has(origin)) {
        return { ok: false, error: "capture_unavailable" };
      }
      return { ok: true, origin, registration: regStatus };
    });
  }

  function completeReservedOrigin(reservation, deps) {
    return addGrantedOrigin(reservation.origin, deps, reservation);
  }

  function runAdoptionPass(deps = {}) {
    const port = deps.port;
    if (!port) return Promise.resolve();
    return enqueueGrant(async () => {
      const consent = port.consentVersion === Gate.CONSENT_VERSION;
      const isUpgrade = !port.declinedHostsKnown;
      const siteMode = port.siteMode;

      if (siteMode === "all") {
        return;
      }

      let perms;
      try {
        perms = typeof chrome !== "undefined" && chrome.permissions?.getAll ? await chrome.permissions.getAll() : null;
      } catch (_e) {
        return;
      }
      const livePatterns = Array.isArray(perms?.origins) ? perms.origins : [];
      // A decline lasts only while a live site grant still covers its host;
      // once the browser has dropped it, the owner's next Allow adopts again.
      if (typeof deps.checkCleanDeclines === "function" && (port.declinedHosts || []).length > 0) {
        const before = Array.from(port.declinedHosts || []);
        await deps.checkCleanDeclines(before, livePatterns);
        const after = Array.from(port.declinedHosts || []);
        if (after.length !== before.length && deps.setCfg) {
          try { await deps.setCfg({ declinedHosts: after }); } catch (_e) {}
        }
      }

      const effectiveLeftOut = new Set([...(port.excludedHosts || []), ...(port.appLeftOut || [])]);
      const eligible = [];
      const liveHosts = new Set();

      for (const pat of livePatterns) {
        const grant = H.classifySiteGrant(pat);
        if (!grant) continue;
        liveHosts.add(grant.host);

        const alreadyOffered = (port.offeredOrigins || []).some((offeredOrigin) => {
          try {
            return new URL(offeredOrigin).hostname === grant.host;
          } catch (_e) { return false; }
        });
        if (alreadyOffered) continue;

        const chosenCovers = Array.from(port.chosenOrigins || []).some((chosen) => {
          try {
            const entryHost = new URL(chosen).hostname;
            return H.hostCovers(entryHost, grant.host);
          } catch (_e) { return false; }
        });
        if (chosenCovers) continue;

        const leftOutCovers = Array.from(effectiveLeftOut).some((exHost) => H.hostCovers(exHost, grant.host));
        if (leftOutCovers) continue;

        const res = port.ownerSites?.reservation;
        if (res && port.now() < res.expiresAt) {
          if (res.pattern && H.classifySiteGrant(res.pattern)?.host === grant.host) continue;
          if (res.origin) {
            try {
              const resHost = new URL(res.origin).hostname;
              if (H.hostCovers(resHost, grant.host)) continue;
            } catch (_e) {}
          }
        }

        if (port.declinedHosts && port.declinedHosts.includes(grant.host)) continue;

        eligible.push(grant);
      }

      let stillOffered = (port.offeredOrigins || []).filter((offeredOrigin) => {
        try {
          const offHost = new URL(offeredOrigin).hostname;
          return liveHosts.has(offHost);
        } catch (_e) { return false; }
      });

      if (!consent || isUpgrade) {
        const existingOfferHosts = new Set(stillOffered.map((o) => {
          try { return new URL(o).hostname; } catch (_e) { return ""; }
        }));
        for (const el of eligible) {
          if (!existingOfferHosts.has(el.host)) {
            stillOffered.push(el.origin);
            existingOfferHosts.add(el.host);
          }
        }
        stillOffered.sort();
        port.offeredOrigins = stillOffered;

        const patch = { offeredOrigins: stillOffered };
        if (isUpgrade) {
          patch.declinedHosts = Array.from(port.declinedHosts || []);
        }
        if (deps.setCfg) {
          try {
            await deps.setCfg(patch);
            if (isUpgrade) {
              port.declinedHostsKnown = true;
            }
          } catch (_e) {
            return;
          }
        } else if (isUpgrade) {
          port.declinedHostsKnown = true;
        }
        port.notify();
        return;
      }

      if (eligible.length === 0) {
        if (stillOffered.length !== (port.offeredOrigins || []).length) {
          port.offeredOrigins = stillOffered;
          if (deps.setCfg) {
            try { await deps.setCfg({ offeredOrigins: stillOffered }); } catch (_e) {}
          }
          port.notify();
        }
        return;
      }

      const start = ownerStateFor(port);
      const capturedGrantEpoch = start.grantEpoch;
      const capturedPermissionEpoch = start.permissionEpoch;

      const beginResult = applyOwnerEvent(port, {
        type: "begin-adopt",
        origins: eligible.map((e) => ({ origin: e.origin, siteWide: e.siteWide })),
        capturedGrantEpoch,
        capturedPermissionEpoch,
      });
      if (!beginResult.result.ok) {
        port.notify();
        return;
      }

      const nextChosen = Array.from(new Set([...Array.from(port.chosenOrigins || []), ...eligible.map((e) => e.origin)])).sort();
      const nextSiteWide = Array.from(new Set([...Array.from(port.siteWideOrigins || []), ...eligible.filter((e) => e.siteWide).map((e) => e.origin)])).sort();
      const adoptedOriginsSet = new Set(eligible.map((e) => e.origin));
      const nextOffered = stillOffered.filter((o) => !adoptedOriginsSet.has(o)).sort();

      if (deps.setCfg) {
        try {
          await deps.setCfg({
            chosenOrigins: nextChosen,
            siteWideOrigins: nextSiteWide,
            offeredOrigins: nextOffered,
          });
        } catch (_e) {
          return;
        }
      }

      const fenceResult = applyOwnerEvent(port, {
        type: "fence-adopt",
        origins: eligible.map((e) => ({ origin: e.origin, siteWide: e.siteWide })),
        capturedGrantEpoch,
        capturedPermissionEpoch,
        phase: "after-choice-write",
      });

      if (!fenceResult.result.ok) {
        if (fenceResult.effects.includes("align-durable-to-memory") && deps.setCfg) {
          try {
            await deps.setCfg({
              chosenOrigins: Array.from(port.chosenOrigins || []),
              siteWideOrigins: Array.from(port.siteWideOrigins || []),
            });
          } catch (_e) {}
        }
        port.notify();
        return;
      }

      port.siteWideOrigins = nextSiteWide;
      port.offeredOrigins = nextOffered;

      applyOwnerEvent(port, {
        type: "publish-grants",
        livePatterns,
        epochAtStart: capturedPermissionEpoch,
      });

      for (const el of eligible) {
        if (typeof deps.registerSite === "function") {
          try { await deps.registerSite(el.host); } catch (_e) {}
        }
      }

      // Announced by site: its host, and whether the grant covered the whole site.
      const notices = [...(port.adoptionNotices || [])];
      for (const e of eligible) {
        if (!notices.some((n) => n && n.host === e.host)) {
          notices.push({ host: e.host, siteWide: !!e.siteWide && !e.exactOnly });
        }
      }
      port.adoptionNotices = notices;
      port.notify();
      deps.refreshOpenTabs?.();
    });
  }

  async function route(msg, sender, deps = {}) {
    const runtimeId = deps.runtimeId || (typeof chrome !== "undefined" && chrome.runtime?.id ? chrome.runtime.id : "");
    if (!sender || sender.id !== runtimeId) {
      return { ok: false, error: "bad_sender" };
    }

    const port = deps.port;
    if (!port) {
      return { ok: false, error: "port_unavailable" };
    }

    if (isExtensionPageSender(sender, runtimeId)) {
      if (!msg || typeof msg !== "object") {
        return { ok: false, error: "bad_message" };
      }

      switch (msg.cmd) {
        case "getState": {
          return { ok: true, ...(await port.settledStatus()) };
        }

        case "acknowledgeDisclosure": {
          if (msg.version === Gate.CONSENT_VERSION) {
            return enqueueGrant(async () => {
              let perms;
              try {
                if (typeof chrome !== "undefined" && chrome.permissions?.getAll) {
                  perms = await chrome.permissions.getAll();
                }
              } catch (_e) {
                return { ok: false, error: "permissions_unavailable" };
              }
              const livePatterns = Array.isArray(perms?.origins) ? perms.origins : [];

              const effectiveLeftOut = new Set([...(port.excludedHosts || []), ...(port.appLeftOut || [])]);
              const heldOffers = [...(port.offeredOrigins || [])];
              const heldHosts = new Set(heldOffers.map((o) => {
                try { return new URL(o).hostname; } catch (_e) { return ""; }
              }));

              for (const pat of livePatterns) {
                const grant = H.classifySiteGrant(pat);
                if (!grant) continue;
                if (heldHosts.has(grant.host)) continue;

                const chosenCovers = Array.from(port.chosenOrigins || []).some((chosen) => {
                  try {
                    return H.hostCovers(new URL(chosen).hostname, grant.host);
                  } catch (_e) { return false; }
                });
                if (chosenCovers) continue;

                const leftOutCovers = Array.from(effectiveLeftOut).some((exHost) => H.hostCovers(exHost, grant.host));
                if (leftOutCovers) continue;

                const res = port.ownerSites?.reservation;
                if (res && port.now() < res.expiresAt) {
                  if (res.pattern && H.classifySiteGrant(res.pattern)?.host === grant.host) continue;
                  if (res.origin) {
                    try {
                      if (H.hostCovers(new URL(res.origin).hostname, grant.host)) continue;
                    } catch (_e) {}
                  }
                }

                if (port.declinedHosts && port.declinedHosts.includes(grant.host)) continue;

                heldOffers.push(grant.origin);
                heldHosts.add(grant.host);
              }
              heldOffers.sort();

              if (deps.setCfg) {
                try {
                  await deps.setCfg({ offeredOrigins: heldOffers });
                } catch (_err) {
                  return { ok: false, error: "storage_error" };
                }
              }
              port.offeredOrigins = heldOffers;

              try {
                await DB.put("meta", Gate.CONSENT_VERSION, "consentVersion");
                port.consentVersion = Gate.CONSENT_VERSION;
                port.notify();
                return { ok: true, consentVersion: port.consentVersion };
              } catch (_err) {
                return { ok: false, error: "storage_error" };
              }
            });
          }
          return { ok: false, error: "invalid_consent_version" };
        }

        case "intendAddOrigin": {
          if (port.siteMode === "all") return { ok: false, error: "wrong_site_mode" };
          const origin = normalizeOrigin(msg.origin);
          if (!origin) return { ok: false, error: "invalid_origin" };
          let host = "";
          try {
            host = new URL(origin).host;
          } catch (_e) {
            return { ok: false, error: "invalid_origin" };
          }
          const pat = H && H.matchPatternFor ? H.matchPatternFor(host) : `*://${host}/*`;
          applyOwnerEvent(port, { type: "reserve", origin, pattern: pat, now: port.now() });
          return { ok: true };
        }

        case "clearAddIntent": {
          applyOwnerEvent(port, { type: "drop-reservation" });
          return { ok: true };
        }

        case "intendAllSites": {
          if (port.consentVersion !== Gate.CONSENT_VERSION) return { ok: false, error: "missing_consent" };
          applyOwnerEvent(port, {
            type: "reserve",
            origin: null,
            pattern: "*://*/*",
            now: port.now(),
            broadAlreadyLive: port.broadGranted === true,
          });
          return { ok: true };
        }

        case "setSiteMode": {
          if (!deps.updateSitePolicy) return { ok: false, error: "policy_unavailable" };
          return deps.updateSitePolicy(msg);
        }
        case "refreshSiteAccess": {
          if (!deps.refreshSiteAccess) return { ok: false, error: "policy_unavailable" };
          return deps.refreshSiteAccess();
        }

        case "dismissTruncation": {
          const origin = normalizeOrigin(msg.origin);
          const bound = typeof msg.bound === "string" ? msg.bound : String(msg.bound || "");
          if (!origin || !bound) return { ok: false, error: "invalid_params" };
          const result = port.dismissTruncation ? await port.dismissTruncation(origin, bound) : { ok: true, dismissed: false };
          return result?.ok === false ? result : { ok: true, dismissed: !!result?.dismissed };
        }

        case "addGrantedOrigin": {
          if (port.siteMode === "all") return { ok: false, error: "wrong_site_mode" };
          const origin = normalizeOrigin(msg.origin);
          if (!origin) return { ok: false, error: "invalid_origin" };

          return addGrantedOrigin(origin, deps);
        }

        case "declineOffer": {
          const origin = normalizeOrigin(msg.origin);
          if (!origin) return { ok: false, error: "invalid_origin" };
          let host = "";
          try { host = new URL(origin).hostname; } catch (_e) { return { ok: false, error: "invalid_origin" }; }
          applyOwnerEvent(port, { type: "decline-offer", host });
          port.offeredOrigins = (port.offeredOrigins || []).filter((o) => o !== origin);
          port.notify();

          const op = enqueueGrant(async () => {
            if (deps.walkRemoveSiteGrant) {
              await deps.walkRemoveSiteGrant(host);
            }
            if (deps.checkCleanDeclines) {
              await deps.checkCleanDeclines([host]);
            }
            if (deps.setCfg) {
              try {
                await deps.setCfg({
                  offeredOrigins: port.offeredOrigins,
                  declinedHosts: Array.from(port.declinedHosts || []),
                });
              } catch (_e) {
                return { ok: false, error: "storage_error" };
              }
            }
            port.notify();
            return { ok: true, origin };
          });
          op.finally(() => {
            runAdoptionPass(deps).catch(() => {});
          });
          return op;
        }

        case "adoptOffer": {
          const origin = normalizeOrigin(msg.origin);
          if (!origin) return { ok: false, error: "invalid_origin" };
          let host = "";
          try { host = new URL(origin).hostname; } catch (_e) { return { ok: false, error: "invalid_origin" }; }

          if (port.consentVersion !== Gate.CONSENT_VERSION) return { ok: false, error: "missing_consent" };
          if (port.siteMode !== "selected") return { ok: false, error: "wrong_site_mode" };

          const effectiveLeftOut = [...(port.excludedHosts || []), ...(port.appLeftOut || [])];
          if (effectiveLeftOut.some((site) => H.hostCovers(site, host))) {
            return { ok: false, error: "site_excluded" };
          }
          if (port.declinedHosts && port.declinedHosts.includes(host)) {
            return { ok: false, error: "declined" };
          }

          return enqueueGrant(async () => {
            let perms;
            try {
              perms = await chrome.permissions.getAll();
            } catch (_e) {
              return { ok: false, error: "permissions_unavailable" };
            }
            const live = perms?.origins || [];
            let matchingGrant = null;
            for (const pat of live) {
              const grant = H.classifySiteGrant(pat);
              if (!grant) continue;
              if (grant.origin === origin || grant.host === host) {
                matchingGrant = grant;
                break;
              }
            }
            if (!matchingGrant) {
              return { ok: false, error: "permission_not_granted" };
            }

            const start = ownerStateFor(port);
            const capturedGrantEpoch = start.grantEpoch;
            const capturedPermissionEpoch = start.permissionEpoch;

            const beginRes = applyOwnerEvent(port, {
              type: "begin-adopt",
              origins: [{ origin, siteWide: matchingGrant.siteWide }],
              capturedGrantEpoch,
              capturedPermissionEpoch,
            });
            if (!beginRes.result.ok) {
              return { ok: false, error: "capture_unavailable" };
            }

            const nextChosen = Array.from(new Set([...Array.from(port.chosenOrigins || []), origin])).sort();
            const nextSiteWide = matchingGrant.siteWide
              ? Array.from(new Set([...Array.from(port.siteWideOrigins || []), origin])).sort()
              : Array.from(port.siteWideOrigins || []);
            const nextOffered = (port.offeredOrigins || []).filter((o) => o !== origin);

            if (deps.setCfg) {
              try {
                await deps.setCfg({
                  chosenOrigins: nextChosen,
                  siteWideOrigins: nextSiteWide,
                  offeredOrigins: nextOffered,
                });
              } catch (_e) {
                return { ok: false, error: "storage_error" };
              }
            }

            const fenceRes = applyOwnerEvent(port, {
              type: "fence-adopt",
              origins: [{ origin, siteWide: matchingGrant.siteWide }],
              capturedGrantEpoch,
              capturedPermissionEpoch,
              phase: "after-choice-write",
            });
            if (!fenceRes.result.ok) {
              // Storage was written ahead of memory; put it back to what memory holds.
              if (deps.setCfg) {
                try {
                  await deps.setCfg({
                    chosenOrigins: Array.from(port.chosenOrigins || []),
                    siteWideOrigins: Array.from(port.siteWideOrigins || []),
                    offeredOrigins: Array.from(port.offeredOrigins || []),
                  });
                } catch (_e) {}
              }
              return { ok: false, error: "capture_unavailable" };
            }

            port.siteWideOrigins = nextSiteWide;
            port.offeredOrigins = nextOffered;

            applyOwnerEvent(port, {
              type: "publish-grants",
              livePatterns: live,
              epochAtStart: capturedPermissionEpoch,
            });

            if (typeof deps.registerSite === "function") {
              try { await deps.registerSite(matchingGrant.host); } catch (_e) {}
            }

            port.notify();
            deps.refreshOpenTabs?.();
            return { ok: true, origin };
          });
        }

        case "setLeftOut": {
          const host = H && H.excludedHostname ? H.excludedHostname(msg.host) : null;
          if (!host || host !== msg.host) return { ok: false, error: "invalid_host" };
          const out = !!msg.out;

          if (out) {
            if (!port.excludedHosts.includes(host)) {
              port.excludedHosts = [...port.excludedHosts, host].sort();
            }
            // A frame commit already in flight re-saves the current set when
            // this changes, so it can never write an older snapshot over it.
            port.excludedGen = (port.excludedGen || 0) + 1;
            if (port.siteMode === "selected") {
              applyOwnerEvent(port, { type: "selected-leave-out", host });
            }
            port.notify();

            const op = enqueueGrant(async () => {
              const declinedList = [host];
              if (port.siteMode === "selected") {
                let livePerms = [];
                try {
                  const p = typeof chrome !== "undefined" && chrome.permissions?.getAll ? await chrome.permissions.getAll() : null;
                  livePerms = p?.origins || [];
                } catch (_e) {}
                const liveGrantHosts = [];
                for (const pat of livePerms) {
                  if (pat === "*://*/*" || pat === "<all_urls>") continue;
                  const grant = H.classifySiteGrant(pat);
                  if (grant && (grant.host === host || H.hostCovers(host, grant.host))) {
                    liveGrantHosts.push(grant.host);
                    if (!declinedList.includes(grant.host)) declinedList.push(grant.host);
                  }
                }
                applyOwnerEvent(port, { type: "selected-leave-out", host, coveringHosts: liveGrantHosts });
                if (deps.walkRemoveSiteGrant) {
                  await deps.walkRemoveSiteGrant(host, { livePatterns: livePerms });
                }
                if (deps.checkCleanDeclines) {
                  await deps.checkCleanDeclines(declinedList);
                }
              }

              if (deps.setCfg) {
                try {
                  const patch = { excludedHosts: [...port.excludedHosts] };
                  if (port.siteMode === "selected") {
                    patch.declinedHosts = Array.from(port.declinedHosts || []);
                  }
                  await deps.setCfg(patch);
                } catch (_e) {
                  await deps.syncSiteRegistrations?.();
                  return { ok: false, error: "storage_error" };
                }
              }

              if (port.leftOutCapable && typeof port.queueSiteRule === "function") {
                port.queueSiteRule(host, true);
              }

              await deps.syncSiteRegistrations?.();
              return { ok: true, host, out: true };
            });
            op.finally(() => {
              runAdoptionPass(deps).catch(() => {});
            });
            return op;
          } else {
            let res;
            if (typeof port.commitInclude === "function") {
              try {
                res = await port.commitInclude(host, deps.setCfg);
              } catch (_e) {
                return { ok: false, error: "storage_error" };
              }
            } else {
              if (deps.setCfg) {
                try {
                  await deps.setCfg({ excludedHosts: port.excludedHosts.filter((h) => h !== host) });
                } catch (_e) {
                  return { ok: false, error: "storage_error" };
                }
              }
              port.excludedHosts = port.excludedHosts.filter((h) => h !== host);
              port.notify();
              if (typeof port.includeHost === "function") {
                port.includeHost(host);
              }
              res = { ok: true, host, out: false };
            }
            await deps.syncSiteRegistrations?.();
            return res;
          }
        }

        case "dismissAdoptionNotices": {
          port.adoptionNotices = [];
          port.notify();
          return { ok: true };
        }

        case "removeGrantedOrigin": {
          const origin = normalizeOrigin(msg.origin);
          if (!origin) return { ok: false, error: "invalid_origin" };
          let host = "";
          try { host = new URL(origin).hostname; } catch (_e) { return { ok: false, error: "invalid_origin" }; }

          if (!Array.isArray(port.pendingRemoveOrigins)) port.pendingRemoveOrigins = [];
          if (!port.pendingRemoveOrigins.includes(origin)) port.pendingRemoveOrigins.push(origin);
          const broadcast = typeof deps.broadcastLeaseUpdate === "function"
            ? deps.broadcastLeaseUpdate
            : (typeof port.broadcastLeaseUpdate === "function" ? (s) => port.broadcastLeaseUpdate(s) : null);
          if (broadcast) {
            broadcast(port.getStatus());
          }
          port.notify();

          const op = enqueueGrant(async () => {
            try {
              let perms;
              try {
                perms = await chrome.permissions.getAll();
              } catch (_e) {
                return { ok: false, error: "permissions_unavailable" };
              }
              const live = perms?.origins || [];
              const coveringHosts = [];
              for (const pat of live) {
                if (pat === "*://*/*" || pat === "<all_urls>") continue;
                const grant = H.classifySiteGrant(pat);
                if (!grant) continue;
                if (grant.host === host || H.hostCovers(host, grant.host)) {
                  // A sub-site the owner still has chosen is not declined with its parent.
                  const stillChosen = grant.host !== host && Array.from(port.chosenOrigins || []).some((o) => {
                    try { return new URL(o).hostname === grant.host; } catch (_e) { return false; }
                  });
                  if (!stillChosen && !coveringHosts.includes(grant.host)) coveringHosts.push(grant.host);
                }
              }
              applyOwnerEvent(port, { type: "owner-remove", origin, coveringHosts });
              port.notify();

              let saved = true;
              if (deps.setCfg) {
                try {
                  const patch = {
                    chosenOrigins: Array.from(port.chosenOrigins || []),
                    siteWideOrigins: Array.from(port.siteWideOrigins || []),
                    declinedHosts: Array.from(port.declinedHosts || []),
                  };
                  if (port.exactOnlyKnown !== false) patch.exactOnlyOrigins = Array.from(port.exactOnlyOrigins || []).sort();
                  await deps.setCfg(patch);
                } catch (_e) {
                  saved = false;
                }
              }

              if (deps.walkRemoveSiteGrant) {
                await deps.walkRemoveSiteGrant(host, { livePatterns: live });
              }
              if (deps.checkCleanDeclines) {
                const prevDeclined = Array.from(port.declinedHosts || []);
                await deps.checkCleanDeclines([host, ...coveringHosts]);
                const nextDeclined = Array.from(port.declinedHosts || []);
                const changed = prevDeclined.length !== nextDeclined.length ||
                  prevDeclined.some((h, i) => h !== nextDeclined[i]);
                if (changed && deps.setCfg) {
                  try {
                    await deps.setCfg({ declinedHosts: nextDeclined });
                  } catch (_e) {
                    saved = false;
                  }
                }
              }

              if (port.clearSiteErrorsWhere) await port.clearSiteErrorsWhere((item) => item === origin);
              deps.refreshOpenTabs?.();

              if (typeof deps.removeSiteOrigin === "function") {
                await deps.removeSiteOrigin(origin).catch(() => {});
              } else if (typeof deps.unregisterSite === "function") {
                try { await deps.unregisterSite(host); } catch (_e) {}
              }

              await Outbox.markAllSnapshotRequired().catch(() => {});
              port.notify();
              if (!saved) return { ok: false, saved: false, origin };
              return { ok: true, origin, saved: true };
            } finally {
              if (Array.isArray(port.pendingRemoveOrigins)) {
                port.pendingRemoveOrigins = port.pendingRemoveOrigins.filter((o) => o !== origin);
              }
              if (broadcast) {
                broadcast(port.getStatus());
              }
              port.notify();
            }
          });
          op.finally(() => {
            runAdoptionPass(deps).catch(() => {});
          });
          return op;
        }

        case "setPaused": {
          const desired = !!msg.paused;
          const epoch = ++pauseEpoch;
          if (desired) { port.paused = true; port.notify(); }
          let saveOk = false;
          if (deps.setCfg) {
            try {
              await deps.setCfg({ paused: desired });
              saveOk = true;
            } catch (_e) {
              saveOk = false;
            }
          } else {
            saveOk = true;
          }

          if (!saveOk) {
            if (desired) {
              port.paused = true;
            }
            port.notify();
            return { ok: false, saved: false, paused: port.paused };
          }

          if (epoch !== pauseEpoch) return { ok: false, error: "superseded" };
          port.paused = desired;
          if (typeof deps.broadcastPause === "function") {
            deps.broadcastPause(port.paused);
          }
          if (port.paused) {
            await Outbox.markAllSnapshotRequired().catch(() => {});
          }
          port.notify();
          return { ok: true, paused: port.paused, saved: true };
        }

        case "setConfig": {
          let hasChange = false;
          const patch = {};
          const prevShowPageIndicator = port.showPageIndicator;
          const prevPauseWithApp = port.pauseWithApp;

          if (typeof msg.showPageIndicator === "boolean") {
            port.showPageIndicator = msg.showPageIndicator;
            patch.showPageIndicator = port.showPageIndicator;
            hasChange = true;
          }
          if (typeof msg.pauseWithApp === "boolean") {
            port.pauseWithApp = msg.pauseWithApp;
            patch.pauseWithApp = port.pauseWithApp;
            hasChange = true;
          }

          if (hasChange) {
            let saveOk = false;
            if (deps.setCfg) {
              try {
                await deps.setCfg(patch);
                saveOk = true;
              } catch (_e) {
                saveOk = false;
              }
            } else {
              saveOk = true;
            }

            if (!saveOk) {
              port.showPageIndicator = prevShowPageIndicator;
              port.pauseWithApp = prevPauseWithApp;
              port.notify();
              return { ok: false, error: "storage_error" };
            }

            if (Object.hasOwn(patch, "showPageIndicator") && typeof deps.broadcastIndicator === "function") {
              deps.broadcastIndicator(port.showPageIndicator);
            }
            if (Object.hasOwn(patch, "pauseWithApp") && typeof port.reapplyLastCapture === "function") {
              await port.reapplyLastCapture();
            }
            port.notify();
            return { ok: true };
          }
          return { ok: true };
        }

        case "dismissLoss": {
          const seq = Number(msg.seq);
          const dismissed = await Outbox.dismissLoss(seq);
          if (dismissed && port.lossNotice && port.lossNotice.seq === seq) {
            port.lossNotice = null;
            port.notify();
          }
          return { ok: true, dismissed };
        }

        default:
          return { ok: false, error: "unknown_command" };
      }
    }

    if (!sender.tab || sender.tab.id == null) {
      return { ok: false, error: "unauthorized" };
    }
    // Safari ignores the manifest's private-window exclusion once the owner
    // allows the extension there, so private tabs are refused here as well.
    if (sender.tab.incognito === true) {
      return { ok: false, error: "private_window" };
    }

    const tabId = sender.tab.id;
    const frameId = sender.frameId || 0;
    const browserDocumentId = sender.documentId || null;

    let senderOrigin = null;
    let senderUrl = "";

    if (sender.url === "about:blank") {
      senderOrigin = normalizeOrigin(sender.origin);
      if (!senderOrigin || !originGranted(port, senderOrigin)) {
        return { ok: false, error: "origin_not_granted" };
      }
      senderUrl = Blocks.originPath(senderOrigin + "/");
    } else {
      senderOrigin = normalizeOrigin(sender.origin || (sender.url ? new URL(sender.url).origin : ""));
      if (!senderOrigin || !originGranted(port, senderOrigin)) {
        return { ok: false, error: "origin_not_granted" };
      }
      senderUrl = Blocks.originPath(sender.url || "");
    }

    let frameSite = "";
    try {
      frameSite = new URL(senderUrl).host;
    } catch (_e) {
      frameSite = senderOrigin;
    }

    const realmToken = msg.realmToken;
    if (!realmToken || typeof realmToken !== "string") {
      return { ok: false, error: "missing_realm_token" };
    }
    const documentKey = typeof msg.documentKey === "string" && /^[0-9a-f]{32}$/.test(msg.documentKey) ? msg.documentKey : null;
    if (!browserDocumentId && !documentKey) return { ok: false, error: "missing_document_key" };
    const documentIdentity = browserDocumentId || documentKey;

    const fKey = frameKeyFor(tabId, frameId, documentIdentity);
    const challengeKey = `${tabId}:${frameId}`;
    let binding = frameBindings.get(fKey);
    if (msg.kind === "hello") {
      // Ask the live frame which realm is running. A delayed message from a
      // retired document cannot appoint itself the current realm (Firefox 140
      // does not supply documentId).
      const challenge = {};
      frameChallenges.set(challengeKey, challenge);
      let confirmed = false;
      try {
        if (deps.confirmRealm) {
          confirmed = await deps.confirmRealm(tabId, frameId, realmToken, browserDocumentId || documentKey);
        } else if (typeof chrome !== "undefined" && chrome.tabs?.sendMessage) {
          const response = await chrome.tabs.sendMessage(tabId, { kind: "confirmRealm" }, { frameId });
          confirmed = response?.realmToken === realmToken;
        }
      } catch (_e) {}
      if (!confirmed || frameChallenges.get(challengeKey) !== challenge) {
        return { ok: false, error: "challenge_mismatch" };
      }
      binding = frameBindings.get(fKey);
      if (binding && (binding.realmToken !== realmToken || binding.documentIdentity !== documentIdentity || binding.origin !== senderOrigin)) {
        const old = frameBindings.get(fKey);
        if (old && Outbox.pruneCursor) Outbox.pruneCursor(old.inst, old.ctx).catch(() => {});
        frameBindings.delete(fKey);
        binding = null;
      }
      if (!binding) {
        // A frame has one live document. Drop prior document bindings only
        // after the live realm challenge confirms this hello.
        const prefix = `${tabId}:${frameId}:`;
        for (const [key, previous] of frameBindings) {
          if (key !== fKey && key.startsWith(prefix)) {
            if (Outbox.pruneCursor) Outbox.pruneCursor(previous.inst, previous.ctx).catch(() => {});
            frameBindings.delete(key);
          }
        }
        binding = { tabId, frameId, realmToken, documentIdentity, documentKey,
          origin: senderOrigin, ctx: mintCtx(), url: senderUrl, inst: port.inst };
        frameBindings.set(fKey, binding);
      }
    } else if (!binding || binding.realmToken !== realmToken || binding.documentIdentity !== documentIdentity || binding.origin !== senderOrigin ||
        (!browserDocumentId && binding.documentKey !== documentKey)) {
      return { ok: false, error: "challenge_mismatch" };
    }

    switch (msg.kind) {
      case "hello": {
        port.syncCaptureAuthority?.();
        return {
          captureEpoch: port.captureEpoch,
          ok: true,
          ctx: binding ? binding.ctx : null,
          lease: port.lease ? { ...port.lease, freshnessMs: Math.max(0, Math.floor(port.lease.receivedAt + port.lease.freshnessMs - port.now())) } : null,
          consentVersion: port.consentVersion,
          paused: port.paused,
          showPageIndicator: port.showPageIndicator,
          grantedOrigins: Array.from(port.grantedOrigins),
          exactOnlyOrigins: Array.from(port.exactOnlyOrigins || []),
          siteWideOrigins: Array.from(port.siteWideOrigins || []),
          pendingRemoveOrigins: Array.from(port.pendingRemoveOrigins || []),
          siteMode: port.siteMode || "selected",
          excludedHosts: [...(port.excludedHosts || [])],
          appLeftOut: [...(port.appLeftOut || [])],
          allSitesConsent: port.allSitesConsent || 0,
          broadGranted: port.broadGranted === true,
          hostCapture: port.hostCapture,
          hostDelivery: port.hostDelivery,
          hostFailure: port.hostFailure,
          custody: port.custody ? { ...port.custody } : null,
          pressure: { ...port.pressure },
          capturePermitted: port.capturePermitted === true,
          connectionGeneration: port.connectionGeneration,
          destinationGeneration: port.destinationGeneration,
        };
      }

      case "read": {
        if (port.siteMode !== "all" || !binding || !deps.executeBrowserRead ||
            !Number.isSafeInteger(msg.requestId) || !["skim", "observe", "root"].includes(msg.action)) return { ok: false, error: "invalid_read" };
        port.syncCaptureAuthority?.();
        const decision = Gate.computeDecision({
          lease: port.lease, paused: port.paused, consentVersion: port.consentVersion,
          originGranted: originGranted(port, senderOrigin), pressure: port.pressure,
          hostCapture: port.hostCapture, capturePermitted: port.capturePermitted === true, now: port.now(),
        });
        if (!decision.open || msg.captureEpoch !== port.captureEpoch || msg.leaseToken !== port.lease?.token) {
          return { ok: false, error: "authority_mismatch" };
        }
        if (binding.readPending) return { ok: false, error: "read_pending" };
        const nonce = mintCtx();
        const admittedEpoch = port.captureEpoch;
        const admittedPermissionEpoch = port.permissionEpoch;
        const authorize = () => {
          port.syncCaptureAuthority?.();
          return frameBindings.get(fKey) === binding && port.captureEpoch === admittedEpoch &&
            port.permissionEpoch === admittedPermissionEpoch && originGranted(port, senderOrigin) &&
            Gate.computeDecision({lease:port.lease, paused:port.paused, consentVersion:port.consentVersion,
              originGranted:true, pressure:port.pressure, hostCapture:port.hostCapture,
              capturePermitted:port.capturePermitted === true, now:port.now()}).open;
        };
        binding.readPending = true;
        binding.readNonce = nonce;
        binding.readPermissionEpoch = admittedPermissionEpoch;
        try {
          const result = await deps.executeBrowserRead(binding, { nonce, action: msg.action,
            reason: msg.reason, requestId: msg.requestId, captureEpoch: admittedEpoch, leaseToken: port.lease.token }, authorize);
          if (!authorize()) return { ok: false, error: "authority_mismatch" };
          if (result !== true) return { ok: false, error: "read_not_executed" };
          if (port.browserDeniedOrigins?.delete(senderOrigin)) port.notify();
          return { ok: true };
        } catch (_e) {
          if (binding.readNonce === nonce) binding.readNonce = null;
          port.browserDeniedOrigins?.add(senderOrigin);
          port.notify();
          return { ok: false, error: "browser_access_denied" };
        } finally { binding.readPending = false; }
      }

      case "skim": {
        if (!binding) {
          return { ok: false, error: "challenge_mismatch" };
        }
        if (port.siteMode === "all") {
          if (!msg.readNonce || binding.readNonce !== msg.readNonce || binding.readPermissionEpoch !== port.permissionEpoch) {
            return { ok: false, error: "read_not_authorized" };
          }
          binding.readNonce = null;
        }
        const nowMs = port.now();
        const codec = globalThis.SolstoneNativeBrowser;

        if (
          (!Number.isSafeInteger(msg.captureEpoch) || msg.captureEpoch < 0 || msg.captureEpoch !== port.captureEpoch) ||
          (msg.connectionGeneration !== port.connectionGeneration) ||
          (msg.destinationGeneration !== port.destinationGeneration) ||
          (!msg.leaseToken || !port.lease || msg.leaseToken !== port.lease.token)
        ) {
          return { ok: false, error: "authority_mismatch" };
        }

        const meta = msg.meta || {};
        const title = typeof meta.title === "string" ? meta.title : "";
        const adapter = typeof meta.adapter === "string" ? meta.adapter : "generic";
        const blocksList = Array.isArray(msg.blocks) ? msg.blocks : [];

        const admittedEpoch = port.captureEpoch;
        const authorize = () => {
          port.syncCaptureAuthority?.();
          if (port.captureEpoch !== admittedEpoch || msg.captureEpoch !== admittedEpoch) return false;
          const currentNow = port.now();
          const decision = Gate.computeDecision({
            lease: port.lease,
            paused: port.paused,
            consentVersion: port.consentVersion,
            originGranted: originGranted(port, senderOrigin),
            pressure: port.pressure,
            hostCapture: port.hostCapture,
            capturePermitted: port.capturePermitted === true,
            now: currentNow,
          });
          if (!decision.open || frameBindings.get(fKey) !== binding) return false;
          if (port.connectionGeneration !== msg.connectionGeneration) return false;
          if (port.destinationGeneration !== msg.destinationGeneration) return false;
          if (!msg.leaseToken || !port.lease || port.lease.token !== msg.leaseToken) return false;
          return true;
        };

        const clips = Array.isArray(msg.clips) ? Array.from(new Set(msg.clips.filter((clip) => ["blocks", "text", "label"].includes(clip)))).sort() : [];
        let tab = null;
        let win = null;
        try {
          if (typeof chrome !== "undefined" && chrome.tabs?.get && Number.isInteger(tabId)) {
            const fetchedTab = await chrome.tabs.get(tabId);
            if (fetchedTab && fetchedTab.windowId != null && chrome.windows?.get) {
              const fetchedWin = await chrome.windows.get(fetchedTab.windowId);
              if (fetchedWin) {
                tab = fetchedTab;
                win = fetchedWin;
              }
            }
          }
        } catch (_e) {
          tab = null;
          win = null;
        }

        let ageMs;
        try {
          if (globalThis.SolstoneTabAge && typeof globalThis.SolstoneTabAge.ageMs === "function") {
            ageMs = await globalThis.SolstoneTabAge.ageMs(tabId, port.wallNow());
          }
        } catch (_e) {}

        let browser = null;
        try {
          if (typeof deps.getBrowserIdentity === "function") {
            browser = await deps.getBrowserIdentity();
          } else if (globalThis.SolstonePageFacts?.mapBrowser) {
            browser = await globalThis.SolstonePageFacts.mapBrowser({});
          }
        } catch (_e) {}

        let ext = "";
        try {
          if (typeof chrome !== "undefined" && chrome.runtime?.getManifest) {
            ext = chrome.runtime.getManifest()?.version || "";
          }
        } catch (_e) {}

        const solstonePaused = port.appReportedPaused ? port.appReportedPaused() === true : false;

        const pageContext = globalThis.SolstonePageFacts?.assemble ? globalThis.SolstonePageFacts.assemble({
          tabId,
          frameId,
          page: msg.page,
          tab,
          window: win,
          ageMs,
          browser,
          ext,
          solstonePaused,
        }) : undefined;

        try {
          const enqueueArgs = {
            inst: port.inst,
            ctx: binding.ctx,
            destinationGeneration: port.destinationGeneration,
            senderUrl,
            site: frameSite,
            title,
            adapter,
            blocks: blocksList,
            pageContext,
            nowMs: Date.now(),
            monotonicNow: port.now(),
            authorize,
          };
          const result = await port.enqueueObservedSkim(enqueueArgs, senderOrigin, {
            clips,
            slot: `${tabId}:${frameId}`, documentId: binding.documentIdentity, omitted: msg.omitted === true,
          });

          if (!authorize()) return { ok: false, error: "authority_mismatch" };

          // Errors and notes are kept on the chosen site the page belongs to
          // (bank.com for login.bank.com), where the owner sees its row.
          const siteKey = siteKeyFor(port, senderOrigin);
          // A page from this site was just read, so "reload this tab" is over.
          if (port.registration?.[siteKey] === "reload" && port.clearSiteError) {
            await port.clearSiteError("registration", siteKey);
          }
          if (result && result.enqueued) {
            if (result.pressure) port.pressure = result.pressure;
            if (port.clearSiteError) await port.clearSiteError("enqueue", siteKey);
            port.notify();
            port.drain();
          } else if (port.clearSiteError) {
            await port.clearSiteError("enqueue", siteKey);
          }

          return {
            ok: true,
            result: {
              enqueued: !!result.enqueued,
              disposition: result.disposition || null,
              batchId: result.batchId || null,
              seq: result.seq || null,
            },
          };
        } catch (err) {
          // The app renewed its grant while this page was being written. The
          // next grant brings a fresh read, so this is not the site's fault.
          if (err?.code === "authorization_failed") return { ok: false, error: "authorization_failed" };
          let noticeBound = "enqueue_failed";
          if (err.disposition === "batch-oversize" || err.code === "batch-oversize") noticeBound = "batch-oversize";
          else if (err.disposition === "schema-refuse" || err.code === "schema-refuse") noticeBound = "schema-refuse";
          else if (err.disposition === "outbox-full" || err.code === "outbox-full") {
            noticeBound = "outbox-full";
            try {
              const cap = await Outbox.getCapacityStatus();
              port.pressure = { active: true, blockedAtBytes: cap.totalBytes };
            } catch (_e) {}
          }
          // The owner may have removed or left out the site while this failed.
          if (port.setEnqueueError && originGranted(port, senderOrigin)) await port.setEnqueueError(siteKeyFor(port, senderOrigin), noticeBound);
          port.notify();
          return { ok: false, error: err.code || "enqueue_failed" };
        }
      }

      case "bye": {
        destroyBinding(tabId, frameId);
        return { ok: true };
      }

      default:
        return { ok: false, error: "unknown_message_kind" };
    }
  }

  globalThis.SolstoneRouter = {
    grantChainBusy: () => grantChainDepth > 0,
    completeReservedOrigin,
    runAdoptionPass,
    route,
    applyOwnerEvent,
    ownerStateFor,
    destroyBinding,
    normalizeOrigin,
    isExtensionPageSender,
    frameBindings,
    frameChallenges,
  };
})();
