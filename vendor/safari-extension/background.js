// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

if (typeof importScripts === "function") {
  importScripts(
    "i18n/catalog.js",
    "i18n/contracts.js",
    "i18n/index.js",
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
    "lib/segment.js",
    "lib/gate.js",
    "lib/native_outbox.js",
    "lib/about.js",
    "lib/safari_port.js",
    "lib/safari_ios_port.js",
    "lib/left_out.js",
    "lib/native_port.js",
    "lib/status.js",
    "lib/tab_age.js",
    "lib/page_facts.js",
    "lib/router.js"
  );
}

const t = (...args) => globalThis.SolstoneI18n.t(...args);
const H = globalThis.SolstoneHosts;
const DB = globalThis.SolstoneDB;
const Failures = globalThis.SolstoneFailures;
const Uuid = globalThis.SolstoneUuid;
const Router = globalThis.SolstoneRouter;
const PortController = globalThis.SolstoneNativePort;
const Outbox = globalThis.SolstoneNativeOutbox;
const Status = globalThis.SolstoneStatus;

const VERSION = "0.5.10";
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
  "lib/gate.js",
  "lib/page_facts.js",
  "content.js",
];

const DEFAULT_CFG = {
  paused: false,
  pauseWithApp: true,
  excludedHosts: [],
  appLeftOut: [],
  appLeftOutRaw: [],
  fence: null,
};

function formatAddIntent(intent) {
  if (!intent || typeof intent !== "object" || typeof intent.origin !== "string") return null;
  let url;
  try { url = new URL(intent.origin); } catch (_e) { return null; }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || url.origin !== intent.origin) return null;
  if (!Number.isFinite(intent.at)) return null;
  return { origin: intent.origin, at: intent.at };
}

function formatCfg(stored) {
  const res = {
    paused: !!stored.paused,
    pauseWithApp: stored.pauseWithApp !== false,
    excludedHosts: Array.isArray(stored.excludedHosts)
      ? [...new Set(stored.excludedHosts.map(H.storedExcludedHostname).filter(Boolean))].sort()
      : [],
    appLeftOut: Array.isArray(stored.appLeftOut) ? [...stored.appLeftOut] : [],
    appLeftOutRaw: Array.isArray(stored.appLeftOutRaw) ? [...stored.appLeftOutRaw] : [],
  };
  if (stored.appLeftOutEpoch !== undefined && stored.appLeftOutEpoch !== null) {
    res.appLeftOutEpoch = stored.appLeftOutEpoch;
  }
  if (typeof stored.appLeftOutRev === "number") {
    res.appLeftOutRev = stored.appLeftOutRev;
  }
  if (stored.siteGrant) {
    res.siteGrant = stored.siteGrant;
  }
  if (stored.startup) {
    res.startup = stored.startup;
  }
  if (stored.clearedNotice === true) {
    res.clearedNotice = true;
  }
  if (stored.firstRunAnswered === true) {
    res.firstRunAnswered = true;
  }
  if (stored.fence) {
    res.fence = {
      entries: Array.isArray(stored.fence.entries) ? [...stored.fence.entries] : [],
      exact: Array.isArray(stored.fence.exact) ? [...stored.fence.exact] : [],
      exactKnown: stored.fence.exactKnown === true,
      siteWide: Array.isArray(stored.fence.siteWide) ? [...stored.fence.siteWide] : [],
      declined: Array.isArray(stored.fence.declined) ? [...stored.fence.declined] : [],
      answered: !!stored.fence.answered,
      sawMore: !!stored.fence.sawMore,
      cleanAt: stored.fence.cleanAt ?? null,
    };
  } else {
    res.fence = null;
  }
  res.addIntent = formatAddIntent(stored.addIntent);
  return res;
}

async function getCfg() {
  const r = await chrome.storage.local.get("cfg");
  const stored = r.cfg || {};
  if (stored.siteGrant !== "live") {
    return Object.assign({}, stored);
  }
  const next = formatCfg(stored);
  await chrome.storage.local.set({ cfg: next });
  return next;
}

let cfgChain = Promise.resolve();
function setCfg(patch) {
  cfgChain = cfgChain.catch(() => {}).then(async () => {
    const r = await chrome.storage.local.get("cfg");
    const stored = r.cfg || {};
    if (stored.siteGrant !== "live" && (!patch || patch.siteGrant !== "live")) {
      throw new Error("storage_error");
    }
    const merged = Object.assign({}, stored, patch);
    const next = formatCfg(merged);
    await chrome.storage.local.set({ cfg: next });
    return next;
  });
  return cfgChain;
}

