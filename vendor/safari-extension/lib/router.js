// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const Blocks = globalThis.SolstoneBlocks;
  const DB = globalThis.SolstoneDB;
  const Gate = globalThis.SolstoneCaptureGate;
  const Outbox = globalThis.SolstoneNativeOutbox;
  const H = globalThis.SolstoneHosts;

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
  let agreeInFlight = false;

  function originGranted(port, origin) {
    return H.originGranted(port, origin);
  }

  function siteKeyFor(port, origin) {
    return H.pageRowOrigin ? H.pageRowOrigin(port?.livePatterns, origin) : origin;
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

  async function clearMatchingIntent(port, origin, deps) {
    if (!port.addIntent || port.addIntent.origin !== origin) return;
    port.addIntent = null;
    if (deps.setCfg) await deps.setCfg({ addIntent: null });
  }

  // Join a site the browser already covers. A fence entry is kept only when the
  // origin is granted afterwards. Nothing here asks the browser for a permission.
  async function joinedOrigin(port, origin, deps) {
    if (port.fence !== null && typeof port.fence === "object") {
      const next = H.admitFenceOrigin(
        port.fence,
        origin,
        port.livePatterns || [],
        port.excludedHosts,
        port.appLeftOut,
      );
      const granted = next && H.originGranted({
        fence: next,
        livePatterns: port.livePatterns || [],
        excludedHosts: port.excludedHosts,
        appLeftOut: port.appLeftOut,
      }, origin);
      if (!granted) return null;
      port.fence = next;
      const patch = { fence: port.fence };
      if (port.addIntent && port.addIntent.origin === origin) {
        port.addIntent = null;
        patch.addIntent = null;
      }
      if (deps.setCfg) await deps.setCfg(patch);
      port.notify();
      deps.refreshOpenTabs?.();
      if (!H.originGranted(port, origin)) return null;
      await deps.syncSiteRegistrations?.();
      return { ok: true, origin };
    }
    let url;
    try { url = new URL(origin); } catch (_e) { return null; }
    const covered = (port.livePatterns || []).some((pattern) => H.plainAllow(pattern, url));
    if (!covered || !H.originGranted(port, origin)) return null;
    if (port.addIntent && port.addIntent.origin === origin) {
      port.addIntent = null;
      if (deps.setCfg) await deps.setCfg({ addIntent: null });
    }
    port.notify();
    deps.refreshOpenTabs?.();
    return { ok: true, origin };
  }

  function addGrantedOrigin(origin, deps) {
    const port = deps.port;
    return enqueueGrant(async () => {
      if (!Gate.consentAccepted(port.consentVersion)) {
        return { ok: false, error: "missing_consent" };
      }
      try {
        const url = new URL(origin);
        if (url.protocol !== "http:" && url.protocol !== "https:") {
          return { ok: false, error: "invalid_origin" };
        }
      } catch (_e) {
        return { ok: false, error: "invalid_origin" };
      }

      const already = await joinedOrigin(port, origin, deps);
      if (already) return already;

      if (typeof deps.beginRead === "function") {
        const read = await deps.beginRead();
        if (Array.isArray(read)) port.livePatterns = read;
      }

      const after = await joinedOrigin(port, origin, deps);
      if (after) return after;

      await clearMatchingIntent(port, origin, deps);
      return { ok: false, result: "not_added" };
    });
  }

  // The browser's list, with no tombstone filter. Removal judges this.
  // Intents and the gate stay on the filtered read. A throw is the only failure;
  // a missing or non-array list is an empty success.
  async function listedOrigins() {
    try {
      const perms = await chrome.permissions.getAll();
      const origins = perms?.origins;
      if (!Array.isArray(origins)) return { ok: true, origins: [] };
      return { ok: true, origins: origins.filter((pattern) => typeof pattern === "string") };
    } catch (_e) {
      return { ok: false, error: "permissions_unavailable" };
    }
  }

  // Non-broad grants whose row is this origin, as the browser spells them.
  function patternsForOrigin(origins, rowOrigin) {
    return (origins || []).filter((pattern) => !H.isBroadPattern(pattern) && H.grantRowOrigin(pattern) === rowOrigin);
  }

  async function removePatterns(patterns) {
    for (const pattern of patterns) {
      try { await chrome.permissions.remove({ origins: [pattern] }); } catch (_e) {}
    }
  }

  function removeGrantedOrigin(origin, deps) {
    const port = deps.port;
    let url = null;
    let host = "";
    try {
      url = new URL(origin);
      host = url.hostname;
    } catch (_e) {
      return Promise.resolve({ ok: false, error: "invalid_origin" });
    }

    return enqueueGrant(async () => {
      const listed = await listedOrigins();
      const isFenced = port.fence !== null;
      if (isFenced) {
        const exactSet = new Set(port.fence.exact || []);
        const siteWideSet = new Set(port.fence.siteWide || []);
        const exactKnown = port.fence.exactKnown !== false;
        const coveringEntries = (port.fence.entries || []).filter((e) =>
          H.originCoveredBy(e, origin, !exactKnown || exactSet.has(e), siteWideSet.has(e))
        );
        port.fence.entries = (port.fence.entries || []).filter((e) => !coveringEntries.includes(e));
        port.fence.exact = (port.fence.exact || []).filter((e) => !coveringEntries.includes(e));
        port.fence.siteWide = (port.fence.siteWide || []).filter((e) => !coveringEntries.includes(e));
        port.notify();

        if (!listed.ok) {
          const declined = Array.isArray(port.fence.declined) ? [...port.fence.declined] : [];
          if (host && !declined.includes(host)) declined.push(host);
          port.fence.declined = declined;
          if (deps.setCfg) await deps.setCfg({ fence: port.fence });
          port.notify();
          deps.refreshOpenTabs?.();
          return { ok: true, origin };
        }

        const remainingHosts = new Set();
        for (const e of port.fence.entries) {
          try { remainingHosts.add(new URL(e).hostname); } catch (_e) {}
        }
        for (const e of coveringEntries) {
          try {
            const eh = new URL(e).hostname;
            const needed = [...remainingHosts].some((rh) => rh === eh || H.hostCovers(eh, rh));
            if (!needed) await removePatterns(patternsForOrigin(listed.origins, e));
          } catch (_e) {}
        }
        if (typeof deps.beginRead === "function") {
          await deps.beginRead();
        }
        if (deps.setCfg) {
          await deps.setCfg({ fence: port.fence });
        }
        port.notify();
        deps.refreshOpenTabs?.();
        return { ok: true, origin };
      }

      if (!listed.ok) return { ok: false, error: "permissions_unavailable" };

      const toRemove = patternsForOrigin(listed.origins, origin);
      if (!port.tombstones) port.tombstones = new Set();
      const keptTombstones = new Set(port.tombstones);
      for (const pattern of toRemove) port.tombstones.add(pattern);
      await removePatterns(toRemove);

      const still = await listedOrigins();
      if (!still.ok) {
        for (const pattern of [...port.tombstones]) {
          if (!keptTombstones.has(pattern)) port.tombstones.delete(pattern);
        }
        return { ok: false, error: "permissions_unavailable" };
      }
      for (const pattern of still.origins) port.tombstones.delete(pattern);
      const stillCovered = still.origins.some((pattern) => H.plainAllow(pattern, url));
      if (stillCovered) {
        const pageHost = H.storedExcludedHostname(host);
        if (!Array.isArray(port.excludedHosts)) port.excludedHosts = [];
        if (pageHost && !port.excludedHosts.includes(pageHost)) {
          port.excludedHosts = [...port.excludedHosts, pageHost].sort();
          if (typeof port.excludedGen === "number") port.excludedGen += 1;
          if (deps.setCfg) await deps.setCfg({ excludedHosts: port.excludedHosts });
        }
        port.notify();
        deps.refreshOpenTabs?.();
        if (typeof deps.beginRead === "function") await deps.beginRead();
        return { ok: true, origin, result: "left_out_instead" };
      }
      port.notify();
      deps.refreshOpenTabs?.();
      if (typeof deps.beginRead === "function") await deps.beginRead();
      return { ok: true, origin };
    });
  }

  async function patternsJustRead(port, deps) {
    let read = null;
    if (typeof deps.beginRead === "function") {
      read = await deps.beginRead();
    }
    if (Array.isArray(read)) return read;
    return { unavailable: true };
  }

  async function endFence(port, deps, patterns) {
    if (!port.fence) return;
    const finished = H.finishFence(port.fence, patterns, port.excludedHosts);
    port.fence = finished.fence;
    port.excludedHosts = finished.excludedHosts;
    if (typeof port.excludedGen === "number") port.excludedGen += 1;
    if (deps.setCfg) await deps.setCfg({ fence: null, excludedHosts: port.excludedHosts });
    port.notify();
    await deps.syncSiteRegistrations?.();
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
          if (agreeInFlight) return { ok: false, result: "agree_in_flight" };
          if (Gate.consentAccepted(port.consentVersion)) {
            return { ok: true, consentVersion: port.consentVersion };
          }
          agreeInFlight = true;
          try {
            await DB.put("meta", Gate.CONSENT_VERSION, "consentVersion");
            port.consentVersion = Gate.CONSENT_VERSION;
            port.notify();
            if (port.fence === null || typeof port.fence !== "object") {
              return { ok: true, consentVersion: port.consentVersion };
            }
            let read;
            try {
              read = await patternsJustRead(port, deps);
            } catch (_e) {
              read = null;
            }
            if (!Array.isArray(read)) {
              return { ok: false, result: "agreed_fence_kept", consentVersion: port.consentVersion };
            }
            await endFence(port, deps, read);
            return { ok: true, consentVersion: port.consentVersion };
          } catch (_err) {
            return { ok: false, error: "storage_error" };
          } finally {
            agreeInFlight = false;
          }
        }

        case "answerFirstRun": {
          try {
            if (deps.setCfg) await deps.setCfg({ firstRunAnswered: true });
            port.firstRunAnswered = true;
            port.notify();
            return { ok: true };
          } catch (_err) {
            return { ok: false, error: "storage_error" };
          }
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
          return removeGrantedOrigin(origin, deps);
        }

        case "stopSharingEverySite": {
          const isSafari = port.brand === "safari";
          if (!isSafari) {
            try { await chrome.permissions.remove({ origins: ["*://*/*"] }); } catch (_e) {}
          }
          if (typeof deps.beginRead === "function") {
            await deps.beginRead();
          }
          let result;
          if (H.everySiteLive(port.livePatterns)) {
            result = "still_every_site";
          } else {
            const isSitePattern = (p) => {
              if (p === "*://*/*" || p === "<all_urls>" || p === "http://*/*" || p === "https://*/*") return false;
              const match = /^(\*|https?):\/\/(\*\.)?([^/:]+)(?::(\d+))?\/\*$/.exec(p);
              if (!match) return false;
              const hostWithPort = match[4] ? `${match[3]}:${match[4]}` : match[3];
              return H.plainAllow(p, `https://${hostWithPort}`) || H.plainAllow(p, `http://${hostWithPort}`);
            };
            const hasSite = (port.livePatterns || []).some(isSitePattern);
            result = hasSite ? "every_site_off_some" : "every_site_off_none";
          }
          return { ok: true, result };
        }

        case "intendAddOrigin": {
          const origin = normalizeOrigin(msg.origin);
          if (!origin) return { ok: false, error: "invalid_origin" };
          if (!port.fence || typeof port.fence !== "object") {
            return { ok: true, stored: false };
          }
          port.addIntent = { origin, at: port.wallNow() };
          if (deps.setCfg) await deps.setCfg({ addIntent: port.addIntent });
          return { ok: true, stored: true };
        }

        case "clearAddIntent": {
          const origin = normalizeOrigin(msg.origin);
          if (origin && port.addIntent && port.addIntent.origin === origin) {
            port.addIntent = null;
            if (deps.setCfg) await deps.setCfg({ addIntent: null });
          }
          return { ok: true };
        }

        case "shareEverySite": {
          const read = await patternsJustRead(port, deps);
          if (!Array.isArray(read)) {
            return { ok: false, error: "permissions_unavailable" };
          }
          if (H.everySiteLive(read)) {
            await endFence(port, deps, read);
            return { ok: true, result: "shared" };
          }
          return { ok: false, result: "share_held" };
        }

        case "shareThemToo": {
          const read = await patternsJustRead(port, deps);
          if (!Array.isArray(read)) {
            return { ok: false, error: "permissions_unavailable" };
          }
          if (H.broadLive(read)) {
            return { ok: false, result: "question_every_site" };
          }
          const leftOut = [...(port.excludedHosts || []), ...(port.appLeftOut || [])];
          const beyond = H.beyondExample(port.fence, port.livePatterns, leftOut);
          const unaccounted = beyond?.shown || [];
          const shown = msg.shown;
          const covered = Array.isArray(shown)
            && shown.every((item) => typeof item === "string")
            && unaccounted.every((pattern) => shown.includes(pattern));
          if (!covered) {
            return { ok: false, result: "question_changed" };
          }
          await endFence(port, deps, read);
          return { ok: true, result: "shared" };
        }

        case "keepMySites": {
          if (port.fence) {
            port.fence.answered = true;
            if (deps.setCfg) await deps.setCfg({ fence: port.fence });
            port.notify();
          }
          return { ok: true };
        }

        case "checkEverySite": {
          if (typeof deps.beginRead === "function") {
            await deps.beginRead();
          }
          return { ok: true };
        }

        case "retryAllSites": {
          if (typeof deps.syncSiteRegistrations === "function") {
            await deps.syncSiteRegistrations();
          }
          return { ok: true };
        }

        case "setLeftOut": {
          const host = H && H.excludedHostname ? H.excludedHostname(msg.host) : null;
          if (!host || host !== msg.host) return { ok: false, error: "invalid_host" };
          const out = !!msg.out;
          if (!Array.isArray(port.excludedHosts)) port.excludedHosts = [];

          if (out) {
            if (!port.excludedHosts.includes(host)) {
              port.excludedHosts = [...port.excludedHosts, host].sort();
            }
            if (typeof port.excludedGen === "number") port.excludedGen += 1;
            if (deps.setCfg) {
              try { await deps.setCfg({ excludedHosts: [...port.excludedHosts] }); }
              catch (_e) { return { ok: false, error: "storage_error" }; }
            }
            if (typeof port.queueSiteRule === "function") port.queueSiteRule(host, true);
            port.notify();
            await deps.syncSiteRegistrations?.();
            return { ok: true, host, out: true };
          }

          const next = port.excludedHosts.filter((h) => h !== host);
          if (deps.setCfg) {
            try { await deps.setCfg({ excludedHosts: [...next] }); }
            catch (_e) { return { ok: false, error: "storage_error" }; }
          }
          port.excludedHosts = next;
          if (typeof port.excludedGen === "number") port.excludedGen += 1;
          if (typeof port.includeHost === "function") port.includeHost(host);
          port.notify();
          await deps.syncSiteRegistrations?.();
          return { ok: true, host, out: false };
        }

        case "setPaused": {
          const desired = !!msg.paused;
          const epoch = ++pauseEpoch;
          if (desired) { port.paused = true; port.notify(); }
          const patch = { paused: desired };
          if (!desired && port.clearedNotice) patch.clearedNotice = false;
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
            if (desired) {
              port.paused = true;
            }
            port.notify();
            return { ok: false, saved: false, paused: port.paused, error: "storage_error" };
          }

          if (epoch !== pauseEpoch) return { ok: false, error: "superseded" };
          port.paused = desired;
          if (!desired && port.clearedNotice) port.clearedNotice = false;
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
          const prevPauseWithApp = port.pauseWithApp;

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
              port.pauseWithApp = prevPauseWithApp;
              port.notify();
              return { ok: false, error: "storage_error" };
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
    const challengeKey = `${tabId}:${frameId}`;
    let challenge = null;
    if (msg?.kind === "hello") {
      challenge = {};
      frameChallenges.set(challengeKey, challenge);
      if (typeof deps.beginRead === "function") {
        await deps.beginRead();
      }
      if (frameChallenges.get(challengeKey) !== challenge) {
        return { ok: false, error: "challenge_mismatch" };
      }
    }

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
    let binding = frameBindings.get(fKey);
    if (msg.kind === "hello") {
      // Ask the live frame which realm is running. A delayed message from a
      // retired document cannot appoint itself the current realm (Firefox 140
      // does not supply documentId).
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
          lease: port.lease ? { ...port.lease, freshnessMs: port.lease.standing === true ? port.lease.freshnessMs :
            Math.max(0, Math.floor(port.lease.receivedAt + port.lease.freshnessMs - port.now())) } : null,
          consentVersion: port.consentVersion,
          paused: port.paused,
          livePatterns: port.livePatterns ? [...port.livePatterns] : [],
          fence: port.fence ? { ...port.fence } : null,
          broadGrant: port.broadGrant === true,
          excludedHosts: [...(port.excludedHosts || [])],
          appLeftOut: [...(port.appLeftOut || [])],
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
        if (!H.broadLive(port.livePatterns) || !binding || !deps.executeBrowserRead ||
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
        const authorize = () => {
          port.syncCaptureAuthority?.();
          return frameBindings.get(fKey) === binding && port.captureEpoch === admittedEpoch &&
            originGranted(port, senderOrigin) &&
            Gate.computeDecision({lease:port.lease, paused:port.paused, consentVersion:port.consentVersion,
              originGranted:true, pressure:port.pressure, hostCapture:port.hostCapture,
              capturePermitted:port.capturePermitted === true, now:port.now()}).open;
        };
        binding.readPending = true;
        binding.readNonce = nonce;
        try {
          const result = await deps.executeBrowserRead(binding, { nonce, action: msg.action,
            reason: msg.reason, requestId: msg.requestId, captureEpoch: admittedEpoch, leaseToken: port.lease.token }, authorize);
          if (!authorize()) return { ok: false, error: "authority_mismatch" };
          if (result !== true) {
            port.faults?.set(senderOrigin, "unknown");
            return { ok: false, error: "read_not_executed" };
          }
          port.faults?.delete(senderOrigin);
          return { ok: true };
        } catch (err) {
          if (binding.readNonce === nonce) binding.readNonce = null;
          const isTimeout = err?.message === "browser_read_timeout" || err?.error === "browser_read_timeout" || err === "browser_read_timeout";
          if (isTimeout) {
            port.faults?.set(senderOrigin, "unknown");
            return { ok: false, error: "browser_read_timeout" };
          }
          port.faults?.set(senderOrigin, "denied");
          return { ok: false, error: "browser_access_denied" };
        } finally { binding.readPending = false; }
      }

      case "skim": {
        if (!binding) {
          return { ok: false, error: "challenge_mismatch" };
        }
        if (H.broadLive(port.livePatterns)) {
          if (!msg.readNonce || binding.readNonce !== msg.readNonce) {
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

          // Errors stay on the covering grant's row origin, where the owner sees its row.
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
    route,
    destroyBinding,
    normalizeOrigin,
    isExtensionPageSender,
    frameBindings,
    frameChallenges,
  };
})();
