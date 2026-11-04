// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function siteCountLine(rows) {
    rows = Array.isArray(rows) ? rows : [];
    if (rows.length === 0) return "";
    const noun = rows.length === 1 ? "site" : "sites";
    if (rows.every((row) => row.kind === "on-now" || row.kind === "on")) return `${rows.length} ${noun}, all on`;
    if (rows.every((row) => row.kind === "paused" || row.kind === "paused-by-browser")) return `${rows.length} ${noun}, all paused`;
    const on = rows.filter((row) => row.kind === "on-now" || row.kind === "on").length;
    if (on > 0) return `${rows.length} ${noun}, ${on} on`;
    return `${rows.length} ${noun}`;
  }

  function arrange(derived, state, page, extras) {
    state = state || {};
    page = page || {};
    extras = extras || {};
    derived = derived || (globalThis.SolstoneStatus ? globalThis.SolstoneStatus.derive(state, extras) : {});

    const chosenOrigins = Array.isArray(state.chosenOrigins)
      ? state.chosenOrigins
      : Array.isArray(state.grantedOrigins)
      ? state.grantedOrigins
      : Array.isArray(state.allowlist)
      ? state.allowlist
      : [];

    const allSites = state.siteMode === "all";
    const Copy = globalThis.SolstoneCopy;
    const siteRows = (allSites ? [] : chosenOrigins).map((entry) => {
      const host = entry.startsWith("http") && globalThis.SolstoneHosts?.displayOrigin
        ? globalThis.SolstoneHosts.displayOrigin(entry) : entry;
      const row = globalThis.SolstoneStatus
        ? globalThis.SolstoneStatus.siteRow(entry, state, extras)
        : { kind: "added-idle", label: "added", action: null };
      return { host, entry, origin: entry, kind: row.kind, label: row.label, action: row.action };
    });

    const attentionRows = [];
    if (Array.isArray(derived.also)) {
      for (const it of derived.also) {
        attentionRows.push({
          isAlso: true,
          kind: it.kind,
          headline: it.headline,
          label: it.headline,
          action: it.action,
        });
      }
    }
    const truncations = state.truncationByOrigin && typeof state.truncationByOrigin === "object"
      ? state.truncationByOrigin : {};
    for (const [origin, notice] of Object.entries(truncations)) {
      if (!notice || !(notice.count > 0)) continue;
      let host = origin;
      try { host = new URL(origin).hostname; } catch (_e) {}
      attentionRows.push({
        host, entry: origin, origin, kind: "truncated",
        label: Copy?.TRUNCATION_ATTENTION || "part of what you shared on this site was too long to keep",
        count: notice.count,
        action: { id: "dismiss-truncation", label: "dismiss", origin, bound: notice.newestId },
      });
    }
    for (const row of siteRows) {
      if (row.action != null || row.kind === "reload-tab" || row.kind === "error") {
        attentionRows.push({
          host: row.host,
          entry: row.entry,
          origin: row.origin,
          kind: row.kind,
          label: row.label,
          action: row.action ? Object.assign({ host: row.host, origin: row.origin }, row.action) : null,
        });
      }
    }

    // The chosen site this page falls under: bank.com for login.bank.com.
    const H = globalThis.SolstoneHosts;
    const pageSite = page.origin && H?.siteForOrigin
      ? H.siteForOrigin(chosenOrigins, page.origin, state.exactOnlyOrigins, state.siteWideOrigins)
      : (chosenOrigins.includes(page.origin) ? page.origin : null);
    const isPageChosen = !!pageSite;
    const pageWords = Copy ? Copy.pageCopy(state.brand) : null;

    let pageState;
    let pageNote = "";
    let pageNoteKey = "";
    let pageKind = page.kind || (page.ok ? "web" : "");
    let siteAction = null;
    let siteSecondary = null;

    const leftOutList = (state.excludedHosts || []).concat(state.appLeftOut || []);
    const coveringExcludedSite = page.host ? (leftOutList.find((s) => H?.hostCovers ? H.hostCovers(s, page.host) : false) || null) : null;
    const isEffectivelyLeftOut = !!coveringExcludedSite;
    const isLocalLeftOut = page.host ? ((state.excludedHosts || []).some((s) => H?.hostCovers ? H.hostCovers(s, page.host) : false)) : false;

    // A page the extension never reads gets its reason, not an add button that
    // can't work. An unseen page in all-sites mode is an honest "can't tell".
    if (pageKind === "private" && pageWords) {
      pageState = pageWords.privateState;
      pageNote = pageWords.privateNote;
      siteAction = null;
    } else if (pageKind === "restricted" && pageWords) {
      pageState = pageWords.restrictedState;
      siteAction = null;
    } else if (allSites && pageKind !== "web" && pageWords) {
      pageKind = "unknown";
      pageState = pageWords.unknownState;
      pageNote = pageWords.unknownNote;
      siteAction = null;
    } else if (!page.ok) {
      pageState = "this page can't be added";
      siteAction = { id: "add-site", label: "add this site", disabled: true, primary: true };
    } else if (isEffectivelyLeftOut) {
      pageState = "left out";
      pageNoteKey = Copy?.popupNoteKey ? Copy.popupNoteKey(state, page, "left-out") : "";
      const rawLeftOutNote = pageNoteKey && Copy ? Copy[pageNoteKey] : "";
      pageNote = typeof rawLeftOutNote === "function" ? rawLeftOutNote(state.brand) : (rawLeftOutNote || "");
      const site = coveringExcludedSite;
      const includeLabel = site === H.siteHostname(page.host) ? "stop leaving this site out" : `stop leaving ${site} out`;
      // Taking it off the list can't reach the app while it can't be told, so a
      // site its list also covers offers no such button (same rule as the site row).
      const appCovers = (state.appLeftOut || []).some((s2) => H.hostCovers(s2, page.host));
      if ((appCovers || !isLocalLeftOut) && !state.leftOutCapable) {
        siteAction = null;
      } else {
        siteAction = { id: "include-site", site, label: includeLabel, disabled: false, primary: false };
      }
    } else if (allSites) {
      const site = H.siteHostname(page.host);
      const row = globalThis.SolstoneStatus.siteRow(page.origin, state, extras);
      pageState = row.label;
      if (row.kind === "denied-by-browser" && pageWords) pageNote = pageWords.deniedNote;
      else if (pageWords && state.broadGranted === true) pageNote = pageWords.leaveOutNote(site);
      siteAction = { id: "exclude-site", site, label: "leave this site out", disabled: false, primary: false };
    } else if (!isPageChosen) {
      pageState = "not added";
      pageNoteKey = Copy?.popupNoteKey ? Copy.popupNoteKey(state, page, "not-added") : "";
      const rawNotAddedNote = pageNoteKey && Copy ? Copy[pageNoteKey] : "";
      pageNote = typeof rawNotAddedNote === "function" ? rawNotAddedNote(state.brand) : (rawNotAddedNote || "");
      const canAdd = state.addSiteEligible === true && state.consentVersion === 1;
      siteAction = { id: "add-site", label: "add this site", disabled: !canAdd, primary: true };
      if (pageKind === "web" && page.ok) {
        siteSecondary = { id: "leave-out", label: "leave this site out" };
      }
    } else {
      const pageRow = siteRows.find((r) => r.origin === pageSite) || (globalThis.SolstoneStatus
        ? globalThis.SolstoneStatus.siteRow(pageSite, state, extras)
        : { label: "" });
      pageState = pageRow.label;
      // Removing it removes the whole site the page belongs to, so say which.
      const siteName = H?.displayOrigin ? H.displayOrigin(pageSite) : pageSite;
      siteAction = { id: "remove-site", origin: pageSite, label: pageSite === page.origin ? "remove this site" : `remove ${siteName}`, disabled: false, primary: false };
    }

    const tone = derived.mark === "healthy"
      ? "ok"
      : derived.mark === "attention"
      ? "attention"
      : derived.mark === "error"
      ? "unavailable"
      : "calm";

    const sections = [{
      id: "verdict",
      tone,
      kind: derived.kind,
      mark: derived.mark,
      badge: derived.badge,
      headline: derived.headline,
      sub: derived.sub,
      reason: derived.reason,
      action: derived.action || null,
      appPausedNote: derived.appPausedNote || "",
    }];
    if (attentionRows.length > 0) sections.push({ id: "siteIssues", rows: attentionRows });
    sections.push({
      id: "page",
      kind: pageKind,
      host: pageKind === "web" || pageKind === "private" ? page.host || "this page" : "this page",
      state: pageState,
      note: pageNote,
      pageNoteKey,
      siteAction,
      siteSecondary,
      pauseAction: !allSites && chosenOrigins.length === 0 && !state.paused ? null : {
        id: "set-paused",
        label: state.paused ? "resume" : "pause all",
        primary: !!state.paused,
      },
    });
    // What is shared, always named, so the mode is visible without opening settings.
    if (state.consentVersion === 1) {
      const line = Copy ? Copy.sharingSummary(allSites ? "all" : "selected", (state.excludedHosts || []).length, siteCountLine(siteRows))
        : siteCountLine(siteRows);
      sections.push({ id: "siteCount", mode: allSites ? "all" : "selected", text: line });
    }
    sections.push({ id: "footer" });
    return sections;
  }

  async function grantSite(input, effects) {
    let origin;
    let host;
    try {
      if (input.startsWith("http://") || input.startsWith("https://")) {
        const u = new URL(input);
        origin = u.origin;
        host = u.host;
      } else {
        const u = new URL("https://" + input);
        origin = u.origin;
        host = u.host;
      }
    } catch (_e) {
      return { ok: false, error: "invalid_origin" };
    }

    const H = globalThis.SolstoneHosts;
    const pattern = H ? H.matchPatternFor(host) : `*://${host}/*`;

    const inHand = effects ? (effects.status || effects.state) : null;
    if (inHand && (inHand.consentVersion !== 1 || inHand.addSiteEligible !== true)) {
      return { ok: false, denied: true, ineligible: true };
    }

    try {
      effects.cmd({ cmd: "intendAddOrigin", origin });
    } catch (_e) {}

    let granted = false;
    try {
      granted = await effects.requestPermission({
        origins: [pattern],
      });
    } catch (_error) {
      granted = false;
    }
    if (!granted) {
      try { effects.cmd({ cmd: "clearAddIntent" }); } catch (_e) {}
      return withBlockedBy({ ok: false, denied: true }, host, effects);
    }

    const freshState = await effects.cmd({ cmd: "getState" });
    if (!freshState || freshState.consentVersion !== 1) {
      try { effects.cmd({ cmd: "clearAddIntent" }); } catch (_e) {}
      return { ok: false, denied: true, ineligible: true };
    }

    const added = await effects.cmd({ cmd: "addGrantedOrigin", origin });
    if (added && added.ok === false) {
      const blocked = await withBlockedBy({ ok: false, denied: true }, host, effects);
      if (blocked.blockedBy) return blocked;
    }
    return added;
  }

  // Safari keeps only the broadest grant, so while it allows a site under this
  // one it doesn't ask about this one, and the request grants nothing. The
  // failure names that site, unless this site's own grant is live after all.
  async function withBlockedBy(result, host, effects) {
    if (typeof effects?.getAllPermissions !== "function") return result;
    const H = globalThis.SolstoneHosts;
    if (!H) return result;
    let live;
    try {
      live = (await effects.getAllPermissions())?.origins;
    } catch (_e) {
      return result;
    }
    if (!Array.isArray(live)) return result;
    const h = H.matchHostFor(host);
    if (!h || live.includes(H.matchPatternFor(h))) return result;
    for (const pattern of live) {
      const site = H.patternSiteHost(pattern);
      if (site && site !== h && site.endsWith(`.${h}`)) return { ...result, blockedBy: site };
    }
    return result;
  }

  // The sheet names the site by host; a caller may hand in a full origin for the grant.
  function sheetHost(input) {
    if (!/^https?:\/\//i.test(input)) return input;
    try {
      return new URL(input).host;
    } catch (_e) {
      return input;
    }
  }

  async function addSite(host, effects) {
    if (effects.status?.consentVersion !== 1 || effects.status?.addSiteEligible !== true) {
      return { ok: false, cancelled: true, ineligible: true };
    }
    // The sheet calls confirm inside the owner's confirming click, so the
    // browser's prompt opens from that click. Firefox refuses a permission
    // request made after the click's handler has returned.
    const outcome = await effects.disclose(sheetHost(host), () => grantSite(host, effects));
    if (!outcome) return { ok: false, cancelled: true };
    return outcome;
  }

  async function grantAllSites(effects) {
    if (effects.status?.consentVersion !== 1) return { ok: false, error: "missing_consent" };
    // Request synchronously from the confirming owner gesture.
    effects.cmd({ cmd: "intendAllSites" });
    let granted = false;
    try { granted = await effects.requestPermission({ origins: ["*://*/*"] }); } catch (_e) {}
    if (!granted && effects.status.brand !== "safari") {
      await effects.cmd({ cmd: "clearAddIntent" });
      return { ok: false, denied: true };
    }
    return effects.cmd({ cmd: "setSiteMode", mode: "all", agreed: true });
  }

  // Asks again for a broad grant the owner already agreed to, without touching
  // the mode. The reservation keeps the grant through reconciliation if the
  // browser's prompt closes the popup before the answer arrives.
  async function regrantAllSites(effects) {
    const agreed = (s) => s?.siteMode === "all" && s?.allSitesConsent === globalThis.SolstoneHosts.ALL_SITES_CONSENT_VERSION;
    if (!agreed(effects.status)) return { ok: false, error: "wrong_site_mode" };
    effects.cmd({ cmd: "intendAllSites" });
    let granted = false;
    try { granted = await effects.requestPermission({ origins: ["*://*/*"] }); } catch (_e) {}
    await effects.cmd({ cmd: "clearAddIntent" });
    if (!granted) return { ok: false, denied: true };
    // The snapshot that offered this may be stale: if the owner left all sites
    // meanwhile, the broad grant goes straight back.
    const fresh = await effects.cmd({ cmd: "getState" });
    if (!agreed(fresh)) {
      try { await effects.removePermission?.({ origins: ["*://*/*"] }); } catch (_e) {}
      return { ok: false, error: "wrong_site_mode" };
    }
    return effects.cmd({ cmd: "refreshSiteAccess" });
  }

  // One browser prompt for the owner's own chosen sites that lost their grant,
  // such as after switching back from all sites. Only already-chosen origins are
  // asked for, so nothing new joins the list.
  // `widen` asks for each site's whole-site pattern: the settings bar for sites
  // that cover only their exact address. Allowing again restores what was there.
  async function grantChosenSites(origins, effects, options = {}) {
    const H = globalThis.SolstoneHosts;
    const chosen = new Set(effects.status?.chosenOrigins || []);
    const exactOnly = new Set(effects.status?.exactOnlyOrigins || []);
    const widen = options?.widen === true;
    const patterns = [];
    for (const origin of origins || []) {
      if (!chosen.has(origin)) continue;
      try {
        const host = new URL(origin).host;
        patterns.push(exactOnly.has(origin) && !widen ? H.exactPatternFor(host) : H.matchPatternFor(host));
      } catch (_e) {}
    }
    if (effects.status?.siteMode === "all" || patterns.length === 0) return { ok: false, error: "wrong_site_mode" };
    let granted = false;
    try { granted = await effects.requestPermission({ origins: [...new Set(patterns)] }); } catch (_e) {}
    if (!granted) return { ok: false, denied: true };
    return effects.cmd({ cmd: "refreshSiteAccess" });
  }

  globalThis.SolstonePopupView = { arrange, siteCountLine, grantSite, addSite, grantAllSites, regrantAllSites, grantChosenSites };
})();
