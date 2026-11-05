// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

if (typeof importScripts === "function") {
  importScripts(
    "native-browser/constants.js",
    "native-browser/schemas.js",
    "native-browser/schema-validator.js",
    "native-browser/codec.js",
    "lib/copy.js",
    "lib/uuid.js",
    "lib/db.js",
    "lib/blocks.js",
    "lib/hosts.js",
    "lib/failures.js",
    "lib/reconcile.js",
    "lib/segment.js",
    "lib/gate.js",
    "lib/native_outbox.js",
    "lib/about.js",
    "lib/safari_port.js",
    "lib/safari_ios_port.js",
    "lib/left_out.js",
    "lib/native_port.js",
    "lib/status.js",
    "lib/owner_sites.js",
    "lib/tab_age.js",
    "lib/page_facts.js",
    "lib/router.js"
  );
}

const H = globalThis.SolstoneHosts;
const DB = globalThis.SolstoneDB;
const Failures = globalThis.SolstoneFailures;
const Reconcile = globalThis.SolstoneReconcile;
const Uuid = globalThis.SolstoneUuid;
const Router = globalThis.SolstoneRouter;
const PortController = globalThis.SolstoneNativePort;
const Outbox = globalThis.SolstoneNativeOutbox;
const Status = globalThis.SolstoneStatus;

const VERSION = "0.5.5";
const ALARM_NAME = "native-port";

const CONTENT_SCRIPT_FILES = [
  "native-browser/constants.js",
  "native-browser/schemas.js",
  "native-browser/schema-validator.js",
  "native-browser/codec.js",
  "lib/blocks.js",
  "lib/hosts.js",
  "adapters.js",
  "skim.js",
  "indicator.js",
  "lib/gate.js",
  "lib/page_facts.js",
  "content.js",
];

const DEFAULT_CFG = {
  paused: false,
  showPageIndicator: false,
  pauseWithApp: true,
  chosenOrigins: [],
  siteMode: "selected",
  excludedHosts: [],
  allSitesConsent: 0,
  siteWideOrigins: [],
  offeredOrigins: [],
  appLeftOut: [],
};

let port = null;
let initPromise = null;
let permissionEpoch = 0;
let badgeEpoch = 0;
let openTabsGeneration = 0;
let badgeChain = Promise.resolve();
// The toolbar's own sequence: only a paint supersedes a paint, so a status
// that publishes authority without painting never leaves icon and title apart.
let paintEpoch = 0;
let toolbarLink = null;
let toolbarWake = null;
let lastAppNudgeAt = -Infinity;
const statusPorts = new Set();
// Tabs that may hold a lease must receive withdrawal without a fresh query.
const leaseTabs = new Set();

let browserIdentityPromise = null;
function getBrowserIdentity() {
  if (!browserIdentityPromise) {
    browserIdentityPromise = (async () => {
      try {
        let browserInfo = null;
        if (typeof browser !== "undefined" && browser.runtime?.getBrowserInfo) {
          try { browserInfo = await browser.runtime.getBrowserInfo(); } catch (_e) {}
        }
        let userAgentData = null;
        if (typeof navigator !== "undefined" && navigator.userAgentData) {
          userAgentData = navigator.userAgentData;
          if (typeof userAgentData.getHighEntropyValues === "function") {
            try {
              const high = await userAgentData.getHighEntropyValues(["fullVersionList"]);
              if (high && Array.isArray(high.fullVersionList)) {
                userAgentData = { ...userAgentData, fullVersionList: high.fullVersionList };
              }
            } catch (_e) {}
          }
        }
        const userAgent = typeof navigator !== "undefined" ? navigator.userAgent : "";
        return globalThis.SolstonePageFacts ? globalThis.SolstonePageFacts.mapBrowser({ browserInfo, userAgentData, userAgent }) : null;
      } catch (_e) {
        return null;
      }
    })();
  }
  return browserIdentityPromise;
}

async function getCfg() {
  const r = await chrome.storage.local.get("cfg");
  const stored = r.cfg || {};
  let chosenOrigins = stored.chosenOrigins;
  if (!Array.isArray(chosenOrigins)) {
    chosenOrigins = Array.isArray(stored.grantedOrigins) ? stored.grantedOrigins : [];
    const next = {
      paused: !!stored.paused,
      showPageIndicator: !!stored.showPageIndicator,
      pauseWithApp: stored.pauseWithApp !== false,
      chosenOrigins,
    };
    await chrome.storage.local.set({ cfg: next });
    return { ...DEFAULT_CFG, ...next };
  }
  const res = {
    paused: !!stored.paused,
    showPageIndicator: !!stored.showPageIndicator,
    pauseWithApp: stored.pauseWithApp !== false,
    chosenOrigins: [...chosenOrigins],
    siteMode: stored.siteMode === "all" ? "all" : "selected",
    // A stored left-out site covers its subdomains too, and www.bank.com means
    // bank.com, so older entries now leave out at least as much as before.
    excludedHosts: Array.isArray(stored.excludedHosts)
      ? [...new Set(stored.excludedHosts.map(H.storedExcludedHostname).filter(Boolean))].sort()
      : [],
    allSitesConsent: stored.allSitesConsent === H.ALL_SITES_CONSENT_VERSION ? stored.allSitesConsent : 0,
    siteWideOrigins: Array.isArray(stored.siteWideOrigins) ? [...stored.siteWideOrigins] : [],
    offeredOrigins: Array.isArray(stored.offeredOrigins) ? [...stored.offeredOrigins] : [],
    appLeftOut: Array.isArray(stored.appLeftOut) ? [...stored.appLeftOut] : [],
    appLeftOutRaw: Array.isArray(stored.appLeftOutRaw) ? [...stored.appLeftOutRaw] : [],
  };
  if (Array.isArray(stored.declinedHosts)) {
    res.declinedHosts = [...stored.declinedHosts];
  }
  // Which sites cover only their exact address. Absent until first worked out,
  // which is different from an empty list.
  if (Array.isArray(stored.exactOnlyOrigins)) {
    res.exactOnlyOrigins = [...stored.exactOnlyOrigins];
  }
  if (stored.appLeftOutEpoch !== undefined && stored.appLeftOutEpoch !== null) {
    res.appLeftOutEpoch = stored.appLeftOutEpoch;
  }
  if (typeof stored.appLeftOutRev === "number") {
    res.appLeftOutRev = stored.appLeftOutRev;
  }
  return res;
}

