// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const t = (...args) => globalThis.SolstoneI18n.t(...args);

  // The device the solstone app is on, named the way the owner would.
  const here = () => globalThis.SolstoneCopy?.PLACE || "this computer";
  // Safari on iPhone and iPad: the app answers while closed.
  const mobile = () => globalThis.SolstoneCopy?.MOBILE === true;

  const PREFIX_BY_MARK = {
    healthy: "icon",
    paused: "icon-paused-",
    attention: "icon-attention-",
    offline: "icon-offline-",
    error: "icon-error-",
    connecting: "icon-connecting-",
  };

  function derive(status, extras) {
    const C = globalThis.SolstoneCopy;
    extras = extras || {};

    let statusFailed = false;
    try { statusFailed = status?.ok === false; }
    catch (_err) { statusFailed = true; }
    if (!status || typeof status !== "object" || statusFailed) {
      return {
        kind: "unavailable",
        mark: "error",
        badge: "",
        headline: t("browser.status.unavailable"),
        sub: "",
        appPausedNote: "",
        reason: t("browser.status.unavailablereason"),
        action: { id: "open-settings", label: t("browser.labels.opensettings") },
        also: [],
        connecting: null,
      };
    }

    try {
      const brand = status.brand || "";
      const platform = status.platform || "";
      const bName = C ? C.browserName(brand) : t("browser.copy.browsername", {brand:"other"});
      const siteErrors = status.siteErrors || {};
      const registrations = status.registration || siteErrors.registration || {};
      const enqueueErrors = status.enqueue || siteErrors.enqueue || {};
      const hostCapture = status.hostCapture;
      const hostDelivery = status.hostDelivery;
      const hostFailure = status.hostFailure;
      const custody = status.custody;
      const lease = status.lease;
      const capturePermitted = status.capturePermitted === true;
      const paused = !!status.paused;
      const pressure = status.pressure || {};
      const updateCheck = status.updateCheck || "pending";
      const behind = status.behind;
      const connected = !!status.connected;
      const handshake = status.handshake;
      const everConnected = !!status.everConnected;
      const lossNotice = status.lossNotice;

      const isEverySite = !status.fence && globalThis.SolstoneHosts?.everySiteLive?.(status.livePatterns) === true;
      let siteCount = 0;
      if (status.fence) {
        siteCount = (status.fence.entries || []).length;
      } else if (isEverySite) {
        siteCount = 1;
      } else if (Array.isArray(status.livePatterns)) {
        siteCount = status.livePatterns.filter(p => !globalThis.SolstoneHosts?.isBroadPattern?.(p)).length;
      }

      const anyGrantedTabOpen = typeof extras.anyGrantedTabOpen === "boolean" ? extras.anyGrantedTabOpen :
        (typeof status.openTabs?.anyGrantedTabOpen === "boolean" ? status.openTabs.anyGrantedTabOpen : null);

      const items = [];

      // Layer 1: Version Skew
      if (behind === "extension") {
        let reason = t("browser.status.updatepending", { place: here(), browser: bName });
        let action = null;
        if (updateCheck === "pending") {
          reason = t("browser.status.updatechecking", { place: here(), browser: bName });
        } else if (updateCheck === "manual" && status.brand === "safari") {
          reason = t("browser.status.updatesafarimanual", { place: here() });
        } else if (updateCheck === "manual") {
          reason = t("browser.status.updatefirefoxmanual", { place: here() });
        } else if (updateCheck === "update-available") {
          reason = t("browser.status.updateready");
          action = { id: "update-now", label: t("browser.labels.updatenow") };
        }
        items.push({
          layer: 1,
          kind: "update-extension",
          mark: "attention",
          badge: "!",
          headline: t("browser.status.updateextension"),
          sub: t("browser.status.untilupdated"),
          reason,
          action,
          connecting: null,
        });
      } else if (behind === "app") {
        const reason = platform === "linux" ? "" : mobile() ? t("browser.status.updateapp", { place: here() })
          : t("browser.status.updateapp", { place: here() });
        items.push({
          layer: 1,
          kind: "update-app",
          mark: "attention",
          badge: "!",
          headline: t("browser.status.updateappheadline"),
          sub: t("browser.status.untilupdated"),
          reason,
          action: null,
          connecting: null,
        });
      }

      // Layer 2: Transport & Host Reachability
      // A background that hasn't tried the app yet has heard nothing either way.
      const untried = status.connectionGeneration === 0;
      const isHandshakeConnecting = untried || (connected && handshake === "pending") ||
        (hostCapture === "permitted" && !capturePermitted && custody?.full !== true &&
          (!lease || lease.freshnessMs === 0));

      if (isHandshakeConnecting) {
        items.push({
          layer: 2,
          kind: "connecting",
          mark: "connecting",
          badge: "",
          headline: t("browser.status.connecting"),
          sub: "",
          reason: "",
          action: null,
          connecting: "handshake",
        });
      } else if (!connected || hostCapture == null || hostCapture === "unavailable") {
        let reason = "";
        let action = null;
        let mark = "offline";
        // The helper answering at all means the app is installed; in Safari the
        // extension comes inside the app. Either way the owner opens it, never
        // downloads it again.
        const appInstalled = status.appAnswered === true || brand === "safari";
        if (!everConnected && !appInstalled) {
          mark = "paused";
          reason = t("browser.status.cantreachgetapp", { place: here() });
          action = { id: "get-app", label: t("browser.status.getapp") };
        } else if (!everConnected || connected) {
          if (!everConnected) mark = "paused";
          reason = mobile() ? t("browser.status.cantreachanswering", { place: here() })
            : t("browser.status.cantreachanswering", { place: here() });
        } else if (platform !== "linux") {
          reason = mobile() ? t("browser.status.cantreachanswering", { place: here() })
            : t("browser.status.cantreachreopen", { place: here() });
        } else if (C) {
          reason = C.linuxCantReachAppReason();
        }
        items.push({
          layer: 2,
          kind: "cant-reach-app",
          mark,
          badge: "",
          headline: t("browser.status.cantreach"),
          sub: t("browser.status.untilanswers"),
          reason,
          action,
          connecting: null,
        });
      }

      // Layer 3: App Mode & Consent
      if (hostCapture === "not_paired") {
        items.push({
          layer: 3,
          kind: "not-paired",
          mark: "paused",
          badge: "",
          headline: t("browser.status.notpairedheadline"),
          sub: t("browser.status.untilpaired"),
          reason: mobile() ? t("browser.status.notpaired", { place: here() })
            : t("browser.status.notpaired", { place: here() }),
          action: null,
          connecting: null,
        });
      }

      if (status.consentAccepted !== true) {
        items.push({
          layer: 3,
          kind: "consent-needed",
          mark: "paused",
          badge: "",
          headline: t("browser.status.finishsetup"),
          sub: t("browser.status.untilyoudo"),
          reason: t("browser.status.readthenchoose"),
          action: { id: "finish-setup", label: t("browser.status.finishsetup") },
          connecting: null,
        });
      }

      if (hostCapture === "paused") {
        items.push({
          layer: 3,
          kind: "app-paused",
          mark: "paused",
          badge: "",
          headline: t("browser.status.apppausedheadline", { surface: "desktop" }),
          sub: t("browser.status.nothingnew"),
          reason: t("browser.status.apppausedreason", { surface: "desktop" }),
          action: null,
          connecting: null,
        });
      }

      if (hostCapture === "intake_off" && (!hostFailure || hostFailure === "relay_unavailable" || hostFailure === "journal_rejected")) {
        const reason = platform === "linux" ? "" : t("browser.status.turnpageson");
        items.push({
          layer: 3,
          kind: "intake-off",
          mark: "paused",
          badge: "",
          headline: t("browser.status.pagesoff"),
          sub: t("browser.status.nothingnew"),
          reason,
          action: null,
          connecting: null,
        });
      }

      if (paused) {
        items.push({
          layer: 3,
          kind: "paused-here",
          mark: "paused",
          badge: "",
          headline: t("browser.status.pausedhere"),
          sub: t("browser.status.nothingfrombrowser"),
          reason: t("browser.status.pausedoesnthold"),
          action: null,
          connecting: null,
        });
      }

      if (status.sitePolicyPending) {
        items.push({ layer: 3, kind: "site-policy-pending", mark: "paused", badge: "", headline: t("browser.status.changingsites"),
          sub: t("browser.status.untilsaved"), reason: "", action: null, connecting: null });
      } else if (isEverySite && status.allSitesRegistration === "failed") {
        items.push({ layer: 3, kind: "all-sites-registration", mark: "attention", badge: "!", headline: t("browser.copy.couldntstart"),
          sub: t("browser.status.nothingfrombrowser"), reason: C.accessCopy(brand).failedBody,
          action: { id: "retry-all-sites", label: t("browser.copy.tryagain") }, connecting: null });
      } else if (!isEverySite && siteCount === 0) {
        items.push({
          layer: 3,
          kind: "no-sites",
          mark: "paused",
          badge: "",
          headline: t("browser.status.nosites"),
          sub: t("browser.status.untilyouadd"),
          reason: t("browser.status.openandadd"),
          action: null,
          connecting: null,
        });
      }

      // Layer 4: Custody Limits & Storage Pressure
      const isQueueFullStore = hostCapture === "intake_off" && hostFailure === "queue_full" && custody?.full !== false;
      const hasSpecificHold = hostCapture === "intake_off" &&
        ["unaccepted_lost", "local_io", "resource_exhausted", "age_policy"].includes(hostFailure);
      const isStoreFull = custody?.full === true && !hasSpecificHold;

      if (isStoreFull || isQueueFullStore) {
        items.push({
          layer: 4,
          kind: "app-store-full",
          mark: "offline",
          badge: "",
          headline: t("browser.status.noroom"),
          sub: t("browser.status.untilroom"),
          reason: mobile() ? t("browser.status.storefull", { place: here() }) : t("browser.status.storefull", { place: here() }),
          action: null,
          connecting: null,
        });
      }

      if (hostCapture === "intake_off" && hostFailure === "unaccepted_lost") {
        items.push({
          layer: 4,
          kind: "lost-and-held",
          mark: "attention",
          badge: "!",
          headline: t("browser.status.somecouldnt"),
          sub: t("browser.status.nothingrightnow"),
          reason: t("browser.status.lostbrowsers"),
          action: null,
          connecting: null,
        });
        if (custody?.full === true && !items.some(it => it.kind === "app-store-full")) {
          items.push({
            layer: 4,
            kind: "app-store-full",
            mark: "offline",
            badge: "",
            headline: t("browser.status.noroom"),
            sub: t("browser.status.untilroom"),
            reason: mobile() ? t("browser.status.storefull", { place: here() }) : t("browser.status.storefull", { place: here() }),
            action: null,
            connecting: null,
          });
        }
      } else if (
        hostCapture === "intake_off" &&
        (hostFailure === "local_io" || hostFailure === "resource_exhausted" || hostFailure === "age_policy" || (hostFailure === "queue_full" && custody?.full === false))
      ) {
        items.push({
          layer: 4,
          kind: "intake-held",
          mark: "offline",
          badge: "",
          headline: mobile() && custody?.full === true ? t("browser.status.noroom") : t("browser.status.nothingrightnow"),
          sub: "",
          reason: mobile() && custody?.full === true ? t("browser.status.storefull", { place: here() })
            : t("browser.status.intakeheld", { place: here() }),
          action: null,
          connecting: null,
        });
        if (custody?.full === true && !items.some(it => it.kind === "app-store-full")) {
          items.push({
            layer: 4,
            kind: "app-store-full",
            mark: "offline",
            badge: "",
            headline: t("browser.status.noroom"),
            sub: t("browser.status.untilroom"),
            reason: mobile() ? t("browser.status.storefull", { place: here() }) : t("browser.status.storefull", { place: here() }),
            action: null,
            connecting: null,
          });
        }
      }

      if (pressure?.active && hostCapture === "permitted") {
        items.push({
          layer: 4,
          kind: "pressure-here",
          mark: "offline",
          badge: "",
          headline: t("browser.status.noroom"),
          sub: t("browser.status.untilroom"),
          reason: t("browser.status.pressure"),
          action: null,
          connecting: null,
        });
      }

      // Layer 5: Local Losses, Stale Custody & Site Errors
      if (lossNotice != null) {
        items.push({
          layer: 5,
          kind: "dropped",
          mark: "attention",
          badge: "!",
          headline: t("browser.status.somecouldnt"),
          sub: "",
          reason: t("browser.status.lostthis"),
          action: { id: "dismiss-loss", label: t("browser.chrome.dismiss") },
          connecting: null,
        });
      }

      if (custody?.stale === true) {
        items.push({
          layer: 5,
          kind: "waiting-over-a-week",
          mark: "attention",
          badge: "!",
          headline: t("browser.status.waitedweekheadline"),
          sub: "",
          reason: mobile() ? t("browser.status.waitedweek", { place: here() }) : t("browser.status.waitedweek", { place: here() }),
          action: null,
          connecting: null,
        });
      }



      const registrationFailures = Object.entries(registrations).filter(([, value]) => value === "failed");
      const enqueueFailureEntries = Object.entries(enqueueErrors);
      const hasSiteErrors = registrationFailures.length > 0 || enqueueFailureEntries.length > 0;
      if (hasSiteErrors) {
        const siteErrorCount = new Set([...registrationFailures, ...enqueueFailureEntries].map(([origin]) => origin)).size;
        const headline = t("browser.status.sitesneedattention", {count:siteErrorCount});
        items.push({
          layer: 5,
          kind: "site-error",
          mark: "attention",
          badge: "!",
          headline,
          sub: "",
          reason: "",
          action: null,
          connecting: null,
        });
      }

      // Layer 6: Remote Delivery Failure
      if (hostDelivery === "failed") {
        items.push({
          layer: 6,
          kind: "delivery-failed",
          mark: "offline",
          badge: "",
          headline: t("browser.status.notreaching"),
          sub: t("browser.status.keptfornow", { place: here() }),
          reason: t("browser.status.keptfornowreason", { place: here() }),
          action: null,
          connecting: null,
        });
      }

      // Layer 7: Active Capture
      const effectiveGateOpen = hostCapture === "permitted" && capturePermitted && custody?.full !== true &&
        status.consentAccepted === true && !paused && !pressure?.active;

      const layers0to4Clear = !items.some((it) => it.layer >= 0 && it.layer <= 4);

      if (effectiveGateOpen && layers0to4Clear) {
        if (hostDelivery === "unknown" || hostDelivery == null) {
          items.push({
            layer: 7,
            kind: "connecting",
            mark: "connecting",
            badge: "",
            headline: t("browser.page.markerstate", {phase:"on"}),
            sub: t("browser.status.nowordyet"),
            reason: "",
            action: null,
            connecting: "delivery",
          });
        } else {
          let deliverySub = "";
          if (hostDelivery === "delivered") {
            deliverySub = hostFailure ? t("browser.status.lastpages") : t("browser.status.reaching");
          } else if (hostDelivery === "kept_locally") {
            deliverySub = t("browser.status.keptwaiting", { place: here() });
          } else if (hostDelivery === "idle") {
            deliverySub = t("browser.status.nothingwaiting");
          }

          if (anyGrantedTabOpen === false) {
            items.push({
              layer: 7,
              kind: "idle",
              mark: "healthy",
              badge: "",
              headline: t("browser.page.markerstate", {phase:"on"}),
              sub: deliverySub,
              reason: isEverySite ? t("browser.status.idlereason", { mode: "all" }) : t("browser.status.idlereason", { mode: "selected" }),
              action: null,
              connecting: null,
            });
          } else {
            items.push({
              layer: 7,
              kind: "on",
              mark: "healthy",
              badge: "",
              headline: t("browser.page.markerstate", {phase:"on"}),
              sub: deliverySub,
              reason: "",
              action: null,
              connecting: null,
            });
          }
        }
      }

      const winner = items[0] || {
        layer: 0,
        kind: "unavailable",
        mark: "error",
        badge: "",
        headline: t("browser.status.unavailable"),
        sub: "",
        reason: t("browser.status.unavailablereason"),
        action: { id: "open-settings", label: t("browser.labels.opensettings") },
        connecting: null,
      };

      const also = items
        .filter((it) => it !== winner && it.kind !== "on" && it.kind !== "idle")
        .map((it) => ({ kind: it.kind, headline: it.headline, action: it.action }));

      const isWinnerOnOrIdleOrDeliveryConnecting = winner.kind === "on" || winner.kind === "idle" ||
        (winner.kind === "connecting" && winner.connecting === "delivery");
      const appPausedNote = (status.appReportedPaused === true && isWinnerOnOrIdleOrDeliveryConnecting)
        ? t("browser.status.apppausednote", { place: here() })
        : "";

      return {
        kind: winner.kind,
        mark: winner.mark,
        badge: winner.badge,
        headline: winner.headline,
        sub: winner.sub,
        appPausedNote,
        reason: winner.reason,
        action: winner.action,
        also,
        connecting: winner.connecting,
        items,
      };
    } catch (_err) {
      return {
        kind: "unavailable",
        mark: "error",
        badge: "",
        headline: t("browser.status.unavailable"),
        sub: "",
        appPausedNote: "",
        reason: t("browser.status.unavailablereason"),
        action: { id: "open-settings", label: t("browser.labels.opensettings") },
        also: [],
        connecting: null,
        items: [],
      };
    }
  }

  // When a surface says the app is reached, connecting or not reached. The
  // evidence is the app's own frames: derive() shows "on" only under a fresh
  // app lease. present() adds the timing every surface shares, so the toolbar,
  // popup and settings page never blink:
  // - not reached shows at once; reached shows at once, except that a drop
  //   from reached stays up for at least LINK.downDwellMs;
  // - connecting from nothing (a fresh surface) or from not reached keeps what
  //   is on screen for LINK.graceMs while the app answers, so a retry that
  //   fails at once never flashes connecting;
  // - resume() holds the last shown state for LINK.graceMs while a surface
  //   resubscribes after its background restarted;
  // - connecting for LINK.offlineAfterMs becomes not reached.
  // Its memo carries what to show (null keeps what is on screen) and when to
  // look again.
  const LINK = Object.freeze({ graceMs: 500, downDwellMs: 1000, offlineAfterMs: 30000 });
  const LINK_FIELDS = ["connected", "handshake", "connectionGeneration", "hostSettling", "hostCapture", "hostDelivery",
    "hostFailure", "custody", "lease", "capturePermitted", "addSiteEligible", "gate"];

  // "up" is everything that isn't the app connection's own connecting or not
  // reached, including a surface that can't read its status at all.
  function linkOf(derived) {
    if (derived.kind === "connecting" && derived.connecting === "handshake") return "connecting";
    if (derived.kind === "cant-reach-app") return "down";
    return "up";
  }

  // The status with nothing heard from the app. untried: the background hasn't
  // tried it yet (it restarted), rather than tried and failed.
  function withdrawn(status, untried) {
    const base = status && typeof status === "object" ? status : {};
    const generation = Number(base.connectionGeneration) || 0;
    return {
      ...base,
      connected: false,
      handshake: "closed",
      connectionGeneration: untried ? 0 : Math.max(1, generation),
      hostSettling: false,
      about: base.about ? { ...base.about, journal_current: false } : null,
      lease: null,
      hostCapture: null,
      hostDelivery: null,
      hostFailure: null,
      custody: null,
      capturePermitted: false,
      addSiteEligible: false,
    };
  }

  function holding(status, shown) {
    if (!shown) return null;
    const next = { ...status };
    for (const key of LINK_FIELDS) next[key] = shown[key];
    return next;
  }

  function present(memo, status, extras, now) {
    memo = memo || {};
    const heard = linkOf(derive(status, extras));
    const connectingSince = heard === "connecting" ? (memo.connectingSince ?? now) : null;
    const holdUntil = memo.holdUntil != null && now < memo.holdUntil ? memo.holdUntil : null;
    let shown = status;
    let link = heard;
    let wakeAt = null;
    if (heard === "connecting") {
      const offlineAt = connectingSince + LINK.offlineAfterMs;
      let holdEnd = holdUntil;
      if (memo.link == null || memo.link === "down") holdEnd = Math.max(holdEnd ?? 0, connectingSince + LINK.graceMs);
      if (now >= offlineAt) {
        shown = withdrawn(status, false);
        link = "down";
      } else if (holdEnd != null && now < holdEnd) {
        shown = holding(status, memo.status);
        link = memo.link ?? null;
        wakeAt = holdEnd;
      } else {
        wakeAt = offlineAt;
      }
    } else if (heard === "up" && memo.droppedAt != null && now < memo.droppedAt + LINK.downDwellMs) {
      shown = holding(status, memo.status);
      link = memo.link;
      wakeAt = memo.droppedAt + LINK.downDwellMs;
    }
    const droppedAt = link == null || link === "up" ? null : (memo.link === "up" ? now : (memo.droppedAt ?? null));
    return { status: shown, link, connectingSince, droppedAt, holdUntil, wakeAt };
  }

  function resume(memo, now) {
    return { ...(memo || {}), holdUntil: now + LINK.graceMs };
  }

  function iconState(status, extras) {
    const result = derive(status, extras);
    const prefix = PREFIX_BY_MARK[result.mark] || "icon-error-";
    let title = `${t("browser.brand.name")} \u00b7 ${t("browser.status.icontitle", {headline:result.headline})}`;
    const shouldAppendSub = result.kind === "delivery-failed" ||
      (result.kind === "connecting" && result.connecting === "delivery") ||
      result.kind === "on" || result.kind === "idle";
    if (shouldAppendSub && result.sub) {
      title += ` \u00b7 ${result.sub}`;
    }
    return { prefix, title, badge: result.badge || "" };
  }

  function siteRow(entry, status, extras) {
    const C = globalThis.SolstoneCopy;
    status = status || {};
    extras = extras || {};
    const bName = C ? C.browserName(status.brand) : t("browser.copy.browsername", {brand:"other"});
    const registrations = status.registration || status.siteErrors?.registration || {};
    const enqueueErrors = status.enqueue || status.siteErrors?.enqueue || {};
    const registration = registrations[entry];
    const enqueueError = enqueueErrors[entry];
    const tabs = status.openTabs || {};
    const openTabOrigins = Array.isArray(extras.openTabOrigins) ? extras.openTabOrigins :
      (Array.isArray(tabs.openOrigins) ? tabs.openOrigins : []);
    const tabsKnown = typeof extras.tabsKnown === "boolean" ? extras.tabsKnown : tabs.known === true;
    let host = "";
    try { host = new URL(entry).hostname; } catch (_e) {}

    const isEverySite = !status.fence && globalThis.SolstoneHosts?.everySiteLive?.(status.livePatterns) === true;

    const exactOnly = status.fence ? (status.fence.exact || []).includes(entry) : false;
    const siteWide = status.fence ? (status.fence.siteWide || []).includes(entry) : false;
    const isTabOpen = openTabOrigins.some((origin) => origin === entry ||
      (!isEverySite && (status.fence
        ? globalThis.SolstoneHosts?.originCoveredBy?.(entry, origin, exactOnly, siteWide)
        : (globalThis.SolstoneHosts?.hostCovers ? globalThis.SolstoneHosts.hostCovers(host, new URL(origin).hostname) : false))));
    const leaseOpen = !!status.lease && Number(status.lease.freshnessMs) > 0;
    const gateOpenFor = (granted) => granted && status.capturePermitted === true && leaseOpen && status.consentAccepted === true &&
      !status.paused && !status.pressure?.active && status.hostCapture === "permitted" && status.custody?.full !== true;
    const leftOutList = (status.excludedHosts || []).concat(status.appLeftOut || []);
    const coveringSite = host && leftOutList.find((site) => globalThis.SolstoneHosts?.hostCovers ? globalThis.SolstoneHosts.hostCovers(site, host) : false);
    if (coveringSite) {
      if (isEverySite) {
        return { kind: "excluded", label: t("browser.popup.leftout"), action: null };
      }
      const appCovers = (status.appLeftOut || []).some((site) => globalThis.SolstoneHosts?.hostCovers ? globalThis.SolstoneHosts.hostCovers(site, host) : false);
      let action = null;
      if (!(appCovers && !status.leftOutCapable)) {
        action = { id: "include-site", host: coveringSite, label: t("browser.status.stopleavinghostout", {value1: String(coveringSite)}) };
      }
      return { kind: "excluded", label: t("browser.popup.leftout"), action };
    }

    const fault = status.faults instanceof Map ? status.faults.get(entry) : status.faults?.[entry];
    if (fault === "denied") {
      return { kind: "denied-by-browser", label: t("browser.copy.denyingsite", { browser: bName }), action: null };
    }
    if (fault === "unknown") {
      return { kind: "unknown", label: t("browser.copy.unknownstate"), action: null };
    }

    if (registration === "failed" || enqueueError) {
      const stored = registration === "failed" ? registration : enqueueError;
      return { kind: "error", label: C ? C.classifyFailure(stored, status.brand) : String(stored), action: null };
    }

    if (isEverySite) {
      if (status.paused || status.hostCapture === "paused") return { kind: "paused", label: t("browser.page.markerstate", {phase:"paused"}), action: null };
      if (status.allSitesRegistration === "failed" || !gateOpenFor(globalThis.SolstoneHosts?.originGranted ? globalThis.SolstoneHosts.originGranted(status, entry) : true)) {
        return { kind: "not-taken-in", label: t("browser.popup.nottakenin"), action: null };
      }
      if (tabsKnown && isTabOpen) return { kind: "on-now", label: t("browser.labels.onnow"), action: null };
      return { kind: "included", label: t("browser.popup.included"), action: null };
    }

    const isPendingRemove = Array.isArray(status.pendingRemoveOrigins) && status.pendingRemoveOrigins.includes(entry);
    const isGranted = !isPendingRemove && (globalThis.SolstoneHosts?.originGranted
      ? globalThis.SolstoneHosts.originGranted(status, entry)
      : false);

    if (status.paused || status.hostCapture === "paused") {
      return {
        kind: "paused",
        label: t("browser.page.markerstate", {phase:"paused"}),
        action: null,
      };
    }

    const gateOpen = gateOpenFor(isGranted);
    if (!isGranted || (tabsKnown && isTabOpen && !gateOpen)) return { kind: "not-taken-in", label: t("browser.popup.nottakenin"), action: null };

    if (registration === "reload" && tabsKnown && isTabOpen) {
      return { kind: "reload-tab", label: t("browser.popup.reloadtab"), action: null };
    }
    if (tabsKnown && !isTabOpen) {
      return { kind: "added-idle", label: t("browser.popup.addedidle"), action: null };
    }
    if (tabsKnown && isTabOpen) {
      return {
        kind: "on-now",
        label: t("browser.labels.onnow"),
        action: null,
      };
    }

    return {
      kind: "added",
      label: t("browser.popup.added"),
      action: null,
    };
  }

  function projectOpenTabs(tabs, options = {}) {
    if (!Array.isArray(tabs)) return { known: false, openOrigins: null, anyGrantedTabOpen: null };
    const origins = new Set();
    for (const tab of tabs) {
      // Nothing is taken in from a private tab, so it never counts as open.
      if (tab?.incognito === true) continue;
      try {
        const url = new URL(tab?.url || "");
        if (url.protocol === "http:" || url.protocol === "https:") origins.add(url.origin);
      } catch (_e) {}
    }
    const openOrigins = Array.from(origins).sort();
    return { known: true, openOrigins, anyGrantedTabOpen: openOrigins.some((origin) =>
      globalThis.SolstoneHosts.originGranted({ ...options, sitePolicyPending: false }, origin)) };
  }

  function welcomeHold(status) {
    const derived = derive(status);
    const item = (derived.items || []).find((candidate) => candidate.layer === 1 || candidate.layer === 2 || candidate.layer === 4 ||
      candidate.kind === "not-paired" || candidate.kind === "intake-off");
    if (item) {
      const C = globalThis.SolstoneCopy;
      const appInstalled = status.appAnswered === true || status.brand === "safari";
      const bodies = {
        "cant-reach-app": appInstalled ? C?.STEP1_OPEN_APP_BODY : C?.STEP1_CANT_REACH_BODY,
        "not-paired": C?.STEP1_NOT_PAIRED_BODY,
        "intake-off": status.platform === "linux" ? item.reason : C?.STEP1_INTAKE_OFF_BODY,
      };
      return { met: false, heading: item.headline, body: bodies[item.kind] || item.reason || "", action: item.action || null };
    }
    // The app answering says nothing about whether the owner has confirmed the
    // pairing: a held pairing reports the same capture state as a confirmed one.
    const heading = status.hostCapture === "paused"
      ? t("browser.status.foundsolstoneapps")
      : t("browser.status.foundsolstoneapp");
    return { met: true, heading, body: "", action: null };
  }

  globalThis.SolstoneStatus = {
    derive,
    LINK,
    present,
    resume,
    withdrawn,
    iconState,
    siteRow,
    projectOpenTabs,
    welcomeHold,
  };
})();
