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
    "lib/native_port.js",
    "lib/status.js",
    "lib/owner_sites.js",
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

const VERSION = "0.4.0";
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
  "content.js",
];

const DEFAULT_CFG = {
  paused: false,
  showPageIndicator: false,
  chosenOrigins: [],
  siteMode: "selected",
  excludedHosts: [],
  allSitesConsent: 0,
};

let port = null;
let initPromise = null;
let permissionEpoch = 0;
let badgeEpoch = 0;
let openTabsGeneration = 0;
let badgeChain = Promise.resolve();
const statusPorts = new Set();
// Tabs that may hold a lease must receive withdrawal without a fresh query.
const leaseTabs = new Set();

async function getCfg() {
  const r = await chrome.storage.local.get("cfg");
  const stored = r.cfg || {};
  let chosenOrigins = stored.chosenOrigins;
  if (!Array.isArray(chosenOrigins)) {
    chosenOrigins = Array.isArray(stored.grantedOrigins) ? stored.grantedOrigins : [];
    const next = {
      paused: !!stored.paused,
      showPageIndicator: !!stored.showPageIndicator,
      chosenOrigins,
    };
    await chrome.storage.local.set({ cfg: next });
    return { ...DEFAULT_CFG, ...next };
  }
  return {
    paused: !!stored.paused,
    showPageIndicator: !!stored.showPageIndicator,
    chosenOrigins,
    siteMode: stored.siteMode === "all" ? "all" : "selected",
    excludedHosts: Array.isArray(stored.excludedHosts) ? [...new Set(stored.excludedHosts.map(H.excludedHostname).filter(Boolean))].sort() : [],
    allSitesConsent: stored.allSitesConsent === H.ALL_SITES_CONSENT_VERSION ? stored.allSitesConsent : 0,
  };
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

  const iconInfo = Status && Status.iconState
    ? Status.iconState(status)
    : { prefix: "icon-offline-", badge: "", title: "solstone" };

  const prefix = iconInfo.prefix;
  const badge = iconInfo.badge || "";
  const title = iconInfo.title || "solstone";

  // Authority publication never waits for browser action painting.
  for (const sp of statusPorts) {
    try { sp.postMessage({ type: "status", status }); }
    catch (_e) { statusPorts.delete(sp); }
  }
  broadcastLeaseUpdate(status, currentBadgeEpoch);
  badgeChain = badgeChain.catch(() => {}).then(async () => {
    if (badgeEpoch !== currentBadgeEpoch) return;
    await chrome.action.setIcon({ path: ICON_SET(prefix) });
    if (badgeEpoch !== currentBadgeEpoch) return;
    await chrome.action.setBadgeText({ text: badge });
    if (badgeEpoch !== currentBadgeEpoch) return;
    if (badge) await chrome.action.setBadgeBackgroundColor({ color: "#9F2D2D" });
    if (badgeEpoch !== currentBadgeEpoch) return;
    await chrome.action.setTitle({ title });
  });
  await badgeChain.catch(() => {});
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

function broadcastLeaseUpdate(status, epoch = badgeEpoch) {
  if (!status) return;
  const message = {
    kind: "leaseUpdate", captureEpoch: status.captureEpoch, lease: status.lease,
    paused: status.paused, consentVersion: status.consentVersion,
    grantedOrigins: status.grantedOrigins || [], showIndicator: status.showPageIndicator,
    siteMode: status.siteMode, excludedHosts: status.excludedHosts || [],
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
function patternNeeded(pattern) {
  if (!port) return false;
  const reservation = port.ownerSites?.reservation;
  if (reservation?.pattern === pattern && port.now() < reservation.expiresAt) return true;
  if (pattern === "*://*/*" && port.siteMode === "all" && port.allSitesConsent === H.ALL_SITES_CONSENT_VERSION) return true;
  return [...port.chosenOrigins].some(origin => {
    try { return H.matchPatternFor(new URL(origin).host) === pattern; }
    catch (_e) { return false; }
  });
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
      if (tab.id != null) {
        chrome.tabs.sendMessage(tab.id, { kind: "stop" }, () => void chrome.runtime.lastError);
        Router.destroyBinding(tab.id);
      }
    }
  } catch (_e) {
    /* ignore */
  }

  try {
    if (patternNeeded(pattern)) { await registerSite(host); return; }
    await removePermission(pattern);
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

  let reservation = port?.ownerSites?.reservation || null;
  if (reservation && port.now() >= reservation.expiresAt) {
    Router.applyOwnerEvent(port, { type: "drop-reservation" });
    reservation = null;
  }
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

  for (const action of actions) {
    if (action.op === "release") {
      try {
        if (patternNeeded(action.origin)) continue;
        await removePermission(action.origin);
      } catch (_e) {
        /* ignore */
      }
    }
  }
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
        await chrome.scripting.registerContentScripts([{
          id: "cs-all-sites", matches: ["*://*/*"], excludeMatches: port.excludedHosts.map(H.matchPatternFor),
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
function updateSitePolicy(msg) {
  // Admission withdraws immediately, including while earlier browser work waits.
  sitePolicyPendingCount++;
  port.sitePolicyPending = true;
  port.ownerSites.grantEpoch++;
  port.notify();
  const change = sitePolicyChain.catch(() => {}).then(async () => {
    let patch;
    if (msg.cmd === "setSiteMode") {
      if (!["selected", "all"].includes(msg.mode)) return { ok: false, error: "invalid_site_mode" };
      if (msg.mode === "all" && (msg.agreed !== true || port.consentVersion !== globalThis.SolstoneCaptureGate.CONSENT_VERSION)) {
        return { ok: false, error: "missing_consent" };
      }
      patch = { siteMode: msg.mode, allSitesConsent: msg.mode === "all" ? H.ALL_SITES_CONSENT_VERSION : port.allSitesConsent };
    } else {
      if (port.siteMode !== "all" || typeof msg.excluded !== "boolean") return { ok: false, error: "wrong_site_mode" };
      const host = H.excludedHostname(msg.host);
      if (!host) return { ok: false, error: "invalid_host" };
      const hosts = new Set(port.excludedHosts);
      if (msg.excluded) hosts.add(host); else hosts.delete(host);
      patch = { excludedHosts: [...hosts].sort() };
    }
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
  port.chosenOrigins = new Set(cfg.chosenOrigins || []);
  port.siteMode = cfg.siteMode;
  port.excludedHosts = cfg.excludedHosts;
  port.allSitesConsent = cfg.allSitesConsent;
  port.truncationByOrigin = storedTruncation && typeof storedTruncation === "object" ? storedTruncation : {};
  port.registration = storedSiteErrors?.registration && typeof storedSiteErrors.registration === "object" ? storedSiteErrors.registration : {};
  port.enqueue = storedSiteErrors?.enqueue && typeof storedSiteErrors.enqueue === "object" ? storedSiteErrors.enqueue : {};
  port.siteErrors = { registration: { ...port.registration }, enqueue: { ...port.enqueue } };
  port.ownerSites = { ...(port.ownerSites || {}), reservation: null, registration: port.registration, enqueue: port.enqueue };

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
        if (perms.origins?.includes(pattern) || perms.origins?.includes("*://*/*")) {
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
    port.ownerSites.registration = port.registration;
    port.ownerSites.enqueue = port.enqueue;
    port.drift = missingPatterns.length ? { patterns: Array.from(new Set(missingPatterns)).sort() } : null;
    permissionsSettled = true;
    break;
  }
  if (!permissionsSettled) throw new Error("permissions_changed_during_init");

  port.lossNotice = (await DB.get("meta", "lossNotice")) || null;
  const cap = await Outbox.getCapacityStatus();
  port.pressure = cap.pressure;
  await runReconcile().catch(() => {});
  await syncSiteRegistrations();
  port.connect();
  updateBadge();
  refreshOpenTabs();
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
      if (port) p.postMessage({ type: "status", status: port.getStatus() });
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
      removeSiteOrigin,
      settlePermissionEffects,
      broadcastPause,
      broadcastIndicator,
      refreshOpenTabs,
      updateSitePolicy,
      executeBrowserRead,
      refreshSiteAccess,
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
  refreshOpenTabs();
});
chrome.tabs.onCreated?.addListener(() => refreshOpenTabs());
chrome.tabs.onUpdated?.addListener(() => refreshOpenTabs());

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
    port.broadGranted = perms.origins.includes("*://*/*");
    const missing = [];
    for (const o of port.chosenOrigins) {
      try {
        const pat = H.matchPatternFor(new URL(o).host);
        if (!perms.origins.includes(pat) && !perms.origins.includes("*://*/*")) {
          missing.push(pat);
        }
      } catch (_e) {}
    }
    port.drift = missing.length ? { patterns: Array.from(new Set(missing)).sort() } : null;
    port.notify();
    syncSiteRegistrations().catch(() => {});
    runReconcile().catch(() => {});
    return;
  }
  permissionEpoch++;
  runReconcile().catch(() => {});
});

chrome.permissions.onAdded.addListener(async (details) => {
  const addedPatterns = details?.origins || [];
  if (port) {
    const sync = Router.applyOwnerEvent(port, { type: "browser-added-sync", patterns: addedPatterns, now: port.now() });
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
        const pat = H.matchPatternFor(new URL(o).host);
        if (!perms.origins.includes(pat) && !perms.origins.includes("*://*/*")) {
          missing.push(pat);
        }
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
    runReconcile().catch(() => {});
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
  registerSite,
  unregisterSite,
  removeSiteOrigin,
  runReconcile,
  getCfg,
  setCfg,
  get port() { return port; },
};