let cfgChain = Promise.resolve();
function setCfg(patch) {
  cfgChain = cfgChain.catch(() => {}).then(async () => {
    const current = await getCfg();
    const next = Object.assign({}, current, patch);
    await chrome.storage.local.set({ cfg: next });
    return next;
  });
  return cfgChain;
}

// Saves which sites cover only their exact address. The list is read when the
// write runs, in line with every other config write, so an earlier list never
// overwrites a later one. Nothing is written until startup has worked the list
// out once.
let exactOnlyReady = false;
function persistExactOnly() {
  if (!exactOnlyReady || !port) return cfgChain;
  cfgChain = cfgChain.catch(() => {}).then(async () => {
    if (!exactOnlyReady || !port) return undefined;
    const list = Array.from(port.exactOnlyOrigins || []).sort();
    const current = await getCfg();
    const stored = Array.isArray(current.exactOnlyOrigins) ? [...current.exactOnlyOrigins].sort() : null;
    if (stored && stored.length === list.length && stored.every((o, i) => o === list[i])) return current;
    const next = Object.assign({}, current, { exactOnlyOrigins: list });
    await chrome.storage.local.set({ cfg: next });
    return next;
  });
  return cfgChain;
}

const ICON_SET = (prefix) => ({
  16: `icons/${prefix}16.png`,
  48: `icons/${prefix}48.png`,
  128: `icons/${prefix}128.png`,
});

async function updateBadge(status) {
  badgeEpoch++;
  const currentBadgeEpoch = badgeEpoch;

  if (!status && port) status = port.getStatus();
  if (!status) return;

  // A routine host state renewal withdraws authority and re-grants it a moment
  // later. Content scripts hear the withdrawal; the owner's surfaces wait for
  // the settled state rather than flash "can't reach the solstone app".
  const settling = status.hostSettling === true;

  // Authority publication never waits for browser action painting.
  if (!settling) {
    for (const sp of statusPorts) {
      try { sp.postMessage({ type: "status", status }); }
      catch (_e) { statusPorts.delete(sp); }
    }
  }
  broadcastLeaseUpdate(status, currentBadgeEpoch);
  if (settling) return;
  await paintToolbar(status);
}

async function paintToolbar(status) {
  const now = port ? port.now() : Date.now();
  toolbarLink = Status.present(toolbarLink, status, undefined, now);
  if (toolbarWake != null && port) port.clearSchedule(toolbarWake);
  toolbarWake = null;
  if (toolbarLink.wakeAt != null && port) {
    const target = port;
    toolbarWake = target.schedule(() => {
      toolbarWake = null;
      if (port !== target) return;
      const current = target.getStatus();
      if (current.hostSettling !== true) paintToolbar(current);
    }, Math.max(0, toolbarLink.wakeAt - now));
  }
  // Nothing to paint yet: the toolbar keeps what it shows.
  if (!toolbarLink.status) return;

  const iconInfo = Status.iconState(toolbarLink.status);
  const prefix = iconInfo.prefix;
  const badge = iconInfo.badge || "";
  const title = iconInfo.title || "solstone";
  const currentPaint = ++paintEpoch;
  badgeChain = badgeChain.catch(() => {}).then(async () => {
    if (paintEpoch !== currentPaint) return;
    await chrome.action.setIcon({ path: ICON_SET(prefix) });
    if (paintEpoch !== currentPaint) return;
    await chrome.action.setBadgeText({ text: badge });
    if (paintEpoch !== currentPaint) return;
    if (badge) await chrome.action.setBadgeBackgroundColor({ color: "#9F2D2D" });
    if (paintEpoch !== currentPaint) return;
    await chrome.action.setTitle({ title });
  });
  await badgeChain.catch(() => {});
}

// The owner coming back to the browser, often straight from opening the
// solstone app, tries the app now rather than at the next minute's poll. The
// app is on this computer, so a try is cheap; it still waits a few seconds
// between tries.
function tryAppNow() {
  ensureInit().then(() => {
    if (!port || port.livePort || port.behind) return;
    const now = port.now();
    if (now - lastAppNudgeAt < 5000) return;
    lastAppNudgeAt = now;
    port.connect();
  }).catch(() => {});
}

function refreshOpenTabs() {
  if (!port) return;
  const generation = ++openTabsGeneration;
  const knownDocuments = new Map();
  for (const entry of Object.values(port.truncationByOrigin || {})) {
    for (const [slot, doc] of Object.entries(entry.documents || {})) knownDocuments.set(slot, doc);
  }
  let settled = false;
  const finish = (tabs, failed) => {
    if (settled) return;
    settled = true;
    if (!port || generation !== openTabsGeneration) return;
    if (failed || !Array.isArray(tabs)) {
      port.openTabs = { generation, known: false, openOrigins: null, anyGrantedTabOpen: null };
    } else {
      for (const tab of tabs) if (tab.id != null) leaseTabs.add(tab.id);

      const liveIds = new Set(tabs.map(tab => String(tab.id)));
      port.pruneTruncationDocuments?.((slot, doc) =>
        generation !== openTabsGeneration || !/^[0-9]+:[0-9]+$/.test(slot) ||
        knownDocuments.get(slot) !== doc || liveIds.has(slot.split(":")[0]));
      const projected = Status.projectOpenTabs(tabs, port);
      port.openTabs = { generation, ...projected };
    }
    port.notify();
  };
  try {
    const pending = chrome.tabs.query({}, (tabs) => finish(tabs, !!chrome.runtime.lastError));
    if (pending && typeof pending.then === "function") {
      pending.then((tabs) => finish(tabs, !!chrome.runtime.lastError), () => finish(null, true));
    }
  } catch (_e) {
    finish(null, true);
  }
}