let port = null;
// Removals that arrive before the port exists still close that pattern.
const sessionTombstones = new Set();
let initPromise = null;
let latestRead = Promise.resolve();
// Last successful permission read and the manifest version already injected.
// Kept out of cfg so a stored list cannot become the live grant by itself.
let grantWatch = { patterns: [], injectedVersion: null };
let badgeEpoch = 0;
let openTabsGeneration = 0;
let badgeChain = Promise.resolve();
let paintEpoch = 0;
let toolbarLink = null;
let toolbarWake = null;
let lastAppNudgeAt = -Infinity;
const statusPorts = new Set();
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
  // Safari on iPhone and iPad keeps the logo it starts with. The popup says the state.
  if (globalThis.SolstoneCopy?.MOBILE === true) return;
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
  const title = iconInfo.title || t("browser.brand.name");
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
    if (!port || port.behind) return;
    // A live port only needs asking when it answers one exchange at a time.
    const live = port.livePort;
    if (live && typeof live.refresh !== "function") return;
    const now = port.now();
    if (now - lastAppNudgeAt < 5000) return;
    lastAppNudgeAt = now;
    if (live) live.refresh();
    else port.connect();
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
    kind: "leaseUpdate",
    captureEpoch: status.captureEpoch,
    lease: status.lease,
    paused: status.paused,
    consentVersion: status.consentVersion,
    livePatterns: status.livePatterns || [],
    fence: status.fence || null,
    broadGrant: status.broadGrant === true,
    excludedHosts: status.excludedHosts || [],
    appLeftOut: status.appLeftOut || [],
    hostCapture: status.hostCapture,
    hostDelivery: status.hostDelivery,
    hostFailure: status.hostFailure,
    custody: status.custody,
    pressure: status.pressure,
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

function requestSnapshots() {
  chrome.tabs.query({}, (tabs) => {
    for (const tab of tabs || []) {
      if (tab.id == null) continue;
      chrome.tabs.sendMessage(tab.id, { kind: "resnapshot" }, () => void chrome.runtime.lastError);
    }
  });
}

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

