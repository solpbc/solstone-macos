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
  let pauseEpoch = 0;

  function ownerStateFor(port) {
    const current = port.ownerSites || {};
    return {
      grantEpoch: Number.isSafeInteger(current.grantEpoch) ? current.grantEpoch : 0,
      permissionEpoch: Number.isSafeInteger(port.permissionEpoch) ? port.permissionEpoch : 0,
      chosen: Array.from(port.chosenOrigins || []),
      granted: Array.from(port.grantedOrigins || []),
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
    };
    port.permissionEpoch = state.permissionEpoch;
    port.chosenOrigins = new Set(state.chosen);
    port.grantedOrigins = new Set(state.granted);
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
    const operation = grantChain.catch(() => {}).then(async () => {
      await deps.settlePermissionEffects?.();
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

      const pat = H && H.matchPatternFor ? H.matchPatternFor(host) : `*://${host}/*`;
      let hasPerm = false;
      try {
        if (typeof chrome !== "undefined" && chrome.permissions?.contains) {
          hasPerm = await chrome.permissions.contains({ origins: [pat] });
        } else if (typeof chrome !== "undefined" && chrome.permissions?.getAll) {
          const perms = await chrome.permissions.getAll();
          hasPerm = Array.isArray(perms?.origins) && (perms.origins.includes(pat) || perms.origins.includes("*://*/*"));
        } else {
          hasPerm = false;
        }
      } catch (_e) {
        hasPerm = false;
      }

      if (reservation && (port.ownerSites?.reservation !== reservation || port.now() >= reservation.expiresAt)) {
        return { ok: false, error: "capture_unavailable" };
      }
      const liveAuth = !port.paused && !port.pressure?.active && port.consentVersion === Gate.CONSENT_VERSION &&
        port.capturePermitted === true && port.hostCapture === "permitted" && port.custody?.full !== true &&
        port.lease && port.now() < port.lease.receivedAt + port.lease.freshnessMs;
      const admission = applyOwnerEvent(port, {
        type: "begin-add", origin, now: port.now(), liveAuth: !!liveAuth, hasPerm,
        capturedGrantEpoch, capturedPermissionEpoch,
      });
      if (!admission.result.ok) return admission.result;

      const nextChosen = Array.from(new Set([...Array.from(port.chosenOrigins || []), origin]));
      try {
        if (deps.setCfg) await deps.setCfg({ chosenOrigins: nextChosen });
      } catch (_e) {
        applyOwnerEvent(port, { type: "drop-reservation" });
        return { ok: false, error: "storage_error" };
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
    grantChain = operation;
    return operation;
  }

  function completeReservedOrigin(reservation, deps) {
    return addGrantedOrigin(reservation.origin, deps, reservation);
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
          return { ok: true, ...port.getStatus() };
        }

        case "acknowledgeDisclosure": {
          if (msg.version === Gate.CONSENT_VERSION) {
            try {
              await DB.put("meta", Gate.CONSENT_VERSION, "consentVersion");
              port.consentVersion = Gate.CONSENT_VERSION;
              port.notify();
              return { ok: true, consentVersion: port.consentVersion };
            } catch (_err) {
              return { ok: false, error: "storage_error" };
            }
          }
          return { ok: false, error: "invalid_consent_version" };
        }

        case "intendAddOrigin": {
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

        case "dismissTruncation": {
          const origin = normalizeOrigin(msg.origin);
          const bound = typeof msg.bound === "string" ? msg.bound : String(msg.bound || "");
          if (!origin || !bound) return { ok: false, error: "invalid_params" };
          const result = port.dismissTruncation ? await port.dismissTruncation(origin, bound) : { ok: true, dismissed: false };
          return result?.ok === false ? result : { ok: true, dismissed: !!result?.dismissed };
        }

        case "addGrantedOrigin": {
          const origin = normalizeOrigin(msg.origin);
          if (!origin) return { ok: false, error: "invalid_origin" };

          return addGrantedOrigin(origin, deps);
        }

        case "removeGrantedOrigin": {
          const origin = normalizeOrigin(msg.origin);
          if (!origin) return { ok: false, error: "invalid_origin" };

          applyOwnerEvent(port, { type: "owner-remove", origin });
          port.notify();
          deps.refreshOpenTabs?.();
          let saved = true;
          if (deps.setCfg) {
            try {
              await deps.setCfg({ chosenOrigins: Array.from(port.chosenOrigins || []) });
            } catch (_e) {
              saved = false;
            }
          }

          if (typeof deps.removeSiteOrigin === "function") {
            await deps.removeSiteOrigin(origin).catch(() => {});
          } else if (typeof deps.unregisterSite === "function") {
            try {
              const u = new URL(origin);
              const matchHost = H && H.matchHostFor ? H.matchHostFor(u.host) : u.hostname;
              const hasSibling = Array.from(port.chosenOrigins || []).some((o) => {
                try {
                  const sHost = H && H.matchHostFor ? H.matchHostFor(new URL(o).host) : new URL(o).hostname;
                  return sHost === matchHost;
                } catch (_e) { return false; }
              });
              if (!hasSibling) {
                await deps.unregisterSite(u.host);
              }
            } catch (_e) {
              /* ignore */
            }
          }

          await Outbox.markAllSnapshotRequired().catch(() => {});
          port.notify();
          if (!saved) return { ok: false, saved: false, origin };
          return { ok: true, origin, saved: true };
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
          if (typeof msg.showPageIndicator === "boolean") {
            const prev = port.showPageIndicator;
            port.showPageIndicator = msg.showPageIndicator;
            let saveOk = false;
            if (deps.setCfg) {
              try {
                await deps.setCfg({ showPageIndicator: port.showPageIndicator });
                saveOk = true;
              } catch (_e) {
                saveOk = false;
              }
            } else {
              saveOk = true;
            }

            if (!saveOk) {
              port.showPageIndicator = prev;
              port.notify();
              return { ok: false, error: "storage_error" };
            }

            if (typeof deps.broadcastIndicator === "function") {
              deps.broadcastIndicator(port.showPageIndicator);
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
      if (!senderOrigin || !port.grantedOrigins.has(senderOrigin)) {
        return { ok: false, error: "origin_not_granted" };
      }
      senderUrl = Blocks.originPath(senderOrigin + "/");
    } else {
      senderOrigin = normalizeOrigin(sender.origin || (sender.url ? new URL(sender.url).origin : ""));
      if (!senderOrigin || !port.grantedOrigins.has(senderOrigin)) {
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

      case "skim": {
        if (!binding) {
          return { ok: false, error: "challenge_mismatch" };
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
            originGranted: port.grantedOrigins.has(senderOrigin),
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
            nowMs: Date.now(),
            monotonicNow: port.now(),
            authorize,
          };
          const result = await port.enqueueObservedSkim(enqueueArgs, senderOrigin, {
            clips,
            slot: `${tabId}:${frameId}`, documentId: binding.documentIdentity, omitted: msg.omitted === true,
          });

          if (!authorize()) return { ok: false, error: "authority_mismatch" };

          if (result && result.enqueued) {
            if (result.pressure) port.pressure = result.pressure;
            if (port.clearSiteError) await port.clearSiteError("enqueue", senderOrigin);
            port.notify();
            port.drain();
          } else if (port.clearSiteError) {
            await port.clearSiteError("enqueue", senderOrigin);
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
          if (port.setEnqueueError) await port.setEnqueueError(senderOrigin, noticeBound);
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
    completeReservedOrigin,
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