function broadcastLeaseUpdate(status = port?.getStatus(), epoch = badgeEpoch) {
  if (!status) return;
  const message = {
    kind: "leaseUpdate", captureEpoch: status.captureEpoch, lease: status.lease,
    paused: status.paused, consentVersion: status.consentVersion,
    grantedOrigins: status.grantedOrigins || [], exactOnlyOrigins: status.exactOnlyOrigins || [],
    siteWideOrigins: status.siteWideOrigins || [],
    pendingRemoveOrigins: status.pendingRemoveOrigins || [],
    showIndicator: status.showPageIndicator,
    siteMode: status.siteMode, excludedHosts: status.excludedHosts || [],
    appLeftOut: status.appLeftOut || [],
    allSitesConsent: status.allSitesConsent, broadGranted: status.broadGranted,
    sitePolicyPending: status.sitePolicyPending,
    hostCapture: status.hostCapture, hostDelivery: status.hostDelivery,
    hostFailure: status.hostFailure, custody: status.custody, pressure: status.pressure,
    capturePermitted: status.capturePermitted === true,
    destinationGeneration: status.destinationGeneration,
    connectionGeneration: status.connectionGeneration || 0,
    connectionToken: status.connectionToken || null,
  };
  const sent = new Set();
  const send = (tabId) => {
    if (tabId == null || sent.has(tabId) || epoch !== badgeEpoch) return;
    sent.add(tabId);
    try { chrome.tabs.sendMessage(tabId, message, () => void chrome.runtime.lastError); }
    catch (_e) { /* The tab may have closed. */ }
  };
  for (const binding of Router.frameBindings.values()) leaseTabs.add(binding.tabId);
  for (const tabId of leaseTabs) send(tabId);
  // Discovery supplements known recipients; it never gates their withdrawal.
  chrome.tabs.query({}, (tabs) => {
    if (epoch !== badgeEpoch) return;
    for (const tab of tabs || []) {
      if (tab.id == null) continue;
      leaseTabs.add(tab.id);
      send(tab.id);
    }
  });
}

function broadcastPause(paused) {
  const epoch = badgeEpoch;
  chrome.tabs.query({}, (tabs) => {
    if (epoch !== badgeEpoch || port?.paused !== paused) return;
    for (const tab of tabs || []) {
      if (tab.id == null) continue;
      chrome.tabs.sendMessage(tab.id, { kind: "setPaused", paused }, () => void chrome.runtime.lastError);
    }
  });
}

function broadcastIndicator(show) {
  chrome.tabs.query({}, (tabs) => {
    for (const tab of tabs || []) {
      if (tab.id == null) continue;
      chrome.tabs.sendMessage(tab.id, { kind: "setIndicator", show }, () => void chrome.runtime.lastError);
    }
  });
}

function requestSnapshots() {
  chrome.tabs.query({}, (tabs) => {
    for (const tab of tabs || []) {
      if (tab.id == null) continue;
      chrome.tabs.sendMessage(tab.id, { kind: "resnapshot" }, () => void chrome.runtime.lastError);
    }
  });
}

const permissionEffects = new Set();
async function removePermission(pattern) {
  const effect = chrome.permissions.remove({ origins: [pattern] });
  permissionEffects.add(effect);
  try { return await effect; }
  finally { permissionEffects.delete(effect); }
}
async function settlePermissionEffects() {
  while (permissionEffects.size) await Promise.allSettled([...permissionEffects]);
}

let lapsingReservation = null;
async function lapseReservation(targetPort = port) {
  if (!targetPort?.ownerSites?.reservation) return;
  const res = targetPort.ownerSites.reservation;
  if (targetPort.now() < res.expiresAt) return;
  if (lapsingReservation === res) return;
  lapsingReservation = res;
  try {
    if (res.pattern === "*://*/*" && !res.broadAlreadyLive) {
      try {
        await removePermission("*://*/*");
      } catch (_e) {}
    }
  } finally {
    Router.applyOwnerEvent(targetPort, { type: "drop-reservation" });
    targetPort.notify?.();
  }
}

async function walkRemoveSiteGrant(targetHost, options = {}) {
  let live = Array.isArray(options) ? options : (options?.livePatterns || options?.patterns);
  if (!live) {
    try {
      const perms = await chrome.permissions.getAll();
      live = perms?.origins || [];
    } catch (_e) {
      return [];
    }
  }
  const removed = [];
  for (const pattern of live) {
    if (pattern === "*://*/*" || pattern === "<all_urls>") continue;
    const grant = H.classifySiteGrant(pattern);
    if (!grant) continue;
    const matches = grant.host === targetHost || H.hostCovers(targetHost, grant.host);
    if (matches) {
      if (patternHeld(pattern)) continue;
      try {
        await removePermission(pattern);
        removed.push(pattern);
      } catch (_e) {}
    }
  }
  return removed;
}

async function checkCleanDeclines(hosts, livePatterns = null) {
  if (!port) return;
  const toCheck = Array.isArray(hosts) ? hosts : [];
  if (toCheck.length === 0) return;
  let live = livePatterns;
  if (!live) {
    try {
      const perms = await chrome.permissions.getAll();
      live = perms?.origins || [];
    } catch (_e) {
      return;
    }
  }
  const coveringGrants = [];
  for (const pat of live) {
    const grant = H.classifySiteGrant(pat);
    if (grant) coveringGrants.push(grant);
  }
  const cleanHosts = [];
  for (const h of toCheck) {
    const hasCovering = coveringGrants.some((grant) => {
      if (grant.host === h) return true;
      if (!grant.exactOnly && H.hostCovers(grant.host, h)) return true;
      return false;
    });
    if (!hasCovering) {
      cleanHosts.push(h);
    }
  }
  if (cleanHosts.length > 0) {
    Router.applyOwnerEvent(port, { type: "drop-declines", hosts: cleanHosts });
  }
}
// Chrome removes every grant a removed pattern contains, so a site pattern
// stays while a chosen site sits under it (bank.com while login.bank.com is
// chosen). It only keeps the browser grant; nothing is registered or read for
// the parent once it isn't chosen.
function patternHeld(pattern) {
  if (patternNeeded(pattern)) return true;
  const siteHost = H.patternSiteHost(pattern);
  if (!siteHost || !port) return false;
  return [...port.chosenOrigins].some((origin) => {
    try {
      const hostname = new URL(origin).hostname;
      return hostname !== siteHost && H.hostCovers(siteHost, hostname);
    } catch (_e) { return false; }
  });
}

