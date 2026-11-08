// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const DB = globalThis.SolstoneDB;
  const Outbox = globalThis.SolstoneNativeOutbox;
  const Gate = globalThis.SolstoneCaptureGate;

  function getConsts() {
    const C = globalThis.SolstoneNativeBrowserConstants;
    if (!C) throw new Error("missing SolstoneNativeBrowserConstants");
    return C;
  }

  function resolveHostName(runtimeId) {
    const consts = getConsts();
    const table = consts.HOSTS_AND_IDS;
    if (!table || !runtimeId) return null;

    if (
      runtimeId === table.dev?.chrome_id ||
      runtimeId === table.dev?.edge_id ||
      runtimeId === table.dev?.firefox_id ||
      (table.dev?.safari_id && runtimeId === table.dev.safari_id) ||
      (table.dev?.safari_ios_id && runtimeId === table.dev.safari_ios_id)
    ) {
      return table.dev.host;
    }
    if (
      runtimeId === table.production?.chrome_id ||
      runtimeId === table.production?.edge_id ||
      runtimeId === table.production?.firefox_id ||
      (table.production?.safari_id && runtimeId === table.production.safari_id) ||
      (table.production?.safari_ios_id && runtimeId === table.production.safari_ios_id)
    ) {
      return table.production.host;
    }
    return null;
  }

  function arraysEqual(a, b) {
    if (a === b) return true;
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }

  function resolveBrand(runtime = typeof chrome !== "undefined" ? chrome.runtime : null) {
    // Safari's user agent resembles Chrome's, so the extension's own scheme decides.
    if (runtime && globalThis.SolstoneSafariPort?.isSafari(runtime)) return "safari";
    const ua = typeof navigator !== "undefined" && navigator.userAgent ? navigator.userAgent : "";
    if (ua.includes("Firefox/")) return "firefox";
    if (ua.includes("Edg/")) return "edge";
    return "chrome";
  }

  function defaultConnectNative() {
    if (typeof chrome === "undefined" || !chrome.runtime?.connectNative) return null;
    const runtime = chrome.runtime;
    if (globalThis.SolstoneSafariPort?.isSafari(runtime)) {
      return (host) => globalThis.SolstoneSafariPort.connect(runtime, host);
    }
    return runtime.connectNative.bind(runtime);
  }

  function mintConnectionToken() {
    const bytes = new Uint8Array(16);
    if (typeof crypto !== "undefined" && crypto.getRandomValues) {
      crypto.getRandomValues(bytes);
    }
    return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  }

  class SolstoneNativePortController {
    constructor(options = {}) {
      this.connectNative = options.connectNative || defaultConnectNative();
      this.now = options.now || (() => (typeof performance !== "undefined" && performance.now ? performance.now() : Date.now()));
      this.wallNow = options.wallNow || (() => Math.floor(Date.now()));
      this.schedule = options.schedule || ((fn, ms) => {
        const timer = setTimeout(fn, ms);
        if (timer && typeof timer.unref === "function") timer.unref();
        return timer;
      });
      this.clearSchedule = options.clearSchedule || ((id) => clearTimeout(id));
      this.requestUpdateCheck = options.requestUpdateCheck || (typeof chrome !== "undefined" && chrome.runtime?.requestUpdateCheck ? chrome.runtime.requestUpdateCheck.bind(chrome.runtime) : null);
      this.onStatusChange = options.onStatusChange || null;
      // Safari on iPhone and iPad: the handler's last answer stands until the next
      // exchange, and the handler still refuses a batch it wouldn't take.
      this.standingAuthority = options.standingAuthority ?? globalThis.SolstoneSafariPort?.ios === true;
      this.runtimeId = options.runtimeId || (typeof chrome !== "undefined" && chrome.runtime?.id ? chrome.runtime.id : "");
      this.manifestVersion = options.manifestVersion || "0.2.0";
      this.inst = options.inst !== undefined ? options.inst : null;
      this.requestSnapshots = options.requestSnapshots || null;

      this.retryDelayMs = options.retryDelayMs || 5000;
      this.inflightAckMs = options.inflightAckMs || 5000;

      this.captureEpoch = 0;
      this.captureSignature = null;
      this.hostStateDeadline = null;
      this.stateRevision = 0;
      this.settlingRevision = null;
      this.settleUntil = 0;
      this.settledWaiters = [];
      this.opEpoch = 0;
      this.connectionGeneration = 0;
      this.connectionToken = null;
      this.livePort = null;
      this.handshake = "closed"; // "closed" | "pending" | "ready"
      this.handshakeStartedAt = 0;
      this.destinationGeneration = null;
      this.about = null;
      this.aboutDestination = null;
      this.aboutDeadline = null;

      this.hostCapture = null;
      this.hostDelivery = null;
      this.hostFailure = null;
      this.custody = null;

      this.lease = null;
      this.behind = null;
      this.pressure = { active: false };
      this.siteRejection = null;
      this.lossNotice = null;
      this.drift = null;

      this.drainOwner = false;
      this.inflightBatch = null;
      this.retryAfterState = false;
      this.retryNotBefore = 0;

      this.everConnected = false;
      // The helper answered a hello this session, even if only to say the app
      // isn't running: the app is installed, so the owner is told to open it.
      this.appAnswered = false;
      this.updateCheck = "pending";
      this.paused = false;
      this.livePatterns = [];
      this.fence = null;
      this.broadGrant = false;
      this.faults = new Map();
      this.excludedHosts = [];
      this.appLeftOut = [];
      this.appLeftOutRaw = [];
      this.appLeftOutEpoch = null;
      this.appLeftOutRev = 0;
      this.sitePolicyPending = false;
      this.registration = {};
      this.enqueue = {};
      this.truncationByOrigin = {};
      this.truncationChain = Promise.resolve();
      this.siteErrors = { registration: {}, enqueue: {} };
      this.allSitesRegistration = null;
      this.pauseWithApp = true;
      this.startup = null;
      this.siteGrant = null;
      this.clearedNotice = false;
      this.openTabs = { known: false, openOrigins: null, anyGrantedTabOpen: null };
      this.consentVersion = 0;
      this.pauseWithApp = true;
      this.siteWideOrigins = [];
      this.pendingRemoveOrigins = [];
      this.offeredOrigins = [];
      this.declinedHosts = [];
      this.declinedHostsKnown = false;
      this.appLeftOut = [];
      this.appLeftOutRaw = [];
      this.appLeftOutEpoch = null;
      this.appLeftOutRev = null;
      this.leftOutCapable = false;
      this.desktop = null;
      this.adoptionNotices = [];
      this.includeHolds = new Set();
      this.ruleQueue = [];
      this.excludedGen = 0;
      this.leftOutTail = Promise.resolve();
      this.syncSiteRegistrations = options.syncSiteRegistrations || null;
      this.ruleId = 0;
      this.outstandingRule = null;
      this.migrationQueue = [];
      this.refusedHosts = new Set();
      this.migrationBlocked = false;
      this.lastRuleSentAt = null;
      this.migrationTimer = null;
      this.persistCfg = options.persistCfg || null;
      this.onLapseReservation = options.onLapseReservation || null;
      this.lastCaptureMessage = null;
      this.capturePermitted = false;
      this.brand = resolveBrand();
      this.platform = options.platform || "";
      this.hostName = resolveHostName(this.runtimeId);
    }

    syncCaptureAuthority() {
      const signature = JSON.stringify([
        this.connectionToken,
        this.stateRevision,
        this.paused,
        this.consentVersion,
        this.pressure?.active,
        this.capturePermitted,
        this.hostCapture,
        this.lease,
        this.sitePolicyPending,
        this.livePatterns ? [...this.livePatterns].sort() : [],
        this.fence ? {
          entries: [...(this.fence.entries || [])].sort(),
          exact: [...(this.fence.exact || [])].sort(),
          exactKnown: this.fence.exactKnown,
          siteWide: [...(this.fence.siteWide || [])].sort(),
          declined: [...(this.fence.declined || [])].sort(),
          answered: this.fence.answered,
          sawMore: this.fence.sawMore,
          cleanAt: this.fence.cleanAt,
        } : null,
        !!this.broadGrant,
        this.excludedHosts ? [...this.excludedHosts].sort() : [],
        this.appLeftOut ? [...this.appLeftOut].sort() : [],
      ]);
      if (signature !== this.captureSignature) {
        this.captureSignature = signature;
        this.captureEpoch++;
        Outbox.checkAuthorization?.();
      }
    }

    notify() {
      this.syncCaptureAuthority();
      Outbox.checkAuthorization?.();
      const status = this.getStatus();
      if (typeof this.onStatusChange === "function") {
        this.onStatusChange(status);
      }
      if (!status.hostSettling && this.settledWaiters.length > 0) {
        for (const resolve of this.settledWaiters.splice(0)) resolve(status);
      }
    }

    // What the owner's surfaces show. A surface opened between withdrawing and
    // re-granting authority for a host state waits for the settled state, as
    // the badge does; capture authority itself never waits.
    settledStatus() {
      const status = this.getStatus();
      if (!status.hostSettling) return Promise.resolve(status);
      return new Promise((resolve) => this.settledWaiters.push(resolve));
    }

    async persistSiteMaps() {
      const next = {
        registration: { ...(this.registration || {}) },
        enqueue: { ...(this.enqueue || {}) },
      };
      try {
        await DB.put("meta", next, "siteErrors");
        this.siteErrors = next;
        return true;
      } catch (_e) {
        return false;
      }
    }

    async setRegistration(origin, status) {
      const previous = { ...this.registration };
      if (status === "ready") delete this.registration[origin];
      else this.registration[origin] = status;
      const saved = await this.persistSiteMaps();
      if (!saved) this.registration = previous;
      else if (this.ownerSites) this.ownerSites.registration = this.registration;
      return saved;
    }

    async setEnqueueError(origin, code) {
      const previous = { ...this.enqueue };
      this.enqueue[origin] = code;
      const saved = await this.persistSiteMaps();
      if (!saved) this.enqueue = previous;
      else if (this.ownerSites) this.ownerSites.enqueue = this.enqueue;
      return saved;
    }

    // A removed or left-out site keeps no error behind: nothing would ever
    // clear it, and the owner would see an alarm with nothing to act on.
    async clearSiteErrorsWhere(matches) {
      const pick = (map) => Object.keys(map || {}).filter((origin) => { try { return matches(origin); } catch (_e) { return false; } });
      const regGone = pick(this.registration);
      const enqGone = pick(this.enqueue);
      if (regGone.length === 0 && enqGone.length === 0) return true;
      const previous = { registration: { ...this.registration }, enqueue: { ...this.enqueue } };
      for (const origin of regGone) delete this.registration[origin];
      for (const origin of enqGone) delete this.enqueue[origin];
      const saved = await this.persistSiteMaps();
      if (!saved) {
        this.registration = previous.registration;
        this.enqueue = previous.enqueue;
      } else if (this.ownerSites) {
        this.ownerSites.registration = this.registration;
        this.ownerSites.enqueue = this.enqueue;
      }
      this.notify();
      return saved;
    }

    async clearSiteError(kind, origin) {
      const target = kind === "registration" ? this.registration : this.enqueue;
      if (!Object.prototype.hasOwnProperty.call(target || {}, origin)) return true;
      const previous = { ...target };
      delete target[origin];
      const saved = await this.persistSiteMaps();
      if (!saved) {
        if (kind === "registration") this.registration = previous;
        else this.enqueue = previous;
      } else {
        if (this.ownerSites) this.ownerSites[kind] = target;
        this.notify();
      }
      return saved;
    }

    serializeTruncation(work) {
      const operation = this.truncationChain.catch(() => {}).then(work);
      this.truncationChain = operation;
      return operation;
    }

    normalizeTruncation(entry) {
      if (!entry) return { count: 0, sequence: 0, dismissedThrough: 0, newestId: "", documents: {} };
      if (Number.isSafeInteger(entry.sequence)) return entry;
      // Preserve every retained pre-repair identity, including stale UI actions.
      const dismissed = [...new Set(entry.dismissed || [])];
      if (entry.dismissThroughId && !dismissed.includes(entry.dismissThroughId)) dismissed.push(entry.dismissThroughId);
      const pending = [...new Set(entry.pending || [])].filter(id => !dismissed.includes(id));
      const count = Math.max(pending.length, Number.isSafeInteger(entry.count) ? entry.count : 0);
      const legacy = Object.fromEntries([...dismissed, ...pending].map((id, i) => [id, i + 1]));
      return { count, sequence: dismissed.length + count, dismissedThrough: dismissed.length,
        newestId: count ? `trunc-${dismissed.length + count}` : "", documents: {}, legacy };
    }

    // Counts and dismissal sequences are independent of outbox history.
    prepareTruncation(origin, id, { slot = id, documentId = id, omitted = true, legacyId = null } = {}) {
      const next = { ...this.truncationByOrigin };
      const current = this.normalizeTruncation(next[origin]);
      const last = current.documents?.[slot];
      if (!omitted && !last && !current.legacy) return null;
      if (last?.documentId === documentId && last.omitted === omitted && (!omitted || last.id === id)) return null;
      // A slot has one current document, even across origin changes.
      for (const [otherOrigin, value] of Object.entries(next)) {
        if (otherOrigin !== origin && Object.hasOwn(value.documents || {}, slot)) {
          const documents = { ...value.documents }; delete documents[slot];
          next[otherOrigin] = { ...value, documents };
        }
      }
      const wasLegacy = !last && legacyId && Object.hasOwn(current.legacy || {}, legacyId);
      const sequence = current.sequence + (omitted && !wasLegacy ? 1 : 0);
      if (!Number.isSafeInteger(sequence)) throw Object.assign(new Error("notice capacity"), { code: "storage_error" });
      next[origin] = { ...current, sequence,
        count: sequence - current.dismissedThrough,
        newestId: omitted ? `trunc-${sequence}` : current.newestId,
        documents: { ...current.documents, [slot]: { documentId, id, omitted } },
      };
      // Refuse more metadata rather than lose notices or retain page bodies.
      // The outbox transaction aborts too; the existing site-error exposes it.
      if (new TextEncoder().encode(JSON.stringify(next)).length > 1024 * 1024) {
        throw Object.assign(new Error("notice capacity"), { code: "storage_error" });
      }
      return next;
    }

    recordTruncation(origin, id, observation) {
      return this.serializeTruncation(async () => {
        try {
          const next = this.prepareTruncation(origin, id, observation);
          if (!next) return { ok: true, recorded: false };
          await DB.put("meta", next, "truncationByOrigin");
          this.truncationByOrigin = next;
          this.notify();
          return { ok: true, recorded: observation?.omitted !== false };
        } catch (_e) { return { ok: false, error: "storage_error" }; }
      });
    }

    enqueueObservedSkim(args, origin, observation) {
      args = { ...args, blocks: structuredClone(args.blocks) };
      return this.serializeTruncation(async () => {
        const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify([args.blocks, observation.omitted, observation.clips])));
        const id = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, "0")).join("");
        const legacyId = `${observation.documentId}:${globalThis.SolstoneBlocks.hashStr(JSON.stringify(args.blocks))}:${observation.omitted}:${observation.clips.join(",")}`;
        const next = this.prepareTruncation(origin, id, { ...observation, legacyId });
        const result = await Outbox.enqueueSkim({ ...args,
          writeObservation: next ? meta => meta.put(next, "truncationByOrigin") : null,
        });
        if (next) { this.truncationByOrigin = next; this.notify(); }
        return result;
      });
    }

    pruneTruncationDocuments(keepSlot) {
      return this.serializeTruncation(async () => {
        const next = { ...this.truncationByOrigin };
        let changed = false;
        for (const [origin, entry] of Object.entries(next)) {
          const documents = { ...entry.documents };
          for (const slot of Object.keys(documents)) if (!keepSlot(slot, documents[slot])) { delete documents[slot]; changed = true; }
          next[origin] = { ...entry, documents };
        }
        if (!changed) return true;
        try {
          await DB.put("meta", next, "truncationByOrigin");
          this.truncationByOrigin = next;
          return true;
        } catch (_e) { return false; }
      });
    }

    dismissTruncation(origin, id) {
      return this.serializeTruncation(async () => {
        const existing = this.truncationByOrigin[origin];
        if (!existing) return { ok: true, dismissed: false };
        const current = this.normalizeTruncation(existing);
        const match = /^trunc-([1-9][0-9]*)$/.exec(id);
        const through = match ? Number(match[1]) : current.legacy?.[id];
        if (!current || !Number.isSafeInteger(through) || through <= current.dismissedThrough || through > current.sequence) {
          return { ok: true, dismissed: false };
        }
        const next = { ...this.truncationByOrigin, [origin]: {
          ...current, dismissedThrough: through, count: current.sequence - through,
        } };
        try { await DB.put("meta", next, "truncationByOrigin"); }
        catch (_e) { return { ok: false, error: "storage_error" }; }
        this.truncationByOrigin = next;
        this.notify();
        return { ok: true, dismissed: true };
      });
    }

    getStatus() {
      this.syncCaptureAuthority();
      const nowMs = this.now();
      const originGranted = !this.sitePolicyPending && (this.fence !== null
        ? (this.fence.entries || []).length > 0 && (this.livePatterns || []).length > 0
        : (this.livePatterns || []).length > 0);
      const fresh = (this.hostStateDeadline == null || nowMs < this.hostStateDeadline) &&
        (!this.lease || this.lease.standing === true || nowMs < this.lease.receivedAt + this.lease.freshnessMs);
      const capturePermitted = fresh && this.capturePermitted === true;

      const addSiteDecision = Gate.computeDecision({
        lease: this.lease,
        paused: this.paused,
        consentVersion: this.consentVersion,
        originGranted: true,
        pressure: this.pressure,
        hostCapture: fresh ? this.hostCapture : null,
        capturePermitted,
        now: nowMs,
      });
      const addSiteEligible = addSiteDecision.open === true;

      const gate = Gate.computeDecision({
        lease: this.lease,
        paused: this.paused,
        consentVersion: this.consentVersion,
        originGranted,
        pressure: this.pressure,
        hostCapture: fresh ? this.hostCapture : null,
        capturePermitted,
        now: nowMs,
      });

      const faultsObj = this.faults instanceof Map
        ? Object.fromEntries(this.faults.entries())
        : { ...(this.faults || {}) };

      return {
        inst: this.inst,
        captureEpoch: this.captureEpoch,
        everConnected: !!this.everConnected,
        appAnswered: !!this.appAnswered,
        connected: this.livePort != null,
        handshake: this.handshake,
        brand: this.brand,
        platform: this.platform,
        hostCapture: fresh ? this.hostCapture : null,
        hostDelivery: fresh ? this.hostDelivery : null,
        hostFailure: fresh ? this.hostFailure : null,
        custody: fresh && this.custody ? { ...this.custody } : null,
        about: this.about ? { ...this.about, journal_current: this.about.journal_current &&
          this.livePort != null && this.handshake === "ready" && this.aboutDeadline != null &&
          nowMs < this.aboutDeadline && fresh } : null,
        destinationGeneration: this.destinationGeneration,
        lease: fresh && this.lease ? { ...this.lease } : null,
        connectionGeneration: this.connectionGeneration,
        connectionToken: this.connectionToken,
        hostSettling: this.settlingRevision != null && this.settlingRevision === this.stateRevision &&
          this.livePort != null && this.handshake === "ready" && nowMs < this.settleUntil,
        behind: this.behind,
        pressure: { ...this.pressure },
        truncationByOrigin: this.truncationByOrigin || {},
        siteErrors: {
          registration: { ...(this.registration || {}) },
          enqueue: { ...(this.enqueue || {}) },
        },
        registration: { ...(this.registration || {}) },
        enqueue: { ...(this.enqueue || {}) },
        siteRejection: null,
        lossNotice: this.lossNotice ? { ...this.lossNotice } : null,
        drift: this.drift ? { ...this.drift } : null,
        paused: !!this.paused,
        clearedNotice: !!this.clearedNotice,
        consentVersion: this.consentVersion,
        consentAccepted: Gate.consentAccepted(this.consentVersion) === true,
        agreementRules: this.agreementRules === "firefox" || this.agreementRules === "safari" ? this.agreementRules : "chrome",
        versionOneFence: this.agreementRules === "chrome" && this.consentVersion === 1,
        firstRunAnswered: this.firstRunAnswered === true,
        livePatterns: [...(this.livePatterns || [])],
        fence: this.fence ? JSON.parse(JSON.stringify(this.fence)) : null,
        broadGrant: !!this.broadGrant,
        faults: faultsObj,
        excludedHosts: [...(this.excludedHosts || [])],
        appLeftOut: [...(this.appLeftOut || [])],
        appLeftOutRaw: [...(this.appLeftOutRaw || [])],
        appLeftOutEpoch: this.appLeftOutEpoch ?? null,
        appLeftOutRev: this.appLeftOutRev ?? null,
        leftOutCapable: !!this.leftOutCapable,
        desktop: this.desktop ? { ...this.desktop } : null,
        allSitesRegistration: this.allSitesRegistration,
        sitePolicyPending: this.sitePolicyPending,
        openTabs: this.openTabs ? { ...this.openTabs, openOrigins: Array.isArray(this.openTabs.openOrigins) ? this.openTabs.openOrigins.slice() : null } : { known: false, openOrigins: null, anyGrantedTabOpen: null },
        pauseWithApp: this.pauseWithApp !== false,
        appReportedPaused: this.appReportedPaused() === true,
        updateCheck: this.updateCheck,
        capturePermitted,
        addSiteEligible,
        gate,
      };
    }

    connect() {
      // A new native connection never inherits a prior journal's facts.
      this.about = null;
      this.aboutDestination = null;
      this.aboutDeadline = null;
      this.desktop = null;
      this.leftOutCapable = false;
      this.includeHolds.clear();
      this.ruleQueue = [];
      this.opEpoch++;
      this.stateRevision++;
      this.hostStateDeadline = null;
      this.connectionGeneration++;
      const currentEpoch = this.opEpoch;
      const currentGen = this.connectionGeneration;
      const currentToken = mintConnectionToken();
      this.connectionToken = currentToken;

      const oldPort = this.livePort;
      this.livePort = null;
      this.handshake = "closed";
      this.lease = null;
      this.drainOwner = false;
      this.inflightBatch = null;

      this.hostCapture = null;
      this.hostDelivery = null;
      this.hostFailure = null;
      this.custody = null;
      this.capturePermitted = false;
      this.leftOutCapable = false;
      this.ruleId = 0;
      this.outstandingRule = null;
      this.migrationQueue = [];
      this.refusedHosts.clear();
      this.migrationBlocked = false;
      this.lastRuleSentAt = null;
      if (this.migrationTimer) {
        this.clearSchedule(this.migrationTimer);
        this.migrationTimer = null;
      }

      if (oldPort) {
        try {
          oldPort.disconnect();
        } catch (_e) {
          /* ignore */
        }
      }

      const host = resolveHostName(this.runtimeId);
      this.hostName = host;
      if (!this.inst || !host || typeof this.connectNative !== "function") {
        this.handshake = "closed";
        this.notify();
        return;
      }

      let portObj = null;
      try {
        portObj = this.connectNative(host);
      } catch (_err) {
        this.livePort = null;
        this.handshake = "closed";
        this.notify();
        return;
      }

      if (!portObj) {
        this.livePort = null;
        this.handshake = "closed";
        this.notify();
        return;
      }

      this.livePort = portObj;
      this.handshake = "pending";
      this.handshakeStartedAt = this.now();
      this.schedule(() => {
        if (this.opEpoch === currentEpoch && this.handshake === "pending") {
          this.handlePortDisconnect(currentEpoch, currentGen, currentToken);
          try { portObj.disconnect(); } catch (_e) {}
        }
      }, getConsts().HANDSHAKE_MS_BUDGET);

      const consts = getConsts();
      const helloMsg = {
        type: "hello",
        protocol: consts.WIRE_PROTOCOL,
        version: this.manifestVersion,
        brand: this.brand,
        inst: this.inst,
      };

      portObj.onMessage.addListener((msg) => {
        if (this.opEpoch !== currentEpoch || this.connectionGeneration !== currentGen || this.connectionToken !== currentToken) return;
        return this.handlePortMessage(msg, currentEpoch, currentGen, currentToken);
      });

      portObj.onDisconnect.addListener(() => {
        if (this.opEpoch !== currentEpoch || this.connectionGeneration !== currentGen || this.connectionToken !== currentToken) return;
        this.handlePortDisconnect(currentEpoch, currentGen, currentToken);
      });

      try {
        portObj.postMessage(helloMsg);
      } catch (_e) {
        this.handlePortDisconnect(currentEpoch, currentGen, currentToken);
      }
      this.notify();
    }

    async handlePortMessage(msg, epoch, gen, token) {
      if (this.opEpoch !== epoch || this.connectionGeneration !== gen || this.connectionToken !== token) return;
      const codec = globalThis.SolstoneNativeBrowser;
      const rawJson = typeof msg === "string" ? msg : JSON.stringify(msg);
      const decoded = codec.decode(rawJson, "host_to_extension");

      if (decoded.status !== "accept") {
        this.hostCapture = null;
        this.hostDelivery = null;
        this.hostFailure = null;
        this.custody = null;
        this.opEpoch++;
        this.handshake = "closed";
        this.lease = null;
        this.capturePermitted = false;
        if (this.livePort) {
          try { this.livePort.disconnect(); } catch (_e) {}
          this.livePort = null;
        }
        this.notify();
        await Outbox.markAllSnapshotRequired().catch(() => {});
        return;
      }

      const val = decoded.value;
      const nowMs = this.now();

      if (val.type === "hello_ack" || val.type === "state") {
        if (val.type === "hello_ack") {
          if (this.handshake !== "pending" || codec.handshakeExpired(this.handshakeStartedAt, nowMs, getConsts().HANDSHAKE_MS_BUDGET)) return;
          this.handshake = "ready";
          this.appAnswered = true;
        } else if (this.handshake !== "ready") return;
        return await this.applyCaptureMessage(val, epoch, gen, token);
      }

      if (val.type === "unsupported") {
        this.hostCapture = null;
        this.hostDelivery = null;
        this.hostFailure = null;
        this.custody = null;
        this.behind = val.behind || "extension";
        this.opEpoch++;
        this.handshake = "closed";
        this.lease = null;
        this.capturePermitted = false;
        if (this.livePort) {
          try { this.livePort.disconnect(); } catch (_e) {}
          this.livePort = null;
        }

        this.notify();
        if (val.behind === "extension") {
          if (typeof this.requestUpdateCheck === "function") {
            this.updateCheck = "pending";
            this.notify();
            const fenceEpoch = this.opEpoch;
            try {
              const checkPromise = this.requestUpdateCheck();
              if (checkPromise && typeof checkPromise.then === "function") {
                checkPromise.then(
                  (status) => {
                    if (this.opEpoch !== fenceEpoch) return;
                    const st = typeof status === "string" ? status : status?.status;
                    if (st === "no_update" || st === "no-update") this.updateCheck = "no-update";
                    else if (st === "throttled") this.updateCheck = "throttled";
                    else if (st === "update_available" || st === "update-available") this.updateCheck = "no-update";
                    else this.updateCheck = "failure";
                    this.notify();
                  },
                  () => {
                    if (this.opEpoch !== fenceEpoch) return;
                    this.updateCheck = "failure";
                    this.notify();
                  }
                );
              }
            } catch (_e) {
              this.updateCheck = "failure";
              this.notify();
            }
          } else {
            this.updateCheck = "manual";
            this.notify();
          }
        }
        return;
      }

      if (val.type === "accepted") {
        if (this.handshake !== "ready") return;
        if (this.inflightBatch && !this.inflightBatch.receipting && this.inflightBatch.batchId === val.batch_id &&
            val.destination_generation === this.inflightBatch.destinationGeneration && val.inst === this.inst) {
          const batchId = val.batch_id;
          const operation = this.inflightBatch;
          operation.receipting = true;
          const fence = { epoch: this.opEpoch, gen, token, port: this.livePort, destGen: this.destinationGeneration, stateRevision: this.stateRevision };

          try {
            if (val.result === "accepted" || val.result === "duplicate") {
              await Outbox.removeBatch(batchId);
              if (this.opEpoch !== fence.epoch || this.livePort !== fence.port) return;
              await this.refreshStorageStatus();
              if (this.opEpoch !== fence.epoch || this.livePort !== fence.port) return;
              if (this.inflightBatch === operation) {
                this.inflightBatch = null;
                this.drainOwner = false;
              }
              this.notify();
              await this.drain();
              return;
            } else if (val.result === "rejected") {
              const rejectRes = await Outbox.applyRejectedReceipt(batchId, val);
              if (this.opEpoch !== fence.epoch || this.livePort !== fence.port) return;
              await this.refreshStorageStatus();
              if (this.opEpoch !== fence.epoch || this.livePort !== fence.port) return;
              if (this.inflightBatch === operation) {
                this.inflightBatch = null;
                this.drainOwner = false;
              }
              if (rejectRes?.seq) {
                this.lossNotice = await DB.get("meta", "lossNotice");
              }
              if (val.class === "retryable" || val.reason === "expired_unaccepted") {
                this.retryNotBefore = this.now() + this.retryDelayMs;
                this.schedule(() => this.drain(), this.retryDelayMs);
              } else if (val.reason === "stale_generation") {
                if (this.stateRevision === fence.stateRevision) this.retryAfterState = true;
              } else {
                await this.drain();
              }
              this.notify();
              return;
            }
          } catch (_err) {
            if (this.inflightBatch !== operation) return;
            this.inflightBatch = null;
            this.drainOwner = false;
            this.retryNotBefore = this.now() + this.retryDelayMs;
            this.schedule(() => {
              if (this.opEpoch === fence.epoch && this.livePort === fence.port) this.drain();
            }, this.retryDelayMs);
            this.notify();
          }

        }
        return;
      }

      if (val.type === "boundary") {
        if (this.handshake !== "ready") return;
        const fence = { epoch: this.opEpoch, gen, token, port: this.livePort };
        await Outbox.markAllSnapshotRequired();
        if (this.opEpoch !== fence.epoch || this.connectionGeneration !== fence.gen || this.connectionToken !== fence.token || this.livePort !== fence.port) {
          return;
        }
        this.notify();
        if (typeof this.requestSnapshots === "function") {
          this.requestSnapshots();
        }
        return;
      }

      if (val.type === "bye") {
        this.opEpoch++;
        this.handshake = "closed";
        this.lease = null;
        this.capturePermitted = false;
        this.hostCapture = null;
        this.hostDelivery = null;
        this.hostFailure = null;
        this.custody = null;
        if (this.livePort) {
          try { this.livePort.disconnect(); } catch (_e) {}
          this.livePort = null;
        }
        this.notify();
        await Outbox.markAllSnapshotRequired().catch(() => {});
      }
    }

    async applyCaptureMessage(val, epoch, gen, token) {
      if (!val) return;
      this.lastCaptureMessage = val;
      const codec = globalThis.SolstoneNativeBrowser;
      const nowMs = this.now();

      if (val.type === "hello_ack" || val.type === "state") {
        this.leftOutCapable = Object.prototype.hasOwnProperty.call(val, "left_out");
      }

      if (Object.prototype.hasOwnProperty.call(val, "left_out")) {
        const res = globalThis.SolstoneLeftOut ? globalThis.SolstoneLeftOut.applyList({
          epoch: val.left_out_epoch,
          rev: val.left_out_rev,
          savedEpoch: this.appLeftOutEpoch,
          savedRev: this.appLeftOutRev,
          savedList: this.appLeftOut,
          savedRawList: this.appLeftOutRaw,
          localExcluded: this.excludedHosts,
          frameList: val.left_out,
          normalizeHost: (h) => (globalThis.SolstoneHosts ? globalThis.SolstoneHosts.excludedHostname(h) : h),
        }) : { list: val.left_out, rawList: val.left_out, epoch: val.left_out_epoch, rev: val.left_out_rev, localExcluded: this.excludedHosts, migrated: [] };

        const prevExcluded = this.excludedHosts;
        const prevAppLeftOut = this.appLeftOut;
        const prevRaw = this.appLeftOutRaw;
        const prevEpoch = this.appLeftOutEpoch;
        const prevRev = this.appLeftOutRev;

        const nextExcluded = res.localExcluded;
        const nextAppLeftOut = res.list;
        const nextRaw = res.rawList || val.left_out;
        const nextEpoch = res.epoch;
        const nextRev = res.rev;

        const excludedChanged = !arraysEqual(nextExcluded, prevExcluded);
        const appLeftOutChanged = !arraysEqual(nextAppLeftOut, prevAppLeftOut);
        const rawChanged = !arraysEqual(nextRaw, prevRaw);
        const epochChanged = nextEpoch !== prevEpoch;
        const revChanged = nextRev !== prevRev;

        this.appLeftOut = nextAppLeftOut;
        this.appLeftOutRaw = nextRaw;
        this.appLeftOutEpoch = nextEpoch;
        this.appLeftOutRev = nextRev;
        this.excludedHosts = nextExcluded;

        if (excludedChanged) {
          this.excludedGen++;
        }

        const changed = excludedChanged || appLeftOutChanged || rawChanged || epochChanged || revChanged;

        if (changed) {
          this.commitLeftOut({
            appLeftOut: this.appLeftOut,
            appLeftOutRaw: this.appLeftOutRaw,
            appLeftOutEpoch: this.appLeftOutEpoch,
            appLeftOutRev: this.appLeftOutRev,
            excludedHosts: this.excludedHosts,
          }).catch(() => {});
        }

        const effectiveChanged = excludedChanged || appLeftOutChanged;
        if (effectiveChanged && typeof this.syncSiteRegistrations === "function") {
          this.syncSiteRegistrations().catch(() => {});
        }
      }
      if (Object.prototype.hasOwnProperty.call(val, "desktop")) {
        if (val.desktop && typeof val.desktop === "object") {
          const knownSites = ["on", "needs_access", "not_checked"];
          const rawSites = val.desktop.sites;
          const sites = knownSites.includes(rawSites) ? rawSites : "not_checked";
          this.desktop = {
            screen: val.desktop.screen === true,
            activity: val.desktop.activity === true,
            sites,
          };
        }
      }
      if (Object.prototype.hasOwnProperty.call(val, "site_rule_ack")) {
        if (this.outstandingRule && globalThis.SolstoneLeftOut && Object.prototype.hasOwnProperty.call(val, "left_out")) {
          const ackStatus = globalThis.SolstoneLeftOut.noteAck({
            outstandingId: this.outstandingRule.id,
            ackId: val.site_rule_ack,
          });
          if (ackStatus === "settled") {
            const frameList = Array.isArray(val.left_out) ? val.left_out : [];
            const result = globalThis.SolstoneLeftOut.ruleResult({
              outstanding: this.outstandingRule,
              frameList,
            });
            if (result === "refused") {
              this.refusedHosts.add(this.outstandingRule.host);
            }
            const settledHost = this.outstandingRule.host;
            this.outstandingRule = null;
            const qIdx = this.migrationQueue.indexOf(settledHost);
            if (qIdx !== -1) this.migrationQueue.splice(qIdx, 1);
            this.pumpRuleQueue();
          }
        }
      }
      if (this.outstandingRule && globalThis.SolstoneLeftOut?.migrationBlocked(this.outstandingRule, nowMs)) {
        this.migrationBlocked = true;
      }

      // Clear the old destination before the first status or any await,
      // including a new destination with absent or malformed optional facts.
      if (val.type === "hello_ack" || this.aboutDestination !== (val.destination_generation || null)) {
        this.about = null;
        this.aboutDestination = val.destination_generation || null;
      }
      this.aboutDeadline = null;
      const about = globalThis.SolstoneAbout?.decode(val.about) || null;
      const deliveryContinues = this.destinationGeneration === val.destination_generation &&
        ["permitted", "paused", "intake_off"].includes(val.capture);
      // Surfaces keep showing the last settled state while this settles, but
      // only while that state is still earned: never past its own lease, and
      // never past the next renewal, so a transition that never ends can't
      // hold the owner's surfaces either.
      const stillSettling = this.settlingRevision != null && this.settlingRevision === this.stateRevision &&
        nowMs < this.settleUntil;
      if (!stillSettling) {
        this.settleUntil = Math.min(nowMs + getConsts().STATE_RENEWAL_MS_INTERVAL, this.hostStateDeadline ?? Infinity);
      }
      const revision = ++this.stateRevision;
      this.settlingRevision = revision;
      if (nowMs < this.settleUntil) {
        this.schedule(() => {
          if (this.settlingRevision === revision && this.stateRevision === revision) this.notify();
        }, this.settleUntil - nowMs);
      }
      const current = () => this.opEpoch === epoch && this.connectionGeneration === gen &&
        this.connectionToken === token && this.stateRevision === revision && this.handshake === "ready";
      // Withdraw old authority before any durable transition. A newer state
      // aborts this transition's still-active transaction through notify().
      this.lease = null;
      this.capturePermitted = false;
      this.hostCapture = null;
      this.hostDelivery = null;
      this.hostFailure = null;
      this.custody = null;
      if (!deliveryContinues) {
        this.destinationGeneration = null;
        this.drainOwner = false;
        this.inflightBatch = null;
      }
      this.notify();
      try {
        if (typeof val.destination_generation === "string" && val.destination_generation.length > 0) {
          const promoted = await Outbox.promoteHeldForGeneration(val.destination_generation, current);
          if (!current()) return;
          if (promoted?.count) {
            await this.refreshStorageStatus();
            if (!current()) return;
          }
        }
        if (!current()) return;
        if (val.capture !== "unavailable" && !this.everConnected) {
          await DB.put("meta", true, "everConnected");
          if (!current()) return;
          this.everConnected = true;
        }
      } catch (_e) {
        // The transition failed: the withdrawn state is the true one now.
        if (current()) {
          this.settlingRevision = null;
          this.notify();
        }
        return;
      }
      if (!current()) return;
      this.settlingRevision = null;

      const stateForCapture = this.readsThroughAppPause(val)
        ? { ...val, capture: "permitted" }
        : val;

      this.hostCapture = stateForCapture.capture;
      this.hostDelivery = val.delivery || null;
      this.hostFailure = val.failure || null;
      this.custody = val.custody ? { ...val.custody } : null;
      this.destinationGeneration = val.destination_generation || null;
      this.behind = null;
      this.capturePermitted = codec.captureIsPermitted(stateForCapture);
      this.hostStateDeadline = val.freshness_ms > 0 && !this.standingAuthority ? nowMs + val.freshness_ms : null;
      if (about) {
        this.about = about;
        this.aboutDeadline = this.hostStateDeadline;
      }
      const expire = () => {
        if (!current()) return;
        this.lease = null;
        this.capturePermitted = false;
        this.hostCapture = null;
        this.hostDelivery = null;
        this.hostFailure = null;
        this.custody = null;
        this.notify();
      };
      if (this.hostStateDeadline != null && this.now() >= this.hostStateDeadline) {
        expire();
      } else {
        if (this.capturePermitted) {
          this.lease = { token, generation: val.destination_generation, receivedAt: nowMs, freshnessMs: val.freshness_ms,
            ...(this.standingAuthority ? { standing: true } : {}) };
        }
        if (this.hostStateDeadline != null) this.schedule(expire, this.hostStateDeadline - this.now());
      }
      this.notify();
      if (typeof val.destination_generation === "string" && val.destination_generation.length > 0) {
        this.retryAfterState = false;
      }
      if (this.leftOutCapable) {
        const rawList = Array.isArray(this.appLeftOutRaw) ? this.appLeftOutRaw : [];
        for (const h of this.excludedHosts) {
          if (!rawList.includes(h) && !this.migrationQueue.includes(h) && !this.refusedHosts.has(h) && !this.includeHolds.has(h)) {
            this.migrationQueue.push(h);
          }
        }
        this.pumpRuleQueue();
      }
      await this.drain();
      return;
    }

    commitLeftOut(patch, setCfg = this.persistCfg) {
      this.leftOutTail = this.leftOutTail.catch(() => {}).then(async () => {
        const DB = globalThis.SolstoneDB;
        let genAtStart = this.excludedGen;

        if (patch.appLeftOut !== undefined && DB) await DB.put("meta", patch.appLeftOut, "appLeftOut");
        if (patch.appLeftOutRaw !== undefined && DB) await DB.put("meta", patch.appLeftOutRaw, "appLeftOutRaw");
        if (patch.appLeftOutEpoch !== undefined && DB) await DB.put("meta", patch.appLeftOutEpoch, "appLeftOutEpoch");
        if (patch.appLeftOutRev !== undefined && DB) await DB.put("meta", patch.appLeftOutRev, "appLeftOutRev");
        if (patch.excludedHosts !== undefined && DB) await DB.put("meta", patch.excludedHosts, "excludedHosts");

        const persist = typeof setCfg === "function" ? setCfg : this.persistCfg;
        if (typeof persist === "function") {
          await persist(patch);
        }

        while (this.excludedGen !== genAtStart) {
          genAtStart = this.excludedGen;
          if (DB) await DB.put("meta", [...this.excludedHosts], "excludedHosts");
          if (typeof persist === "function") {
            await persist({ excludedHosts: [...this.excludedHosts] });
          }
        }
      });
      return this.leftOutTail;
    }

    async commitInclude(host, setCfg = this.persistCfg) {
      this.includeHolds.add(host);
      try {
        await this.commitLeftOut({ excludedHosts: this.excludedHosts.filter((h) => h !== host) }, setCfg);
      } catch (err) {
        this.includeHolds.delete(host);
        throw err;
      }
      this.excludedHosts = this.excludedHosts.filter((h) => h !== host);
      this.excludedGen++;
      this.includeHost(host);
      await this.commitLeftOut({ excludedHosts: [...this.excludedHosts] }, setCfg);
      this.includeHolds.delete(host);
      if (typeof this.syncSiteRegistrations === "function") {
        this.syncSiteRegistrations().catch(() => {});
      }
      this.notify();
      return { ok: true, host, out: false };
    }

    includeHost(host) {
      const H = globalThis.SolstoneHosts;
      const norm = H?.excludedHostname ? H.excludedHostname(host) : host;
      const toInclude = new Set([host]);
      if (norm) toInclude.add(norm);
      for (const raw of this.appLeftOutRaw || []) {
        if (H?.excludedHostname && H.excludedHostname(raw) === norm) {
          toInclude.add(raw);
        }
      }
      for (const h of toInclude) {
        if (!this.ruleQueue.some((item) => item.host === h && item.out === false)) {
          this.ruleQueue.push({ host: h, out: false });
        }
      }
      this.pumpRuleQueue();
    }

    // Owner rules wait behind any rule already in flight, so an answer is
    // never matched to the wrong rule.
    queueSiteRule(host, out) {
      if (!this.ruleQueue.some((item) => item.host === host && item.out === !!out)) {
        this.ruleQueue.push({ host, out: !!out });
      }
      this.pumpRuleQueue();
    }

    pumpRuleQueue() {
      if (!this.leftOutCapable || !this.livePort || this.handshake !== "ready") return;
      if (this.outstandingRule) {
        // A rule unanswered for 10 s stops migration for this connection but
        // never blocks the owner's own later rules.
        if (this.now() - this.outstandingRule.sentAt < 10000) return;
        this.migrationBlocked = true;
        this.outstandingRule = null;
      }
      if (this.ruleQueue.length > 0) {
        const next = this.ruleQueue.shift();
        this.sendSiteRule(next.host, next.out);
        return;
      }
      this.pumpMigration();
    }

    sendSiteRule(host, out) {
      if (!this.leftOutCapable || !this.livePort || this.handshake !== "ready") return false;
      const id = ++this.ruleId;
      const msg = { type: "site_rule", id, host, out: !!out };
      this.outstandingRule = { id, host, out: !!out, sentAt: this.now() };
      this.lastRuleSentAt = this.now();
      try {
        this.livePort.postMessage(msg);
        return true;
      } catch (_e) {
        return false;
      }
    }

    pumpMigration() {
      if (!this.leftOutCapable || !this.livePort || this.handshake !== "ready" || this.migrationBlocked) return;
      const now = this.now();
      if (this.outstandingRule) {
        if (now - this.outstandingRule.sentAt >= 10000 || globalThis.SolstoneLeftOut?.migrationBlocked(this.outstandingRule, now)) {
          this.migrationBlocked = true;
        }
        return;
      }
      const H = globalThis.SolstoneHosts;
      while (this.migrationQueue.length > 0) {
        const candidate = this.migrationQueue[0];
        const valid = this.excludedHosts.includes(candidate) &&
          !this.includeHolds.has(candidate) &&
          !(this.appLeftOutRaw && this.appLeftOutRaw.includes(candidate)) &&
          (H?.excludedHostname ? H.excludedHostname(candidate) === candidate : true) &&
          !this.refusedHosts.has(candidate);
        if (!valid) {
          this.migrationQueue.shift();
          continue;
        }
        break;
      }
      if (this.migrationQueue.length === 0) return;
      const nextHost = globalThis.SolstoneLeftOut?.nextMigration({
        queue: this.migrationQueue,
        refused: this.refusedHosts,
        outstanding: this.outstandingRule,
        now,
        lastSentAt: this.lastRuleSentAt,
        blocked: this.migrationBlocked,
      });
      if (!nextHost) {
        if (!this.outstandingRule && !this.migrationBlocked && this.migrationQueue.length > 0) {
          const waitMs = Math.max(0, 1000 - (now - (this.lastRuleSentAt || 0)));
          if (!this.migrationTimer && waitMs > 0) {
            this.migrationTimer = this.schedule(() => {
              this.migrationTimer = null;
              this.pumpMigration();
            }, waitMs);
          }
        }
        return;
      }
      const isValid = this.excludedHosts.includes(nextHost) &&
        !this.includeHolds.has(nextHost) &&
        !(this.appLeftOutRaw && this.appLeftOutRaw.includes(nextHost)) &&
        (H?.excludedHostname ? H.excludedHostname(nextHost) === nextHost : true) &&
        !this.refusedHosts.has(nextHost);
      if (!isValid) {
        const idx = this.migrationQueue.indexOf(nextHost);
        if (idx !== -1) this.migrationQueue.splice(idx, 1);
        return;
      }
      this.sendSiteRule(nextHost, true);
    }

    // The setting reaches only the owner's own pause. An app that cannot say
    // so (no `away` fact) or reports nobody at the computer (locked, asleep)
    // closes reading whatever the setting says.
    readsThroughAppPause(val) {
      return this.pauseWithApp === false && val?.capture === "paused" && val.away === false;
    }

    appReportedPaused() {
      return this.readsThroughAppPause(this.lastCaptureMessage);
    }

    async reapplyLastCapture() {
      if (!this.lastCaptureMessage || this.handshake !== "ready") return;
      return await this.applyCaptureMessage(this.lastCaptureMessage, this.opEpoch, this.connectionGeneration, this.connectionToken);
    }

    handlePortDisconnect(epoch, gen, token) {
      if (this.opEpoch !== epoch || this.connectionGeneration !== gen || this.connectionToken !== token) return;
      this.opEpoch++;
      this.livePort = null;
      this.handshake = "closed";
      this.lease = null;
      this.capturePermitted = false;
      this.drainOwner = false;
      this.inflightBatch = null;
      this.hostCapture = null;
      this.hostDelivery = null;
      this.hostFailure = null;
      this.custody = null;
      this.desktop = null;
      this.leftOutCapable = false;
      this.includeHolds.clear();
      this.ruleQueue = [];
      Outbox.markAllSnapshotRequired().catch(() => {});
      this.notify();
    }

    async poll(now) {
      const consts = getConsts();
      this.pumpRuleQueue();
      const codec = globalThis.SolstoneNativeBrowser;
      const monoNow = Number(now !== undefined ? now : this.now());

      if (this.livePort && this.handshake === "pending") {
        if (codec.handshakeExpired(this.handshakeStartedAt, monoNow, consts.HANDSHAKE_MS_BUDGET)) {
          this.opEpoch++;
          if (this.livePort) {
            try { this.livePort.disconnect(); } catch (_e) {}
            this.livePort = null;
          }
          this.handshake = "closed";
          this.capturePermitted = false;
          this.notify();
        }
      }

      if (this.lease || this.hostStateDeadline != null) {
        if ((this.hostStateDeadline != null && monoNow >= this.hostStateDeadline) ||
            (this.lease && this.lease.standing !== true && !codec.freshnessAuthorizesSkim(this.lease.receivedAt, this.lease.freshnessMs, monoNow))) {
          this.lease = null;
          this.hostCapture = null;
          this.hostDelivery = null;
          this.hostFailure = null;
          this.custody = null;
          this.capturePermitted = false;
          this.notify();
        }
      }

      if (this.outstandingRule && globalThis.SolstoneLeftOut?.migrationBlocked(this.outstandingRule, monoNow)) {
        this.migrationBlocked = true;
      }
      if (this.leftOutCapable) {
        this.pumpMigration();
      }

      await this.refreshStorageStatus();
      this.notify();
      if (!this.livePort) {
        this.connect();
      } else {
        await this.drain();
      }
    }

    async refreshStorageStatus() {
      const cap = await Outbox.getCapacityStatus();
      const held = this.pressure.active && this.pressure.blockedAtBytes != null && cap.totalBytes >= this.pressure.blockedAtBytes;
      this.pressure = held ? this.pressure : cap.pressure;
      this.lossNotice = (await DB.get("meta", "lossNotice")) || null;
    }

    async dismissLoss(seq) {
      if (this.lossNotice && this.lossNotice.seq === seq) {
        this.lossNotice = null;
        this.notify();
      }
      return Outbox.dismissLoss(seq);
    }

    async drain() {
      if (this.retryAfterState) return;
      if (this.drainOwner || !this.livePort || this.handshake !== "ready") return;
      if (!this.destinationGeneration) return;
      if (!["permitted", "paused", "intake_off"].includes(this.hostCapture)) return;
      if (this.retryNotBefore && this.now() < this.retryNotBefore) return;

      const owner = {};
      this.drainOwner = owner;
      const fence = {
        epoch: this.opEpoch,
        gen: this.connectionGeneration,
        token: this.connectionToken,
        port: this.livePort,
        destGen: this.destinationGeneration,
      };
      const ownsDrain = () => this.opEpoch === fence.epoch &&
        this.connectionGeneration === fence.gen && this.connectionToken === fence.token &&
        this.livePort === fence.port && this.destinationGeneration === fence.destGen &&
        this.drainOwner === owner && this.handshake === "ready" &&
        ["permitted", "paused", "intake_off"].includes(this.hostCapture);

      try {
        const head = await Outbox.getHead();
        if (!ownsDrain()) {
          if (this.drainOwner === owner) this.drainOwner = false;
          return;
        }

        if (!head) {
          this.drainOwner = false;
          return;
        }

        const cursor = await DB.get("producer", `${head.inst}\n${head.ctx}`);
        if (!ownsDrain()) {
          if (this.drainOwner === owner) this.drainOwner = false;
          return;
        }

        const sendingDelta = !head.sendSnapshot && Array.isArray(head.records) && head.records.some(record => record.t === "delta");
        if (sendingDelta && head.destinationGeneration !== this.destinationGeneration &&
            (!cursor || cursor.generation !== this.destinationGeneration)) {
          this.drainOwner = false;
          return;
        }

        const wireBatch = Outbox.buildWireBatch(head, {
          destinationGeneration: this.destinationGeneration,
          queuedAtMs: this.wallNow(),
        });
        Outbox.validateWireBatch(wireBatch);

        this.inflightBatch = {
          batchId: head.batchId,
          seq: head.seq,
          destinationGeneration: this.destinationGeneration,
          wireBatch,
          postedAt: this.now(),
        };

        const operation = this.inflightBatch;
        this.livePort.postMessage(wireBatch);

        this.schedule(() => {
          if (this.inflightBatch === operation && this.drainOwner === owner && !operation.receipting) {
            this.inflightBatch = null;
            this.drainOwner = false;
            this.drain();
          }
        }, this.inflightAckMs);
      } catch (_err) {
        if (this.drainOwner === owner) {
          this.drainOwner = false;
          this.inflightBatch = null;
        }
      }
    }
  }

  SolstoneNativePortController.resolveHostName = resolveHostName;
  globalThis.SolstoneNativePort = SolstoneNativePortController;
})();
