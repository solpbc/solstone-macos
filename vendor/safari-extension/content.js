// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  if (globalThis.__solstoneBrowserContent) return;
  globalThis.__solstoneBrowserContent = true;
  // Private windows are never read (Safari can run extensions there).
  if (globalThis.chrome?.extension?.inIncognitoContext === true) return;

  const A = globalThis.SolstoneAdapters;
  const Skim = globalThis.SolstoneSkim;
  const Indicator = globalThis.SolstoneIndicator;
  const Gate = globalThis.SolstoneCaptureGate;

  const realmTokenBytes = new Uint8Array(16);
  crypto.getRandomValues(realmTokenBytes);
  const REALM_TOKEN = [...realmTokenBytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  const documentKeyBytes = new Uint8Array(16);
  crypto.getRandomValues(documentKeyBytes);
  const DOCUMENT_KEY = [...documentKeyBytes].map((b) => b.toString(16).padStart(2, "0")).join("");

  const DEBOUNCE_MS = 500;

  let lease = null;
  let paused = false;
  let consentVersion = 0;
  let originGranted = false;
  let browserMediated = false;
  let injectedRead = null;
  let browserReadPending = false;
  let readSequence = 0;
  let readRequestedAt = 0;
  let readTimer = null;
  let showIndicator = false;
  let hostCapture = null;
  let capturePermitted = false;
  let pressure = { active: false };
  let captureEpoch = null;
  let connectionGeneration = 0;
  let destinationGeneration = null;

  let adapter = null;
  let observer = null;
  let debounceTimer = null;
  let rootInterval = null;
  let idleCallbackId = null;
  let rootEl = null;
  let started = false;
  let grantEpoch = 0;
  let grantSequence = 0;
  let leaseTimer = null;

  function now() {
    return typeof performance !== "undefined" && performance.now ? performance.now() : Date.now();
  }

  function getDecision() {
    return Gate.computeDecision({
      lease,
      paused,
      consentVersion,
      originGranted,
      pressure,
      hostCapture,
      capturePermitted,
      now: now(),
    });
  }

  function getHooks() {
    return {
      discover: () => {
        if (!adapter) adapter = A.adapterForHost(location.host);
        return A.pickRoot(adapter, document);
      },
      readMeta: () => {
        if (!adapter) adapter = A.adapterForHost(location.host);
        return {
          title: document.title,
          adapter: adapter.name,
        };
      },
      skim: (targetRoot) => {
        if (!adapter) adapter = A.adapterForHost(location.host);
        return Skim.skim(targetRoot, adapter);
      },
    };
  }

  function send(msg) {
    try {
      chrome.runtime.sendMessage(Object.assign({ realmToken: REALM_TOKEN, documentKey: DOCUMENT_KEY }, msg), () => void chrome.runtime.lastError);
    } catch (_e) {
      /* worker asleep / context invalidated */
    }
  }

  function doSkim(reason) {
    const decisionBefore = getDecision();
    if (!decisionBefore.open) return;
    if (browserMediated && !injectedRead) { requestBrowserRead("skim", reason); return; }

    if (!adapter) adapter = A.adapterForHost(location.host);
    const targetRoot = A.pickRoot(adapter, document);
    if (!targetRoot) return;
    rootEl = targetRoot;

    const meta = getHooks().readMeta();
    const skimRes = Skim.skim(targetRoot, adapter);
    const blocks = Array.isArray(skimRes) ? skimRes : (skimRes && skimRes.blocks) || [];
    const omitted = !Array.isArray(skimRes) && skimRes && skimRes.omitted ? true : undefined;
    const clips = !Array.isArray(skimRes) && Array.isArray(skimRes?.clips) ? skimRes.clips : [];

    const decisionAfter = getDecision();
    if (!decisionAfter.open) return;

    const msg = {
      kind: "skim",
      reason,
      meta,
      blocks,
      captureEpoch,
      connectionGeneration,
      destinationGeneration,
      leaseToken: lease?.token || null,
      readNonce: injectedRead?.nonce || null,
    };
    if (omitted) msg.omitted = true;
    if (clips.length) msg.clips = clips;
    send(msg);
  }

  function scheduleSkim() {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      if (typeof requestIdleCallback === "function") {
        idleCallbackId = requestIdleCallback(() => {
          idleCallbackId = null;
          doSkim("change");
        }, { timeout: 1000 });
      } else {
        doSkim("change");
      }
    }, DEBOUNCE_MS);
  }

  function startObserving() {
    const decision = getDecision();
    if (!decision.open) return;
    if (browserMediated && !injectedRead) { requestBrowserRead("observe", "initial"); return; }

    const discovered = Gate.runIfPermitted(decision, {
      discover: getHooks().discover,
    });
    if (!discovered || !discovered.root) return;
    rootEl = discovered.root;

    if (observer) observer.disconnect();
    observer = new MutationObserver((mutations) => {
      if (!getDecision().open) { stopObserving(); return; }
      // In broad mode a retained listener only schedules browser-authorized
      // execution. Safari can retain it after a denial with no removal event.
      if (browserMediated) { scheduleSkim(); return; }
      const indicatorHost = document.getElementById("solstone-observer-indicator-host");
      const filtered = mutations.filter((m) => {
        if (!indicatorHost) return true;
        return m.target !== indicatorHost && !indicatorHost.contains(m.target);
      });
      if (filtered.length > 0) {
        scheduleSkim();
      }
    });

    observer.observe(rootEl, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ["aria-label", "aria-level", "role"],
    });

    if (showIndicator) Indicator.show(false);
    doSkim("initial");
  }

  function stopObserving() {
    grantEpoch++;
    readSequence++;
    browserReadPending = false;
    clearTimeout(readTimer);
    clearTimeout(leaseTimer);
    leaseTimer = null;
    if (observer) {
      observer.disconnect();
      observer = null;
    }
    clearTimeout(debounceTimer);
    debounceTimer = null;
    if (rootInterval) {
      clearInterval(rootInterval);
      rootInterval = null;
    }
    if (idleCallbackId != null && typeof cancelIdleCallback === "function") {
      cancelIdleCallback(idleCallbackId);
      idleCallbackId = null;
    }
  }

  function handleSolicitedGrant(response, reqTime) {
    if (typeof response.paused === "boolean") paused = response.paused;
    if (typeof response.consentVersion === "number") consentVersion = response.consentVersion;
    browserMediated = response.siteMode === "all";
    originGranted = globalThis.SolstoneHosts.originGranted(response, location.origin);
    if (typeof response.showPageIndicator === "boolean") showIndicator = response.showPageIndicator;
    hostCapture = response.hostCapture || null;
    capturePermitted = response.capturePermitted === true;
    if (response.pressure) pressure = response.pressure;
    captureEpoch = response.captureEpoch;
    connectionGeneration = response.connectionGeneration || 0;
    destinationGeneration = response.destinationGeneration || null;

    if (response.lease) {
      const freshnessMs = Number(response.lease.freshnessMs || 0);
      if (now() >= reqTime + freshnessMs) {
        lease = null;
      } else {
        lease = {
          token: response.lease.token,
          generation: response.lease.generation,
          freshnessMs,
          receivedAt: reqTime,
        };
      }
    } else {
      lease = null;
    }

    const decision = getDecision();
    clearTimeout(leaseTimer);
    if (decision.open) {
      const grantedLease = lease;
      leaseTimer = setTimeout(() => {
        if (lease !== grantedLease) return;
        lease = null;
        stopObserving();
      }, Math.max(0, lease.receivedAt + lease.freshnessMs - now()));
      if (!observer && !rootEl) waitForRoot();
      else if (!observer && rootEl) startObserving();
    } else {
      stopObserving();
      if (showIndicator && paused) Indicator.show(true);
      else if (!showIndicator) Indicator.remove();
    }
  }

  function handleLeaseUpdate(msg) {
    if (typeof msg.paused === "boolean") paused = msg.paused;
    if (typeof msg.consentVersion === "number") consentVersion = msg.consentVersion;
    browserMediated = msg.siteMode === "all";
    originGranted = globalThis.SolstoneHosts.originGranted(msg, location.origin);
    if (typeof msg.showIndicator === "boolean") showIndicator = msg.showIndicator;
    hostCapture = msg.hostCapture || null;
    capturePermitted = msg.capturePermitted === true;
    if (msg.pressure) pressure = msg.pressure;
    if (msg.connectionGeneration !== undefined) connectionGeneration = msg.connectionGeneration;
    if (msg.destinationGeneration !== undefined) destinationGeneration = msg.destinationGeneration;

    const isClosed = !msg.lease || paused || !originGranted || pressure?.active || hostCapture !== "permitted" || !capturePermitted;

    if (isClosed) {
      lease = null;
      stopObserving();
      if (showIndicator && paused) Indicator.show(true);
      else if (!showIndicator) Indicator.remove();
      return;
    }

    // A delivery-only update cannot renew or revoke an unchanged grant.
    if (Number.isSafeInteger(msg.captureEpoch) && msg.captureEpoch === captureEpoch && msg.lease?.token === lease?.token &&
        msg.destinationGeneration === lease?.generation && getDecision().open) return;

    // Positive notifications carry no content-clock authority. Close before
    // borrowing any of their destination fields for a new request.
    lease = null;
    stopObserving();
    // Positive updates require a solicited, conservatively mapped deadline.
    requestGrant();
  }

  function waitForRoot() {
    let tries = 0;
    if (rootInterval) clearInterval(rootInterval);
    const check = () => {
      tries++;
      const decision = getDecision();
      const discovered = Gate.runIfPermitted(decision, {
        discover: getHooks().discover,
      });
      const r = discovered && discovered.root;
      const ready = r && (r.tagName !== "BODY" || r.children.length > 0);
      if (ready) {
        if (rootInterval !== null) {
          clearInterval(rootInterval);
          rootInterval = null;
        }
        rootEl = r;
        startObserving();
      } else if (tries > 40 || !decision.open) {
        if (rootInterval !== null) {
          clearInterval(rootInterval);
          rootInterval = null;
        }
      }
    };
    rootCheck = check;
    rootInterval = setInterval(() => {
      if (browserMediated) requestBrowserRead("root", "initial");
      else check();
    }, 500);
  }

  let rootCheck = null;
  function requestBrowserRead(action, reason) {
    if (browserReadPending || !getDecision().open) return;
    browserReadPending = true;
    const requestId = ++readSequence;
    readRequestedAt = now();
    readTimer = setTimeout(() => {
      if (readSequence !== requestId) return;
      browserReadPending = false;
      readSequence++;
    }, 5000);
    try {
      chrome.runtime.sendMessage({ kind: "read", action, reason, requestId,
        realmToken: REALM_TOKEN, documentKey: DOCUMENT_KEY,
        captureEpoch, leaseToken: lease?.token || null }, () => {
        if (readSequence !== requestId) return;
        browserReadPending = false;
        clearTimeout(readTimer);
        void chrome.runtime.lastError;
      });
    } catch (_e) { browserReadPending = false; }
  }

  // The browser invokes this in its isolated world only after checking current
  // access. The document identity and lease prevent a queued read from moving
  // to a replacement frame or surviving a policy/authority withdrawal.
  globalThis.__solstoneAuthorizedRead = (realm, documentKey, read) => {
    if (!browserMediated || realm !== REALM_TOKEN || documentKey !== DOCUMENT_KEY ||
        !browserReadPending || read.requestId !== readSequence || now() >= readRequestedAt + 5000 ||
        read.captureEpoch !== captureEpoch || read.leaseToken !== lease?.token || !getDecision().open) return false;
    injectedRead = read;
    try {
      if (read.action === "root") rootCheck?.();
      else if (read.action === "observe") startObserving();
      else if (read.action === "skim") doSkim(read.reason || "change");
      else return false;
      return true;
    } finally { injectedRead = null; }
  };

  function requestGrant() {
    const reqTime = now();
    const epoch = grantEpoch;
    const sequence = ++grantSequence;
    try {
      chrome.runtime.sendMessage({ kind: "hello", realmToken: REALM_TOKEN, documentKey: DOCUMENT_KEY }, (response) => {
        if (epoch !== grantEpoch || sequence !== grantSequence || !response || !response.ok) return;
        handleSolicitedGrant(response, reqTime);
      });
    } catch (_e) {
      /* ignore */
    }
  }

  function boot() {
    if (started) return;
    started = true;
    requestGrant();
  }

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (!msg || !sender) return false;
    if (sender.id !== chrome.runtime.id || sender.tab) return false;

    if (msg.kind === "confirmRealm") {
      sendResponse({ realmToken: REALM_TOKEN });
    } else if (msg.kind === "leaseUpdate") {
      handleLeaseUpdate(msg);
    } else if (msg.kind === "setPaused") {
      paused = !!msg.paused;
      const decision = getDecision();
      if (decision.open) startObserving();
      else stopObserving();
      if (showIndicator) Indicator.show(paused);
    } else if (msg.kind === "resnapshot") {
      if (!getDecision().open) requestGrant();
      else doSkim("change");
    } else if (msg.kind === "stop" || msg.kind === "permissionRemoved") {
      lease = null;
      stopObserving();
      Indicator.remove();
    } else if (msg.kind === "setIndicator") {
      showIndicator = !!msg.show;
      if (showIndicator) Indicator.show(paused);
      else Indicator.remove();
    } else if (msg.kind === "ping") {
      sendResponse({ ok: true });
    }
    return false;
  });

  function flush(reason) {
    doSkim(reason);
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flush("hidden");
    else if (rootEl) doSkim("visible");
    else startObserving();
  });

  window.addEventListener("freeze", () => flush("freeze"), { capture: true });
  window.addEventListener("resume", () => {
    doSkim("resume");
  }, { capture: true });
  window.addEventListener("pageshow", (e) => {
    if (e.persisted) {
      requestGrant();
    }
  });

  window.addEventListener("pagehide", () => {
    flush("pagehide");
    send({ kind: "bye" });
    lease = null;
    stopObserving();
  }, { once: true });

  if (document.readyState === "complete" || document.readyState === "interactive") boot();
  else window.addEventListener("DOMContentLoaded", boot, { once: true });
})();