function patternNeeded(pattern) {
  if (!port) return false;
  const reservation = port.ownerSites?.reservation;
  if (reservation?.pattern === pattern && port.now() < reservation.expiresAt) return true;
  if (pattern === "*://*/*" && port.siteMode === "all" && port.allSitesConsent === H.ALL_SITES_CONSENT_VERSION) return true;
  // A chosen site needs its own pattern and, if the browser still holds one
  // from before sites covered subdomains, its exact-host pattern. Any other
  // site grant for a chosen site's own host (such as an owner's
  // https://login.bank.com/*) is kept too, matching scheme where it names one.
  const grant = H.classifySiteGrant(pattern);
  return [...port.chosenOrigins].some(origin => {
    try {
      const url = new URL(origin);
      if (H.sitePatternsFor(url.host).includes(pattern)) return true;
      if (!grant || grant.host !== url.hostname) return false;
      if (pattern.startsWith("*://")) return true;
      return new URL(grant.origin).protocol === url.protocol;
    } catch (_e) { return false; }
  });
}

// After an update, Safari can leave a tab that was already open bound to the
// previous copy of the extension: injection resolves, yet nothing in the tab can
// reach this worker until the page reloads. A loaded, non-private tab that does
// not answer is treated like one the browser refused, so its site asks for a reload.
async function tabAnswers(tab) {
  if (tab.incognito || tab.status !== "complete") return true;
  try {
    const reply = await Promise.race([
      chrome.tabs.sendMessage(tab.id, { kind: "ping" }, { frameId: 0 }),
      new Promise(resolve => setTimeout(() => resolve(null), 1500)),
    ]);
    return reply?.ok === true;
  } catch (_e) {
    return false;
  }
}

async function registerSite(host) {
  const matchHost = H.matchHostFor(host);
  const id = "cs-" + matchHost;
  const pattern = H.matchPatternFor(host);
  if (!patternNeeded(pattern)) return "failed";

  try {
    await chrome.scripting.unregisterContentScripts({ ids: [id] });
  } catch (_e) {
    /* not registered */
  }

  if (!patternNeeded(pattern)) return "failed";
  try {
    await chrome.scripting.registerContentScripts([
      {
        id,
        matches: [pattern],
        js: CONTENT_SCRIPT_FILES,
        runAt: "document_idle",
        allFrames: true,
        persistAcrossSessions: true,
      },
    ]);
  } catch (error) {
    let registered = [];
    try {
      registered = await chrome.scripting.getRegisteredContentScripts({ ids: [id] });
    } catch (_e) {
      return "failed";
    }
    if (!Failures.contentScriptRegistrationSatisfied(id, registered)) return "failed";
  }

  if (!patternNeeded(pattern)) {
    await unregisterSite(host);
    return "failed";
  }
  let hadTabError = false;
  try {
    const tabs = await chrome.tabs.query({ url: pattern });
    for (const tab of tabs) {
      if (!patternNeeded(pattern)) break;
      if (tab.id == null) continue;
      try {
        await chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: CONTENT_SCRIPT_FILES });
        if (!(await tabAnswers(tab))) hadTabError = true;
      } catch (_e) {
        hadTabError = true;
      }
    }
  } catch (_e) {
    /* host permission not yet effective */
  }

  if (!patternNeeded(pattern)) {
    await unregisterSite(host);
    return "failed";
  }
  return hadTabError ? "reload" : "ready";
}

async function removeSiteOrigin(exactOrigin) {
  let host = "";
  try {
    host = new URL(exactOrigin).host;
  } catch (_e) {
    return;
  }

  const matchHost = H.matchHostFor(host);
  if (port) {
    const hasSibling = Array.from(port.chosenOrigins || []).some((o) => {
      try { return H.matchHostFor(new URL(o).host) === matchHost; } catch (_e) { return false; }
    });
    if (!hasSibling) {
      await unregisterSite(host);
    }
  } else {
    await unregisterSite(host);
  }
}

async function unregisterSite(host) {
  const matchHost = H.matchHostFor(host);
  const pattern = H.matchPatternFor(matchHost);
  if (patternNeeded(pattern)) return;
  try {
    await chrome.scripting.unregisterContentScripts({ ids: ["cs-" + matchHost] });
  } catch (_e) {
    /* not registered */
  }

  // A later add may have completed while unregister was pending. Repair its
  // registration and never release the permission belonging to that choice.
  if (patternNeeded(pattern)) { await registerSite(host); return; }
  try {
    const tabs = await chrome.tabs.query({ url: pattern });
    for (const tab of tabs) {
      if (patternNeeded(pattern)) { await registerSite(host); return; }
      // A tab another chosen site still covers keeps going.
      let stillShared = false;
      try { stillShared = !!port && H.originGranted(port, new URL(tab.url).origin); } catch (_e) {}
      if (tab.id != null && !stillShared) {
        chrome.tabs.sendMessage(tab.id, { kind: "stop" }, () => void chrome.runtime.lastError);
        Router.destroyBinding(tab.id);
      }
    }
  } catch (_e) {
    /* ignore */
  }

  try {
    if (patternNeeded(pattern)) { await registerSite(host); return; }
  } catch (_e) {
    /* ignore */
  }
}

async function runReconcile() {
  const cfg = await getCfg();
  let granted = null;
  try {
    const perms = await chrome.permissions.getAll();
    granted = perms.origins || [];
  } catch (_e) {
    return [];
  }

  await lapseReservation(port);
  const reservation = port?.ownerSites?.reservation || null;
  const exemptPatterns = reservation ? [reservation.pattern] : [];

  const actions = Reconcile.reconcile({
    granted,
    manifestOrigins: port?.siteMode === "all" && port.allSitesConsent === H.ALL_SITES_CONSENT_VERSION ? ["*://*/*"] : [],
    exemptOrigins: [],
    exemptPatterns,
    allowlist: (cfg.chosenOrigins || []).map((o) => {
      try { return new URL(o).host; } catch (_e) { return o; }
    }),
    pausedHosts: {},
  });

  return actions;
}

