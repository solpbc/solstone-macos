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
      let host = entry;
      try {
        if (entry.startsWith("http")) host = new URL(entry).hostname;
      } catch (_e) {}
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

    const isPageChosen = chosenOrigins.includes(page.origin);
    const pageWords = Copy ? Copy.pageCopy(state.brand) : null;

    let pageState;
    let pageNote = "";
    let pageKind = page.kind || (page.ok ? "web" : "");
    let siteAction;

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
    } else if (allSites) {
      const excluded = (state.excludedHosts || []).includes(page.host);
      const row = globalThis.SolstoneStatus.siteRow(page.origin, state, extras);
      pageState = row.label;
      if (row.kind === "denied-by-browser" && pageWords) pageNote = pageWords.deniedNote;
      else if (!excluded && pageWords && state.broadGranted === true) pageNote = pageWords.leaveOutNote(page.host);
      siteAction = { id: excluded ? "include-site" : "exclude-site", label: excluded ? "include this site" : "leave this site out", disabled: false, primary: false };
    } else if (!isPageChosen) {
      pageState = "not added";
      const canAdd = state.addSiteEligible === true && state.consentVersion === 1;
      siteAction = { id: "add-site", label: "add this site", disabled: !canAdd, primary: true };
    } else {
      const pageRow = siteRows.find((r) => r.origin === page.origin) || (globalThis.SolstoneStatus
        ? globalThis.SolstoneStatus.siteRow(page.origin, state, extras)
        : { label: "" });
      pageState = pageRow.label;
      siteAction = { id: "remove-site", label: "remove this site", disabled: false, primary: false };
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
    }];
    if (attentionRows.length > 0) sections.push({ id: "siteIssues", rows: attentionRows });
    sections.push({
      id: "page",
      kind: pageKind,
      host: pageKind === "web" || pageKind === "private" ? page.host || "this page" : "this page",
      state: pageState,
      note: pageNote,
      siteAction,
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
      return { ok: false, denied: true };
    }

    const freshState = await effects.cmd({ cmd: "getState" });
    if (!freshState || freshState.consentVersion !== 1 || freshState.addSiteEligible !== true) {
      try { effects.cmd({ cmd: "clearAddIntent" }); } catch (_e) {}
      return { ok: false, denied: true, ineligible: true };
    }

    return effects.cmd({ cmd: "addGrantedOrigin", origin });
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
    const confirmed = await effects.disclose(sheetHost(host));
    if (!confirmed) return { ok: false, cancelled: true };
    return grantSite(host, effects);
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
  async function grantChosenSites(origins, effects) {
    const H = globalThis.SolstoneHosts;
    const chosen = new Set(effects.status?.chosenOrigins || []);
    const patterns = [];
    for (const origin of origins || []) {
      if (!chosen.has(origin)) continue;
      try { patterns.push(H.matchPatternFor(new URL(origin).host)); } catch (_e) {}
    }
    if (effects.status?.siteMode === "all" || patterns.length === 0) return { ok: false, error: "wrong_site_mode" };
    let granted = false;
    try { granted = await effects.requestPermission({ origins: [...new Set(patterns)] }); } catch (_e) {}
    if (!granted) return { ok: false, denied: true };
    return effects.cmd({ cmd: "refreshSiteAccess" });
  }

  globalThis.SolstonePopupView = { arrange, siteCountLine, grantSite, addSite, grantAllSites, regrantAllSites, grantChosenSites };
})();
