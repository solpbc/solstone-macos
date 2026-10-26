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
      runtimeId === table.dev?.firefox_id
    ) {
      return table.dev.host;
    }
    if (
      runtimeId === table.production?.chrome_id ||
      runtimeId === table.production?.edge_id ||
      runtimeId === table.production?.firefox_id ||
      (table.production?.safari_id && runtimeId === table.production.safari_id)
    ) {
      return table.production.host;
    }
    return null;
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
      this.updateCheck = "pending";
      this.paused = false;
      this.chosenOrigins = new Set();
      this.grantedOrigins = new Set();
      this.siteMode = "selected";
      this.excludedHosts = [];
      this.allSitesConsent = 0;
      this.broadGranted = false;
      this.allSitesRegistration = null;
      this.browserDeniedOrigins = new Set();
      this.sitePolicyPending = false;
      this.permissionEpoch = 0;
      this.ownerSites = { grantEpoch: 0, reservation: null, registration: {}, enqueue: {} };
      this.registration = {};
      this.enqueue = {};
      this.truncationByOrigin = {};
      this.truncationChain = Promise.resolve();
      this.siteErrors = { registration: {}, enqueue: {} };
      this.openTabs = { known: false, openOrigins: null, anyGrantedTabOpen: null };
      this.consentVersion = 0;
      this.showPageIndicator = false;
      this.capturePermitted = false;
      this.brand = resolveBrand();
      this.platform = options.platform || "";
      this.hostName = resolveHostName(this.runtimeId);
    }

    syncCaptureAuthority() {
      const signature = JSON.stringify([this.connectionToken, this.stateRevision, this.paused,
        this.consentVersion, [...this.chosenOrigins].sort(), [...this.grantedOrigins].sort(), this.pressure.active,
        this.siteMode, this.excludedHosts, this.allSitesConsent, this.broadGranted, this.sitePolicyPending, this.permissionEpoch,
        this.capturePermitted, this.hostCapture, this.lease]);
      if (signature !== this.captureSignature) {
        this.captureSignature = signature;
        this.captureEpoch++;
        Outbox.checkAuthorization?.();
      }
    }

    notify() {
      this.syncCaptureAuthority();
      Outbox.checkAuthorization?.();
      if (typeof this.onStatusChange === "function") {
        this.onStatusChange(this.getStatus());
      }
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
      if (this.ownerSites?.reservation && nowMs >= this.ownerSites.reservation.expiresAt) this.ownerSites.reservation = null;
      const chosenList = Array.from(this.chosenOrigins).sort();
      const grantedList = Array.from(this.grantedOrigins).sort();
      const inactiveOrigins = this.siteMode === "all" ? [] : chosenList.filter((o) => !this.grantedOrigins.has(o)).sort();
      const originGranted = !this.sitePolicyPending && (this.siteMode === "all"
        ? this.broadGranted && this.allSitesConsent === globalThis.SolstoneHosts.ALL_SITES_CONSENT_VERSION
        : this.grantedOrigins.size > 0);
      const fresh = (this.hostStateDeadline == null || nowMs < this.hostStateDeadline) &&
        (!this.lease || nowMs < this.lease.receivedAt + this.lease.freshnessMs);
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

      return {
        inst: this.inst,
        captureEpoch: this.captureEpoch,
        everConnected: !!this.everConnected,
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
        consentVersion: this.consentVersion,
        chosenOrigins: chosenList,
        grantedOrigins: grantedList,
        siteMode: this.siteMode,
        excludedHosts: [...this.excludedHosts],
        allSitesConsent: this.allSitesConsent,
        broadGranted: this.broadGranted,
        allSitesRegistration: this.allSitesRegistration,
        browserDeniedOrigins: [...this.browserDeniedOrigins],
        sitePolicyPending: this.sitePolicyPending,
        inactiveOrigins,
        openTabs: this.openTabs ? { ...this.openTabs, openOrigins: Array.isArray(this.openTabs.openOrigins) ? this.openTabs.openOrigins.slice() : null } : { known: false, openOrigins: null, anyGrantedTabOpen: null },
        showPageIndicator: !!this.showPageIndicator,
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
        } else if (this.handshake !== "ready") return;
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
        const revision = ++this.stateRevision;
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
        } catch (_e) { return; }
        if (!current()) return;
        this.hostCapture = val.capture;
        this.hostDelivery = val.delivery || null;
        this.hostFailure = val.failure || null;
        this.custody = val.custody ? { ...val.custody } : null;
        this.destinationGeneration = val.destination_generation || null;
        this.behind = null;
        this.capturePermitted = codec.captureIsPermitted(val);
        this.hostStateDeadline = val.freshness_ms > 0 ? nowMs + val.freshness_ms : null;
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
            this.lease = { token, generation: val.destination_generation, receivedAt: nowMs, freshnessMs: val.freshness_ms };
          }
          if (this.hostStateDeadline != null) this.schedule(expire, this.hostStateDeadline - this.now());
        }
        this.notify();
        if (typeof val.destination_generation === "string" && val.destination_generation.length > 0) {
          this.retryAfterState = false;
        }
        await this.drain();
        return;
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
      Outbox.markAllSnapshotRequired().catch(() => {});
      this.notify();
    }

    async poll(now) {
      const consts = getConsts();
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
            (this.lease && !codec.freshnessAuthorizesSkim(this.lease.receivedAt, this.lease.freshnessMs, monoNow))) {
          this.lease = null;
          this.hostCapture = null;
          this.hostDelivery = null;
          this.hostFailure = null;
          this.custody = null;
          this.capturePermitted = false;
          this.notify();
        }
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

  globalThis.SolstoneNativePort = SolstoneNativePortController;
})();