let registrationChain = Promise.resolve();
function syncSiteRegistrations() {
  registrationChain = registrationChain.catch(() => {}).then(async () => {
    if (!port) return;
    const registered = await chrome.scripting.getRegisteredContentScripts();
    const broad = port.siteMode === "all" && port.allSitesConsent === H.ALL_SITES_CONSENT_VERSION && port.broadGranted;
    const obsolete = registered.filter(item => item.id.startsWith("cs-") && (broad || item.id === "cs-all-sites"));
    if (obsolete.length) await chrome.scripting.unregisterContentScripts({ ids: obsolete.map(item => item.id) });
    if (broad) {
      try {
        const effectiveExcludes = Array.from(new Set([...(port.excludedHosts || []), ...(port.appLeftOut || [])])).sort();
        await chrome.scripting.registerContentScripts([{
          id: "cs-all-sites", matches: ["*://*/*"], excludeMatches: effectiveExcludes.map(H.matchPatternFor),
          js: CONTENT_SCRIPT_FILES, runAt: "document_idle", allFrames: true, persistAcrossSessions: true,
        }]);
        port.allSitesRegistration = "ready";
        const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
        for (const tab of tabs) {
          if (port.siteMode !== "all" || port.allSitesConsent !== H.ALL_SITES_CONSENT_VERSION || !port.broadGranted) break;
          if (tab.id == null || tab.incognito) continue;
          try { await chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: CONTENT_SCRIPT_FILES }); }
          catch (_e) { /* Protected or browser-denied documents remain unread. */ }
        }
      } catch (_e) { port.allSitesRegistration = "failed"; }
    } else {
      port.allSitesRegistration = null;
      if (port.siteMode === "selected") {
        for (const origin of port.grantedOrigins) {
          const host = new URL(origin).host;
          if (!registered.some(item => item.id === "cs-" + H.matchHostFor(host))) {
            await port.setRegistration(origin, await registerSite(host));
          }
        }
      }
    }
    port.notify();
    refreshOpenTabs();
    requestSnapshots();
  });
  return registrationChain;
}

let sitePolicyChain = Promise.resolve();
let sitePolicyPendingCount = 0;
// An error is only shown on a site the owner shares. One left on a site that
// was removed, left out, or belonged to the other mode has no row to act on and
// would hold the toolbar's attention mark forever.
async function pruneOrphanSiteErrors() {
  if (!port?.clearSiteErrorsWhere) return;
  const chosen = new Set(port.chosenOrigins || []);
  const excluded = new Set(port.excludedHosts || []);
  await port.clearSiteErrorsWhere((origin) => port.siteMode === "all"
    ? [...excluded].some((site) => H.hostCovers(site, new URL(origin).hostname))
    : !chosen.has(origin));
}

function updateSitePolicy(msg) {
  // Admission withdraws immediately, including while earlier browser work waits.
  sitePolicyPendingCount++;
  port.sitePolicyPending = true;
  port.ownerSites.grantEpoch++;
  port.notify();
  const change = sitePolicyChain.catch(() => {}).then(async () => {
    if (msg.cmd !== "setSiteMode" || !["selected", "all"].includes(msg.mode)) return { ok: false, error: "invalid_site_mode" };
    if (msg.mode === "all" && (msg.agreed !== true || port.consentVersion !== globalThis.SolstoneCaptureGate.CONSENT_VERSION)) {
      return { ok: false, error: "missing_consent" };
    }
    const patch = { siteMode: msg.mode, allSitesConsent: msg.mode === "all" ? H.ALL_SITES_CONSENT_VERSION : port.allSitesConsent };
    try {
      const saved = await setCfg(patch);
      port.siteMode = saved.siteMode;
      port.excludedHosts = saved.excludedHosts;
      port.allSitesConsent = saved.allSitesConsent;
    } catch (_e) {
      port.ownerSites.reservation = null;
      await runReconcile();
      return { ok: false, error: "storage_error" };
    }
    port.ownerSites.reservation = null;
    await pruneOrphanSiteErrors();
    port.browserDeniedOrigins.clear();
    // Do not borrow grants from the previous mode if browser effects or the
    // permission snapshot fail (Safari may omit a removal event).
    port.grantedOrigins.clear();
    port.broadGranted = false;
    port.notify();
    if (port.siteMode === "selected") {
      try { await removePermission("*://*/*"); } catch (_e) { /* Owner scope is already selected-only. */ }
    }
    const permissionEpochAtStart = port.permissionEpoch;
    let perms;
    try { perms = await chrome.permissions.getAll(); }
    catch (_e) { return { ok: false, error: "permissions_changed" }; }
    if (permissionEpochAtStart !== port.permissionEpoch) return { ok: false, error: "permissions_changed" };
    port.broadGranted = (perms.origins || []).includes("*://*/*");
    const livePatterns = (perms.origins || []).filter(pattern => port.siteMode === "all" || pattern !== "*://*/*");
    Router.applyOwnerEvent(port, { type: "publish-grants", livePatterns, epochAtStart: permissionEpochAtStart });
    port.notify();
    await syncSiteRegistrations();
    await runReconcile();
    Router.runAdoptionPass({ port, setCfg, registerSite, refreshOpenTabs, checkCleanDeclines }).catch(() => {});
    return { ok: true, siteMode: port.siteMode, excludedHosts: [...port.excludedHosts], broadGranted: port.broadGranted };
  });
  const settled = change.finally(() => {
    sitePolicyPendingCount--;
    port.sitePolicyPending = sitePolicyPendingCount > 0;
    port.notify();
    if (!port.sitePolicyPending) requestSnapshots();
  });
  sitePolicyChain = settled;
  return settled;
}