function sameStringSet(left, right) {
  const a = [...(left || [])].map(String).sort();
  const b = [...(right || [])].map(String).sort();
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

function stripMatchPort(pattern) {
  return String(pattern || "").trim().replace(/:\d+(?=\/\*$)/, "");
}

function rememberGrantWatch(stored) {
  const patterns = Array.isArray(stored?.patterns) ? stored.patterns.filter((p) => typeof p === "string") : [];
  const injectedVersion = typeof stored?.injectedVersion === "string" ? stored.injectedVersion : null;
  grantWatch = { patterns, injectedVersion };
}

async function saveGrantWatch() {
  try {
    await chrome.storage.local.set({
      grantWatch: {
        patterns: [...grantWatch.patterns],
        injectedVersion: grantWatch.injectedVersion,
      },
    });
  } catch (_e) {}
}

function leftOutExcludeMatches() {
  const hosts = Array.from(new Set([...(port?.excludedHosts || []), ...(port?.appLeftOut || [])])).sort();
  const matches = [];
  for (const host of hosts) {
    const pattern = H.matchPatternFor(host);
    if (pattern) matches.push(pattern);
  }
  return matches;
}

function addScriptGroup(groups, id, match, rowOrigin) {
  if (!id || !match) return;
  let group = groups.get(id);
  if (!group) {
    group = { id, matches: new Set(), rowOrigins: new Set() };
    groups.set(id, group);
  }
  group.matches.add(match);
  if (rowOrigin) group.rowOrigins.add(rowOrigin);
}

function desiredScripts() {
  const patterns = port?.livePatterns || [];
  const fenced = port?.fence !== null && typeof port.fence === "object";
  if (!fenced && H.everySiteLive(patterns)) {
    const broad = patterns.filter((pattern) => H.isBroadPattern(pattern));
    return [{
      id: "cs-all-sites",
      matches: broad.length > 0 ? broad : ["*://*/*"],
      excludeMatches: leftOutExcludeMatches(),
      rowOrigins: [],
    }];
  }

  const groups = new Map();
  if (fenced) {
    for (const entry of port.fence.entries || []) {
      let url;
      try { url = new URL(entry); } catch (_e) { continue; }
      const host = url.hostname.toLowerCase();
      if (!host) continue;
      addScriptGroup(groups, "cs-" + host, H.matchPatternFor(host), url.origin);
    }
  } else {
    for (const pattern of patterns) {
      if (H.isBroadPattern(pattern)) continue;
      const row = H.grantRowOrigin(pattern);
      if (!row) continue;
      let host = "";
      try { host = new URL(row).hostname.toLowerCase(); } catch (_e) { continue; }
      if (!host) continue;
      addScriptGroup(groups, "cs-" + host, stripMatchPort(pattern), row);
    }
  }

  return [...groups.values()].map((group) => ({
    id: group.id,
    matches: [...group.matches],
    excludeMatches: [],
    rowOrigins: [...group.rowOrigins],
  }));
}

function registrationsMatch(desired, registered) {
  const ours = (registered || []).filter((script) => script?.id?.startsWith("cs-"));
  if (ours.length !== desired.length) return false;
  for (const script of desired) {
    const current = ours.find((item) => item.id === script.id);
    if (!current) return false;
    if (!sameStringSet(current.matches, script.matches)) return false;
    if (!sameStringSet(current.excludeMatches, script.excludeMatches)) return false;
  }
  return true;
}

async function registerPrepared(script) {
  const record = {
    id: script.id,
    matches: [...script.matches],
    js: CONTENT_SCRIPT_FILES,
    runAt: "document_idle",
    allFrames: true,
    persistAcrossSessions: true,
  };
  if (script.excludeMatches.length > 0) record.excludeMatches = [...script.excludeMatches];

  try {
    await chrome.scripting.registerContentScripts([record]);
  } catch (_error) {
    let registered = [];
    try {
      registered = await chrome.scripting.getRegisteredContentScripts({ ids: [script.id] });
    } catch (_e) {
      return "failed";
    }
    const current = registered.find((item) => item?.id === script.id);
    if (!current ||
        !sameStringSet(current.matches, script.matches) ||
        !sameStringSet(current.excludeMatches, script.excludeMatches) ||
        !Failures.contentScriptRegistrationSatisfied(script.id, registered)) {
      return "failed";
    }
  }

  let hadTabError = false;
  try {
    const tabs = await chrome.tabs.query({ url: script.matches });
    for (const tab of tabs || []) {
      if (tab.id == null || tab.incognito || !tab.url) continue;
      let origin = "";
      try { origin = new URL(tab.url).origin; } catch (_e) { continue; }
      if (!H.originGranted(port, origin)) continue;
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
  return hadTabError ? "reload" : "ready";
}

async function applyDesiredScripts(desired, registered) {
  const desiredIds = new Set(desired.map((script) => script.id));
  const obsolete = (registered || []).filter((item) => item?.id?.startsWith("cs-") && !desiredIds.has(item.id));
  if (obsolete.length) {
    try { await chrome.scripting.unregisterContentScripts({ ids: obsolete.map((item) => item.id) }); } catch (_e) {}
  }
  if (!desiredIds.has("cs-all-sites")) port.allSitesRegistration = null;

  for (const script of desired) {
    const current = (registered || []).find((item) => item.id === script.id);
    const same = current &&
      sameStringSet(current.matches, script.matches) &&
      sameStringSet(current.excludeMatches, script.excludeMatches);
    if (same) continue;
    if (current) {
      try { await chrome.scripting.unregisterContentScripts({ ids: [script.id] }); } catch (_e) {}
    }
    const status = await registerPrepared(script);
    if (script.id === "cs-all-sites") {
      port.allSitesRegistration = status === "failed" ? "failed" : "ready";
    } else {
      for (const origin of script.rowOrigins) {
        await port.setRegistration?.(origin, status);
      }
    }
  }
}

async function registerSite() {
  return syncSiteRegistrations();
}

async function unregisterSite() {
  return syncSiteRegistrations();
}

let registrationChain = Promise.resolve();
function syncSiteRegistrations(options = {}) {
  const grantFanout = options.grantFanout === true;
  registrationChain = registrationChain.catch(() => {}).then(async () => {
    if (!port) return;
    let registered = [];
    try {
      registered = await chrome.scripting.getRegisteredContentScripts();
    } catch (_e) {
      registered = [];
    }
    const desired = desiredScripts();
    const matched = registrationsMatch(desired, registered);
    if (matched && !grantFanout) return;
    if (!matched) await applyDesiredScripts(desired, registered);
    port.notify();
    refreshOpenTabs();
    if (grantFanout) requestSnapshots();
  });
  return registrationChain;
}

async function reinjectOpenTabs() {
  if (!port || grantWatch.injectedVersion === VERSION) return;
  let tabs = [];
  try {
    tabs = await chrome.tabs.query({});
  } catch (_e) {
    tabs = [];
  }
  for (const tab of tabs || []) {
    if (!tab || tab.id == null || tab.incognito || !tab.url) continue;
    let origin = "";
    try { origin = new URL(tab.url).origin; } catch (_e) { continue; }
    if (!H.originGranted(port, origin)) continue;
    try {
      await chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, files: CONTENT_SCRIPT_FILES });
    } catch (_e) {}
  }
  grantWatch.injectedVersion = VERSION;
  await saveGrantWatch();
}

async function pruneOrphanSiteErrors() {
  if (port?.faults instanceof Map) {
    for (const origin of [...port.faults.keys()]) {
      if (!H.originGranted(port, origin)) port.faults.delete(origin);
    }
  }
  if (!port?.clearSiteErrorsWhere) return;
  await port.clearSiteErrorsWhere((origin) => {
    return !H.originGranted(port, origin);
  });
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

function clearedSafariCfg() {
  return {
    paused: true,
    pauseWithApp: true,
    clearedNotice: true,
    siteGrant: "live",
    startup: "cleared",
    firstRunAnswered: true,
    fence: null,
    excludedHosts: [],
    appLeftOut: [],
  };
}

// Read-only. A throw rejects. Startup and the alarm share this comparison.
async function detectSafariCleared() {
  const kept = await DB.get("meta", "inst");
  if (!kept) return { mismatch: false };
  const mirror = await chrome.storage.local.get("inst");
  if (mirror.inst === kept) return { mismatch: false };
  return { mismatch: true };
}

async function checkSafariClearedStorage() {
  const detected = await detectSafariCleared();
  if (!detected.mismatch) return { mismatch: false, cleared: false };
  try {
    await chrome.storage.local.set({ cfg: clearedSafariCfg() });
  } catch (err) {
    return { mismatch: true, cleared: false, error: err };
  }
  for (const store of ["meta", "outbox", "producer"]) await DB.clear(store);
  return { mismatch: true, cleared: true };
}

const SAFARI_CHECK_BOUND_MS = 10000;
let safariWatch = null;

function beginSafariWatch() {
  const watch = { phase: "detect", startedAt: Date.now(), abandoned: false, promise: null };
  safariWatch = watch;
  watch.promise = (async () => {
    let detected;
    try {
      detected = await detectSafariCleared();
    } catch (_e) {
      if (safariWatch === watch) safariWatch = null;
      return;
    }
    const elapsed = Date.now() - watch.startedAt;
    if (watch.abandoned || !port || (watch.phase === "detect" && elapsed >= SAFARI_CHECK_BOUND_MS)) {
      watch.abandoned = true;
      if (safariWatch === watch) safariWatch = null;
      return;
    }
    if (!detected.mismatch) {
      if (safariWatch === watch) safariWatch = null;
      return;
    }
    port.paused = true;
    port.clearedNotice = true;
    port.notify();
    watch.phase = "clear";
    try {
      await chrome.storage.local.set({ cfg: clearedSafariCfg() });
    } catch (_e) {
      if (safariWatch === watch) safariWatch = null;
      return;
    }
    try {
      for (const store of ["meta", "outbox", "producer"]) await DB.clear(store);
    } catch (_e) {
      if (safariWatch === watch) safariWatch = null;
      return;
    }
    if (safariWatch === watch) safariWatch = null;
    chrome.runtime.reload();
  })();
  return watch.promise;
}

// A page click stores an intent, then asks the browser. The next read joins the
// site only when that intent is still fresh and a site grant, not a broad one, covers it.
// A negative age stays stored. Only an age past ten minutes is forgotten.
function addIntentExpired() {
  const intent = port.addIntent;
  if (!intent || typeof intent !== "object" || typeof intent.origin !== "string") return false;
  if (!Number.isFinite(intent.at)) return false;
  return port.wallNow() - intent.at > 600000;
}

function completeAddIntent(applied) {
  const intent = port.addIntent;
  if (!intent || typeof intent !== "object" || typeof intent.origin !== "string") return null;
  if (!Number.isFinite(intent.at)) return null;
  const age = port.wallNow() - intent.at;
  if (age < 0 || age > 600000) return null;
  if (!H.siteLevelCovers(applied, intent.origin)) return null;
  return H.admitFenceOrigin(port.fence, intent.origin, applied, port.excludedHosts, port.appLeftOut);
}

async function applySnapshot(applied, tombstoneFiltered, options = {}) {
  if (!port) return;
  const serial = options.serial ?? port.readSerial;
  const still = () => port && serial === port.readSerial;
  const prevPatterns = port.livePatterns || [];
  const same = prevPatterns.length === applied.length &&
    prevPatterns.every((p, i) => p === applied[i]);

  const prevFence = port.fence;
  const prevFenceEntries = prevFence ? (prevFence.entries || []) : [];
  let fenceEnded = false;
  let fenceEntriesChanged = false;
  let intentTaken = false;
  let intentExpired = addIntentExpired();
  let nextFence = port.fence;
  let nextExcluded = port.excludedHosts;
  let fenceWrite = null;

  if (port.fence !== null && typeof port.fence === "object") {
    const admitted = completeAddIntent(applied);
    let working = port.fence;
    if (admitted) {
      working = admitted;
      intentTaken = true;
    }
    const res = H.applySnapshotToFence(working, applied, {
      wallNow: port.wallNow(),
      tombstoneFiltered,
      leftOutHosts: Array.from(new Set([...(port.excludedHosts || []), ...(port.appLeftOut || [])])),
    });
    const holdCleanEnd = port.agreementRules === "chrome" && port.consentVersion === 1;
    if (res.ended && !holdCleanEnd) {
      const finished = H.finishFence(res.fence, applied, port.excludedHosts);
      nextFence = finished.fence;
      nextExcluded = finished.excludedHosts;
      fenceEnded = true;
      fenceWrite = { fence: null, excludedHosts: finished.excludedHosts };
      if (intentTaken || intentExpired) fenceWrite.addIntent = null;
    } else {
      const updatedFence = res.fence;
      const fenceChanged = JSON.stringify(working) !== JSON.stringify(updatedFence);
      nextFence = updatedFence;
      if (fenceChanged || intentTaken || intentExpired) {
        fenceWrite = { fence: updatedFence };
        if (intentTaken || intentExpired) fenceWrite.addIntent = null;
      }
      if (updatedFence !== null) {
        const curEntries = updatedFence.entries || [];
        if (curEntries.length !== prevFenceEntries.length || !curEntries.every((e, i) => e === prevFenceEntries[i])) {
          fenceEntriesChanged = true;
        }
      }
    }
  } else if (intentExpired) {
    fenceWrite = { addIntent: null };
  }

  if (fenceWrite) {
    try {
      await setCfg(fenceWrite);
    } catch (_e) {
      // The read is still the one to publish when the save itself failed.
    }
    if (!still()) return;
  } else if (!still()) {
    return;
  }

  if (fenceWrite) {
    port.fence = nextFence;
    if (intentTaken || intentExpired) port.addIntent = null;
    if (fenceEnded) {
      port.excludedHosts = nextExcluded;
      if (typeof port.excludedGen === "number") port.excludedGen += 1;
    } else {
      port.notify();
    }
  }

  const patternsChanged = !same;
  if (patternsChanged) {
    port.livePatterns = applied;
    port.broadGrant = H.broadLive(applied);
  }

  // The lease goes out before registration. A stalled register must not leave
  // the previous, closed lease in place.
  if (patternsChanged || fenceEnded || fenceEntriesChanged) {
    port.notify();
  }
  await pruneOrphanSiteErrors();
  if (!still()) return;
  await syncSiteRegistrations({ grantFanout: options.grantFanout === true });
  if (!still()) return;
  if (patternsChanged || fenceEnded || fenceEntriesChanged) {
    refreshOpenTabs();
  }
}

function beginRead() {
  if (!port) return Promise.resolve();
  const serial = ++port.readSerial;
  let run;
  run = (async () => {
    let origins = null;
    try {
      const perms = await chrome.permissions.getAll();
      if (Array.isArray(perms?.origins)) origins = perms.origins;
    } catch (_e) {
      origins = null;
    }
    // A newer read replaces this one. Wait until that read has finished applying.
    const superseded = () => (latestRead === run ? undefined : latestRead);
    if (!port || serial !== port.readSerial) return superseded();
    if (!origins) {
      if (!port.snapshotSucceeded) port.permissionsUnavailable = true;
      return;
    }
    port.snapshotSucceeded = true;
    port.permissionsUnavailable = false;
    const liveSet = new Set(origins);
    for (const tomb of port.tombstones) {
      if (!liveSet.has(tomb)) port.tombstones.delete(tomb);
    }
    const tombstoneFiltered = port.tombstones.size > 0;
    const applied = origins.filter((p) => !port.tombstones.has(p));
    const grantFanout = !sameStringSet(applied, grantWatch.patterns);
    await applySnapshot(applied, tombstoneFiltered, { grantFanout, serial });
    if (!port || serial !== port.readSerial) return superseded();
    grantWatch.patterns = [...applied];
    await saveGrantWatch();
    if (!port || serial !== port.readSerial) return superseded();
    await reinjectOpenTabs();
    return applied;
  })();
  latestRead = run;
  return run;
}

function decideAgreementRules(safariKnown) {
  if (safariKnown === true) return Promise.resolve("safari");
  const getInfo = globalThis.browser?.runtime?.getBrowserInfo;
  if (typeof getInfo !== "function") return Promise.resolve("chrome");
  return new Promise((resolve) => {
    let settled = false;
    const finish = (rules) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(rules);
    };
    const timer = setTimeout(() => finish("chrome"), 2000);
    Promise.resolve().then(() => getInfo()).then((info) => {
      finish(info && info.name === "Firefox" ? "firefox" : "chrome");
    }, () => {
      finish("chrome");
    });
  });
}

async function doInit() {
  await chrome.alarms.create(ALARM_NAME, { periodInMinutes: 1 });

  const safari = globalThis.SolstoneSafariPort?.isSafari(chrome.runtime) === true;
  let safariClearedMismatch = false;
  let safariClearedFailed = false;
  if (safari) {
    const res = await checkSafariClearedStorage();
    if (res.mismatch) {
      safariClearedMismatch = true;
      if (!res.cleared) {
        safariClearedFailed = true;
      }
    }
  }

  const rulesPromise = decideAgreementRules(safari);

  let inst = await DB.get("meta", "inst");
  if (!inst) {
    const random = new Uint8Array(10);
    crypto.getRandomValues(random);
    const newInst = Uuid.uuidv7String(Uuid.uuidv7Bytes(Date.now(), random));
    await DB.put("meta", newInst, "inst");
    inst = newInst;
  }
  if (safari && !safariClearedFailed) {
    const mirror = await chrome.storage.local.get("inst");
    if (mirror.inst !== inst) await chrome.storage.local.set({ inst });
  }

  let consentVersion = (await DB.get("meta", "consentVersion")) || 0;
  const consentCurrent = globalThis.SolstoneCaptureGate.consentAccepted(consentVersion) === true;

  const rawStorage = await chrome.storage.local.get("cfg");
  const rawCfg = rawStorage.cfg;
  try {
    const watchStored = await chrome.storage.local.get("grantWatch");
    rememberGrantWatch(watchStored?.grantWatch);
  } catch (_e) {
    grantWatch = { patterns: [], injectedVersion: null };
  }

  let inMemoryFence = null;
  if (rawCfg?.siteGrant !== "live") {
    let getAllOrigins = null;
    let getAllThrew = false;
    try {
      const p = await chrome.permissions.getAll();
      if (Array.isArray(p?.origins)) {
        getAllOrigins = p.origins.filter((pattern) => !sessionTombstones.has(pattern));
      }
    } catch (_e) {
      getAllThrew = true;
    }

    let decidedStartup = "existing";
    let decidedSiteGrant = "live";
    let decidedFence = null;
    let decidedPaused = false;
    let decidedClearedNotice = false;

    if (!rawCfg && !consentCurrent) {
      if (!getAllThrew && getAllOrigins && getAllOrigins.length === 0) {
        decidedStartup = "fresh";
        decidedFence = null;
        decidedSiteGrant = "live";
      } else if (!getAllThrew && getAllOrigins && getAllOrigins.length > 0 && safari) {
        decidedStartup = "fresh";
        decidedFence = null;
        decidedSiteGrant = "live";
      } else if (!getAllThrew && getAllOrigins && getAllOrigins.length > 0 && !safari) {
        decidedStartup = "existing";
        decidedSiteGrant = "live";
        decidedFence = { entries: [], exact: [], exactKnown: true, siteWide: [], declined: [], answered: false, sawMore: false, cleanAt: null };
      } else {
        decidedStartup = "existing";
        decidedSiteGrant = "live";
        decidedFence = { entries: [], exact: [], exactKnown: true, siteWide: [], declined: [], answered: false, sawMore: false, cleanAt: null };
      }
    } else if (rawCfg && rawCfg.siteMode === "all" && rawCfg.allSitesConsent === 1 && consentCurrent && !getAllThrew && getAllOrigins && getAllOrigins.includes("*://*/*")) {
      decidedFence = null;
      decidedStartup = "existing";
      decidedSiteGrant = "live";
    } else if (rawCfg && rawCfg.siteMode === "all") {
      decidedFence = { entries: [], exact: [], exactKnown: true, siteWide: [], declined: [], answered: false, sawMore: false, cleanAt: null };
      decidedStartup = "existing";
      decidedSiteGrant = "live";
    } else {
      const entries = Array.isArray(rawCfg?.chosenOrigins)
        ? [...rawCfg.chosenOrigins]
        : (Array.isArray(rawCfg?.grantedOrigins) ? [...rawCfg.grantedOrigins] : []);
      const exactKnown = Array.isArray(rawCfg?.exactOnlyOrigins);
      const exact = exactKnown ? [...rawCfg.exactOnlyOrigins] : [];
      const siteWide = Array.isArray(rawCfg?.siteWideOrigins) ? [...rawCfg.siteWideOrigins] : [];
      const declined = Array.isArray(rawCfg?.declinedHosts) ? [...rawCfg.declinedHosts] : [];
      decidedFence = {
        entries,
        exact,
        exactKnown,
        siteWide,
        declined,
        answered: false,
        sawMore: false,
        cleanAt: null,
      };
      decidedStartup = "existing";
      decidedSiteGrant = "live";
    }

    const patchToPersist = {
      siteGrant: decidedSiteGrant,
      startup: decidedStartup,
      fence: decidedFence,
    };
    if (decidedPaused) patchToPersist.paused = true;
    if (decidedClearedNotice) patchToPersist.clearedNotice = true;
    if (decidedStartup === "existing") patchToPersist.firstRunAnswered = true;

    try {
      const mergedCfg = Object.assign({}, rawCfg || {}, patchToPersist);
      await chrome.storage.local.set({ cfg: formatCfg(mergedCfg) });
      inMemoryFence = decidedFence;
    } catch (_err) {
      if (decidedStartup === "fresh" || decidedStartup === "cleared" || decidedFence === null) {
        inMemoryFence = { entries: [], exact: [], exactKnown: true, siteWide: [], declined: [], answered: false, sawMore: false, cleanAt: null };
      } else {
        inMemoryFence = decidedFence;
      }
    }
  }

  const rules = await rulesPromise;
  if ((rules === "safari" || rules === "firefox") && !globalThis.SolstoneCaptureGate.consentAccepted(consentVersion)) {
    consentVersion = globalThis.SolstoneCaptureGate.CONSENT_VERSION;
    await DB.put("meta", consentVersion, "consentVersion");
  }

  const cfg = await getCfg();
  if (rawCfg?.siteGrant === "live" && (cfg.startup === "existing" || cfg.startup === "cleared") && cfg.firstRunAnswered !== true) {
    await setCfg({ firstRunAnswered: true });
    cfg.firstRunAnswered = true;
  }
  const everConnected = !!(await DB.get("meta", "everConnected"));
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
    const origGetStatus = port.getStatus.bind(port);
    port.getStatus = () => {
      const s = origGetStatus();
      if (port.permissionsUnavailable) s.permissionsUnavailable = true;
      return s;
    };
  } else {
    port.inst = inst;
    port.platform = platform;
    port.requestSnapshots = requestSnapshots;
  }

  port.persistCfg = setCfg;
  port.syncSiteRegistrations = syncSiteRegistrations;

  port.livePatterns = [];
  port.tombstones = sessionTombstones;
  port.readSerial = 0;
  port.faults = new Map();
  port.fence = inMemoryFence !== null ? inMemoryFence : (cfg.fence ?? null);
  port.addIntent = cfg.addIntent || null;
  port.broadGrant = H.broadLive(port.livePatterns);
  port.consentVersion = consentVersion;
  port.agreementRules = rules;
  port.firstRunAnswered = cfg.firstRunAnswered === true;
  port.lossNotice = lossNotice || null;
  port.everConnected = everConnected;
  port.paused = safariClearedFailed ? true : cfg.paused;
  port.clearedNotice = safariClearedFailed ? true : (cfg.paused === false ? false : !!cfg.clearedNotice);
  port.pauseWithApp = cfg.pauseWithApp !== false;
  port.excludedHosts = cfg.excludedHosts;
  port.appLeftOut = cfg.appLeftOut ? [...cfg.appLeftOut] : [];
  port.appLeftOutRaw = Array.isArray(cfg.appLeftOutRaw) ? [...cfg.appLeftOutRaw] : [];
  port.appLeftOutEpoch = cfg.appLeftOutEpoch ?? null;
  port.appLeftOutRev = cfg.appLeftOutRev ?? 0;
  port.truncationByOrigin = storedTruncation && typeof storedTruncation === "object" ? storedTruncation : {};
  port.registration = storedSiteErrors?.registration && typeof storedSiteErrors.registration === "object" ? storedSiteErrors.registration : {};
  port.enqueue = storedSiteErrors?.enqueue && typeof storedSiteErrors.enqueue === "object" ? storedSiteErrors.enqueue : {};
  port.siteErrors = { registration: { ...port.registration }, enqueue: { ...port.enqueue } };

  port.lossNotice = (await DB.get("meta", "lossNotice")) || null;
  const cap = await Outbox.getCapacityStatus();
  port.pressure = cap.pressure;
  port.connect();
  updateBadge();
  refreshOpenTabs();

  await beginRead();

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

chrome.runtime.onConnect.addListener((p) => {
  if (p.name === "status") {
    if (globalThis.SolstoneCopy?.MOBILE === true) tryAppNow();
    if (!Router.isExtensionPageSender(p.sender, chrome.runtime.id)) {
      try { p.disconnect(); } catch (_e) {}
      return;
    }
    statusPorts.add(p);
    beginRead().catch(() => {});
    ensureInit().then(() => {
      if (port && !port.livePort) port.connect();
      if (!port) return;
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
  if (msg?.kind === "hello" && globalThis.SolstoneCopy?.MOBILE === true) tryAppNow();
  ensureInit().then(() => {
    const deps = {
      port,
      setCfg,
      registerSite,
      unregisterSite,
      syncSiteRegistrations,
      broadcastPause,
      refreshOpenTabs,
      executeBrowserRead,
      broadcastLeaseUpdate,
      getBrowserIdentity,
      beginRead,
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
  if (alarm.name !== ALARM_NAME) return;
  let safariClear = null;
  if (globalThis.SolstoneSafariPort?.isSafari(chrome.runtime) === true && port) {
    if (safariWatch && safariWatch.phase === "detect" && Date.now() - safariWatch.startedAt >= SAFARI_CHECK_BOUND_MS) {
      safariWatch.abandoned = true;
      safariWatch = null;
    }
    if (!safariWatch) safariClear = beginSafariWatch();
    else safariClear = safariWatch.promise;
  }
  beginRead().catch(() => {});
  ensureInit().then(async () => {
    if (port) {
      await port.poll();
    }
  }).catch(() => {});
  return safariClear;
});

chrome.permissions.onRemoved.addListener(async (details) => {
  for (const pattern of details?.origins || []) sessionTombstones.add(pattern);
  if (!port) return;
  const currentApplied = (port.livePatterns || []).filter((pattern) => !sessionTombstones.has(pattern));
  await applySnapshot(currentApplied, true);
  await beginRead();
});

chrome.permissions.onAdded.addListener(() => {
  beginRead().catch(() => {});
});

function init() {
  return ensureInit();
}

chrome.runtime.onInstalled.addListener((details) => {
  if (details.reason === "install" && globalThis.SolstoneCopy?.MOBILE !== true) {
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

init();

globalThis.SolstoneBackground = {
  doInit,
  ensureInit,
  updateBadge,
  broadcastLeaseUpdate,
  registerSite,
  unregisterSite,
  syncSiteRegistrations,
  getCfg,
  setCfg,
  beginRead,
  applySnapshot,
  get port() { return port; },
};