async function executeBrowserRead(binding, request, authorize) {
  if (!authorize()) return false;
  const target = { tabId: binding.tabId, frameIds: [binding.frameId] };
  let timer;
  const execution = chrome.scripting.executeScript({ target,
    func: (realmToken, documentKey, read) => globalThis.__solstoneAuthorizedRead?.(realmToken, documentKey, read) === true,
    args: [binding.realmToken, binding.documentKey, request],
  });
  const results = await Promise.race([execution, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("browser_read_timeout")), 5000);
  })]).finally(() => clearTimeout(timer));
  return results?.some(item => item.frameId === binding.frameId && item.result === true) === true;
}

async function refreshSiteAccess() {
  const epoch = port.permissionEpoch;
  const perms = await chrome.permissions.getAll();
  if (epoch !== port.permissionEpoch) return { ok: false, error: "permissions_changed" };
  port.broadGranted = (perms.origins || []).includes("*://*/*");
  Router.applyOwnerEvent(port, { type: "publish-grants", livePatterns: perms.origins || [], epochAtStart: epoch });
  port.notify();
  await syncSiteRegistrations();
  Router.runAdoptionPass({ port, setCfg, registerSite, refreshOpenTabs, checkCleanDeclines }).catch(() => {});
  return { ok: true };
}

// Safari's "Clear Storage…" for the extension empties storage.local but keeps
// its IndexedDB. The identifier is mirrored into storage.local, so a missing
// mirror means the owner cleared it, and what the database kept goes too.
async function forgetClearedSafariStorage() {
  const kept = await DB.get("meta", "inst");
  if (!kept) return false;
  const mirror = await chrome.storage.local.get("inst");
  if (mirror.inst === kept) return false;
  for (const store of ["meta", "outbox", "producer"]) await DB.clear(store);
  return true;
}

async function doInit() {
  await chrome.alarms.create(ALARM_NAME, { periodInMinutes: 1 });

  const safari = globalThis.SolstoneSafariPort?.isSafari(chrome.runtime) === true;
  if (safari) await forgetClearedSafariStorage();

  let inst = await DB.get("meta", "inst");
  if (!inst) {
    const random = new Uint8Array(10);
    crypto.getRandomValues(random);
    const newInst = Uuid.uuidv7String(Uuid.uuidv7Bytes(Date.now(), random));
    await DB.put("meta", newInst, "inst");
    inst = newInst;
  }
  if (safari) {
    const mirror = await chrome.storage.local.get("inst");
    if (mirror.inst !== inst) await chrome.storage.local.set({ inst });
  }

  const consentVersion = (await DB.get("meta", "consentVersion")) || 0;
  const everConnected = !!(await DB.get("meta", "everConnected"));
  const cfg = await getCfg();
  const lossNotice = await DB.get("meta", "lossNotice");
  const storedTruncation = await DB.get("meta", "truncationByOrigin");
  const storedSiteErrors = await DB.get("meta", "siteErrors");

  let platform = "";
  try {
    if (typeof chrome !== "undefined" && chrome.runtime?.getPlatformInfo) {
      const info = await chrome.runtime.getPlatformInfo();
      platform = info?.os || "";
    }
  } catch (_e) {}

  if (!port) {
    await DB.clear("producer");
    port = new PortController({
      inst,
      platform,
      manifestVersion: VERSION,
      requestSnapshots,
      onStatusChange: (status) => updateBadge(status),
    });
  } else {
    port.inst = inst;
    port.platform = platform;
    port.requestSnapshots = requestSnapshots;
  }

  port.consentVersion = consentVersion;
  port.lossNotice = lossNotice || null;
  port.everConnected = everConnected;
  port.paused = cfg.paused;
  port.showPageIndicator = cfg.showPageIndicator;
  port.pauseWithApp = cfg.pauseWithApp !== false;
  port.chosenOrigins = new Set(cfg.chosenOrigins || []);
  port.siteMode = cfg.siteMode;
  port.excludedHosts = cfg.excludedHosts;
  port.allSitesConsent = cfg.allSitesConsent;
  port.persistCfg = setCfg;
  port.syncSiteRegistrations = syncSiteRegistrations;
  port.onLapseReservation = () => { lapseReservation(port); };
  port.declinedHostsKnown = Object.prototype.hasOwnProperty.call(cfg, "declinedHosts");
  port.declinedHosts = cfg.declinedHosts ? [...cfg.declinedHosts] : [];
  port.siteWideOrigins = cfg.siteWideOrigins ? [...cfg.siteWideOrigins] : [];
  // Loaded before the grant pass below, so a permission event during its
  // awaits works from the stored list, not an empty one.
  exactOnlyReady = false;
  port.exactOnlyKnown = Array.isArray(cfg.exactOnlyOrigins);
  port.exactOnlyOrigins = new Set(cfg.exactOnlyOrigins || []);
  port.onExactOnlyChange = () => { persistExactOnly(); };
  port.offeredOrigins = cfg.offeredOrigins ? [...cfg.offeredOrigins] : [];
  port.appLeftOut = cfg.appLeftOut ? [...cfg.appLeftOut] : [];
  // The app's list exactly as it sent it; sync compares raw strings (a restart
  // that lost it would make an app reset drop every app exclusion).
  port.appLeftOutRaw = Array.isArray(cfg.appLeftOutRaw) ? [...cfg.appLeftOutRaw] : [];
  port.appLeftOutEpoch = cfg.appLeftOutEpoch ?? null;
  port.appLeftOutRev = cfg.appLeftOutRev ?? 0;
  port.truncationByOrigin = storedTruncation && typeof storedTruncation === "object" ? storedTruncation : {};
  port.registration = storedSiteErrors?.registration && typeof storedSiteErrors.registration === "object" ? storedSiteErrors.registration : {};
  port.enqueue = storedSiteErrors?.enqueue && typeof storedSiteErrors.enqueue === "object" ? storedSiteErrors.enqueue : {};
  port.siteErrors = { registration: { ...port.registration }, enqueue: { ...port.enqueue } };
  port.ownerSites = {
    ...(port.ownerSites || {}),
    reservation: null,
    registration: port.registration,
    enqueue: port.enqueue,
    siteWide: new Set(port.siteWideOrigins),
    declinedHosts: new Set(port.declinedHosts),
  };

  port.permissionEpoch = permissionEpoch;
  let permissionsSettled = false;
  for (let attempt = 0; attempt < 3; attempt++) {
    const epoch = permissionEpoch;
    const latestCfg = await getCfg();
    const perms = await chrome.permissions.getAll();
    if (epoch !== permissionEpoch) continue;
    port.broadGranted = (perms.origins || []).includes("*://*/*");
    const liveGranted = new Set();
    const missingPatterns = [];
    for (const origin of latestCfg.chosenOrigins) {
      try {
        const u = new URL(origin);
        const pattern = H.matchPatternFor(u.host);
        const isMarked = port.siteWideOrigins ? port.siteWideOrigins.includes(origin) : false;
        const level = H.grantLevel(u.host, perms.origins, isMarked, u.protocol.replace(/:$/, ""));
        if (level) {
          liveGranted.add(origin);
          if (port.siteMode === "selected") {
            const regRes = await registerSite(u.host);
            await port.setRegistration(origin, regRes);
          }
        } else {
          missingPatterns.push(pattern);
        }
      } catch (_e) {}
      if (epoch !== permissionEpoch) break;
    }
    if (epoch !== permissionEpoch) continue;
    port.chosenOrigins = new Set(latestCfg.chosenOrigins);
    port.grantedOrigins = liveGranted;
    // Nothing is persisted during this pass, so the stored list is still the
    // prior. A site widens only when its own whole-site grant is live.
    port.exactOnlyOrigins = new Set(H.exactScope({
      chosen: latestCfg.chosenOrigins,
      live: perms.origins || [],
      prior: latestCfg.exactOnlyOrigins || [],
      priorKnown: Array.isArray(latestCfg.exactOnlyOrigins),
    }));
    port.exactOnlyKnown = true;
    port.ownerSites.registration = port.registration;
    port.ownerSites.enqueue = port.enqueue;
    port.drift = missingPatterns.length ? { patterns: Array.from(new Set(missingPatterns)).sort() } : null;
    permissionsSettled = true;
    break;
  }
  if (!permissionsSettled) throw new Error("permissions_changed_during_init");
  exactOnlyReady = true;
  await persistExactOnly();

  await pruneOrphanSiteErrors();
  port.lossNotice = (await DB.get("meta", "lossNotice")) || null;
  const cap = await Outbox.getCapacityStatus();
  port.pressure = cap.pressure;
  await runReconcile().catch(() => {});
  await syncSiteRegistrations();
  port.connect();
  updateBadge();
  refreshOpenTabs();
  await Router.runAdoptionPass({ port, setCfg, registerSite, refreshOpenTabs, checkCleanDeclines }).catch(() => {});
  try {
    const q = chrome.tabs?.query?.({}, (tabs) => {
      if (!chrome.runtime.lastError && Array.isArray(tabs) && typeof SolstoneTabAge !== "undefined") {
        SolstoneTabAge.start(tabs, port.wallNow());
      }
    });
    if (q && typeof q.then === "function") {
      q.then((tabs) => {
        if (Array.isArray(tabs) && typeof SolstoneTabAge !== "undefined") {
          SolstoneTabAge.start(tabs, port.wallNow());
        }
      }).catch(() => {});
    }
  } catch (_e) {}
  return port;
}

function ensureInit() {
  if (!initPromise) {
    initPromise = doInit().catch((err) => {
      initPromise = null;
      throw err;
    });
  }
  return initPromise;
}

// Register all listeners synchronously during evaluation
chrome.runtime.onConnect.addListener((p) => {
  if (p.name === "status") {
    if (!Router.isExtensionPageSender(p.sender, chrome.runtime.id)) {
      try { p.disconnect(); } catch (_e) {}
      return;
    }
    statusPorts.add(p);
    ensureInit().then(() => {
      // Opening the popup or settings is when an owner who just opened the
      // solstone app looks again, so try the app now rather than at the next
      // minute's poll.
      if (port && !port.livePort) port.connect();
      if (!port) return;
      Router.runAdoptionPass({ port, setCfg, registerSite, refreshOpenTabs, checkCleanDeclines }).catch(() => {});
      // Mid-renewal, the settled state reaches this surface through
      // updateBadge, like every surface already open.
      const status = port.getStatus();
      if (!status.hostSettling) p.postMessage({ type: "status", status });
    }).catch(() => {});
    p.onDisconnect.addListener(() => {
      statusPorts.delete(p);
    });
  }
});

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (sender?.id === chrome.runtime.id && sender.tab?.id != null) leaseTabs.add(sender.tab.id);
  ensureInit().then(() => {
    const deps = {
      port,
      setCfg,
      registerSite,
      unregisterSite,
      syncSiteRegistrations,
      walkRemoveSiteGrant,
      checkCleanDeclines,
      removeSiteOrigin,
      settlePermissionEffects,
      broadcastPause,
      broadcastIndicator,
      refreshOpenTabs,
      updateSitePolicy,
      executeBrowserRead,
      refreshSiteAccess,
      broadcastLeaseUpdate,
      getBrowserIdentity,
    };
    return Router.route(msg, sender, deps);
  }).then(sendResponse, (err) => {
    sendResponse({ ok: false, error: (err && err.message) || "internal_error" });
  });
  return true;
});

chrome.tabs.onRemoved.addListener((tabId) => {
  leaseTabs.delete(tabId);
  port?.pruneTruncationDocuments?.(slot => slot.split(":")[0] !== String(tabId));
  Router.destroyBinding(tabId);
  if (typeof SolstoneTabAge !== "undefined") {
    SolstoneTabAge.forget(tabId);
  }
  refreshOpenTabs();
});
chrome.tabs.onCreated?.addListener((tab) => {
  if (port && typeof SolstoneTabAge !== "undefined") {
    SolstoneTabAge.noteCreated(tab, port.wallNow());
  }
  refreshOpenTabs();
});
chrome.tabs.onUpdated?.addListener(() => refreshOpenTabs());
chrome.windows?.onFocusChanged?.addListener((windowId) => {
  if (windowId !== chrome.windows.WINDOW_ID_NONE) tryAppNow();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) {
    ensureInit().then(async () => {
      // Safari doesn't tell a running extension that its storage was cleared.
      if (globalThis.SolstoneSafariPort?.isSafari(chrome.runtime) === true &&
          await forgetClearedSafariStorage()) {
        chrome.runtime.reload();
        return;
      }
      if (port) {
        await port.poll();
      }
      await runReconcile().catch(() => {});
      await Router.runAdoptionPass({ port, setCfg, registerSite, refreshOpenTabs, checkCleanDeclines }).catch(() => {});
    }).catch(() => {});
  }
});

chrome.permissions.onRemoved.addListener(async (details) => {
  const removedPatterns = details?.origins || [];
  if (port) {
    Router.applyOwnerEvent(port, { type: "browser-removed", patterns: removedPatterns });
    if (removedPatterns.includes("*://*/*")) port.broadGranted = false;
    permissionEpoch = port.permissionEpoch;
    port.notify();
    refreshOpenTabs();
    const epochAtStart = permissionEpoch;
    let perms;
    try { perms = await chrome.permissions.getAll(); }
    catch (_e) { return; }
    if (permissionEpoch !== epochAtStart || !Array.isArray(perms?.origins)) return;
    // What's left after this removal. A wider site grant still covers the
    // sites under it, and a snapshot that hasn't caught up with this removal
    // can't bring the withdrawn grant back.
    const remaining = perms.origins.filter((pattern) => !removedPatterns.includes(pattern));
    port.broadGranted = remaining.includes("*://*/*");
    Router.applyOwnerEvent(port, { type: "publish-grants", livePatterns: remaining, epochAtStart });
    const missing = [];
    for (const o of port.chosenOrigins) {
      try {
        const u = new URL(o);
        const host = u.host;
        const scheme = u.protocol.replace(/:$/, "");
        const isMarked = Array.isArray(port.siteWideOrigins) && port.siteWideOrigins.includes(o);
        if (!H.grantLevel(host, remaining, isMarked, scheme)) missing.push(H.matchPatternFor(host));
      } catch (_e) {}
    }
    port.drift = missing.length ? { patterns: Array.from(new Set(missing)).sort() } : null;
    port.notify();
    syncSiteRegistrations().catch(() => {});
    await runReconcile().catch(() => {});
    const adoption = Router.runAdoptionPass({ port, setCfg, registerSite, refreshOpenTabs, checkCleanDeclines });
    if (Router.grantChainBusy()) adoption.catch(() => {});
    else await adoption;
    return;
  }
  permissionEpoch++;
  runReconcile().catch(() => {});
});

chrome.permissions.onAdded.addListener(async (details) => {
  const addedPatterns = details?.origins || [];
  if (port) {
    const resPat = port.ownerSites?.reservation?.pattern;
    const syncPatterns = resPat && addedPatterns.includes(resPat) ? [resPat] : addedPatterns;
    const sync = Router.applyOwnerEvent(port, { type: "browser-added-sync", patterns: syncPatterns, now: port.now() });
    permissionEpoch = port.permissionEpoch;
    const epochAtStart = sync.result.epochAtStart;
    let perms;
    try { perms = await chrome.permissions.getAll(); }
    catch (_e) { return; }
    if (permissionEpoch !== epochAtStart || !Array.isArray(perms?.origins)) return;
    port.broadGranted = perms.origins.includes("*://*/*");
    const published = Router.applyOwnerEvent(port, { type: "publish-grants", livePatterns: perms.origins, epochAtStart });
    if (!published.result.ok) return;
    const missing = [];
    for (const o of port.chosenOrigins) {
      try {
        const u = new URL(o);
        const host = u.host;
        const scheme = u.protocol.replace(/:$/, "");
        const isMarked = Array.isArray(port.siteWideOrigins) && port.siteWideOrigins.includes(o);
        if (!H.grantLevel(host, perms.origins, isMarked, scheme)) missing.push(H.matchPatternFor(host));
      } catch (_e) {}
    }
    port.drift = missing.length ? { patterns: Array.from(new Set(missing)).sort() } : null;
    const epochs = Router.ownerStateFor(port);
    for (const origin of Array.from(port.grantedOrigins)) {
      if (port.siteMode === "all") break;
      if (permissionEpoch !== epochAtStart) return;
      let host;
      try { host = new URL(origin).host; } catch (_e) { continue; }
      let status = "failed";
      try { status = await registerSite(host); } catch (_e) {}
      const noted = Router.applyOwnerEvent(port, {
        type: "note-registration", origin, status,
        capturedGrantEpoch: epochs.grantEpoch, capturedPermissionEpoch: epochAtStart,
      });
      if (!noted.result.ok) return;
      await port.setRegistration(origin, status);
    }
    if (sync.result.reservation?.origin) {
      await Router.completeReservedOrigin(sync.result.reservation, {
        port, setCfg, registerSite, settlePermissionEffects, refreshOpenTabs,
      });
    }
    syncSiteRegistrations().catch(() => {});
    if (permissionEpoch !== epochAtStart) return;
    port.notify();
    refreshOpenTabs();
    await runReconcile().catch(() => {});
    const adoption = Router.runAdoptionPass({ port, setCfg, registerSite, refreshOpenTabs, checkCleanDeclines });
    if (Router.grantChainBusy()) adoption.catch(() => {});
    else await adoption;
    return;
  }
  permissionEpoch++;
  runReconcile().catch(() => {});
});

function init() {
  return ensureInit();
}

chrome.runtime.onInstalled.addListener((details) => {
  if (details.reason === "install") {
    try {
      chrome.runtime.openOptionsPage();
    } catch (_e) {}
  }
  init();
});

chrome.runtime.onStartup.addListener(init);

chrome.runtime.onUpdateAvailable?.addListener(() => {
  if (!port) return;
  port.updateCheck = "update-available";
  port.notify();
});

// Start initialization once after listeners are registered
init();

globalThis.SolstoneBackground = {
  doInit,
  ensureInit,
  updateBadge,
  broadcastLeaseUpdate,
  registerSite,
  unregisterSite,
  removeSiteOrigin,
  walkRemoveSiteGrant,
  checkCleanDeclines,
  updateSitePolicy,
  runReconcile,
  getCfg,
  setCfg,
  get port() { return port; },
};
