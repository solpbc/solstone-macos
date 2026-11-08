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

    const H = globalThis.SolstoneHosts;
    const Copy = globalThis.SolstoneCopy;

    const isEverySite = !state.fence && H?.everySiteLive?.(state.livePatterns) === true;

    let entriesForRows = [];
    if (state.fence) {
      entriesForRows = state.fence.entries || [];
    } else if (!isEverySite) {
      if (Array.isArray(state.livePatterns)) {
        const seen = new Set();
        for (const p of state.livePatterns) {
          if (H.isBroadPattern(p)) continue;
          const row = H.grantRowOrigin ? H.grantRowOrigin(p) : null;
          if (row && !seen.has(row)) {
            seen.add(row);
            entriesForRows.push(row);
          }
        }
      }
    }

    const siteRows = entriesForRows.map((entry) => {
      const host = entry.startsWith("http") && H?.displayOrigin
        ? H.displayOrigin(entry) : entry;
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

    // Determine if the current page is covered by an allowed site entry
    let pageSite = null;
    if (state.fence) {
      const fenceEntries = state.fence.entries || [];
      const fenceExact = state.fence.exact || [];
      const fenceSiteWide = state.fence.siteWide || [];
      pageSite = page.origin && H?.siteForOrigin
        ? H.siteForOrigin(fenceEntries, page.origin, fenceExact, fenceSiteWide)
        : (fenceEntries.includes(page.origin) ? page.origin : null);
    } else if (!isEverySite) {
      if (page.origin && Array.isArray(state.livePatterns)) {
        for (const p of state.livePatterns) {
          if (!H.isBroadPattern(p) && H.plainAllow(p, page.origin)) {
            pageSite = H.patternSiteHost(p) ? `https://${H.patternSiteHost(p)}` : page.origin;
            break;
          }
        }
      }
    }
    const isPageAllowed = !!pageSite;
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

    if (pageKind === "private" && pageWords) {
      pageState = pageWords.privateState;
      pageNote = pageWords.privateNote;
      siteAction = null;
    } else if (pageKind === "restricted" && pageWords) {
      pageState = pageWords.restrictedState;
      siteAction = null;
    } else if (isEverySite && pageKind !== "web" && pageWords) {
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
      const appCovers = (state.appLeftOut || []).some((s2) => H.hostCovers(s2, page.host));
      if ((appCovers || !isLocalLeftOut) && !state.leftOutCapable) {
        siteAction = null;
      } else {
        siteAction = { id: "include-site", site, label: includeLabel, disabled: false, primary: false };
      }
    } else if (isEverySite) {
      const site = H.siteHostname(page.host);
      const row = globalThis.SolstoneStatus.siteRow(page.origin, state, extras);
      pageState = row.label;
      if (row.kind === "denied-by-browser" && pageWords) pageNote = pageWords.deniedNote;
      else if (pageWords && (state.broadGranted === true || state.broadGrant === true)) pageNote = pageWords.leaveOutNote(site);
      siteAction = { id: "exclude-site", site, label: "leave this site out", disabled: false, primary: true };
    } else if (!isPageAllowed) {
      pageState = "not added";
      pageNoteKey = Copy?.popupNoteKey ? Copy.popupNoteKey(state, page, "not-added") : "";
      const rawNotAddedNote = pageNoteKey && Copy ? Copy[pageNoteKey] : "";
      pageNote = typeof rawNotAddedNote === "function" ? rawNotAddedNote(state.brand) : (rawNotAddedNote || "");
      const canAdd = state.addSiteEligible === true && state.consentAccepted === true;
      siteAction = { id: "add-site", label: "add this site", disabled: !canAdd, primary: true };
      if (pageKind === "web" && page.ok && Copy?.MOBILE !== true) {
        siteSecondary = { id: "leave-out", label: "leave this site out" };
      }
    } else {
      const pageRow = siteRows.find((r) => r.origin === pageSite) || (globalThis.SolstoneStatus
        ? globalThis.SolstoneStatus.siteRow(pageSite, state, extras)
        : { label: "" });
      pageState = pageRow.label;
      const siteName = H?.displayOrigin ? H.displayOrigin(pageSite) : pageSite;
      siteAction = { id: "remove-site", origin: pageSite, label: pageSite === page.origin ? "remove this site" : `remove ${siteName}`, disabled: false, primary: false };
    }

    if (state.permissionsUnavailable === true && siteAction?.id === "add-site") {
      if (pageState === "not added") {
        pageState = Copy.actionFailure("permissions_unavailable", state.brand);
      }
      siteAction = null;
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
      quiet: Copy?.MOBILE === true && ["no-sites", "on", "idle"].includes(derived.kind),
    }];

    const issues = Copy?.MOBILE === true ? attentionRows.filter((row) => row.kind !== "no-sites") : attentionRows;
    if (issues.length > 0) sections.push({ id: "siteIssues", rows: issues });

    if (state.fence && state.fence.sawMore && state.fence.answered !== true) {
      const leftOutHosts = Array.from(new Set([...(state.excludedHosts || []), ...(state.appLeftOut || [])]));
      const beyond = H?.beyondExample ? H.beyondExample(state.fence, state.livePatterns || [], leftOutHosts) : null;
      if (beyond) {
        const q = Copy?.fenceQuestion ? Copy.fenceQuestion(state.brand, beyond.kind, beyond.host) : null;
        if (q) {
          sections.push({
            id: "upgradeQuestion",
            kind: "upgrade-question",
            shown: beyond.shown,
            body: q.body,
            buttons: [
              {
                id: q.shareId,
                label: q.shareLabel,
                // Taking in more is never the visually preselected answer.
                primary: false,
              },
              {
                id: q.keepId || "keep-my-sites",
                label: q.keepLabel || "keep my sites",
                primary: false,
              },
            ],
            action: {
              id: q.shareId,
              label: q.shareLabel,
              primary: false,
            },
            secondaryAction: {
              id: q.keepId || "keep-my-sites",
              label: q.keepLabel || "keep my sites",
              primary: false,
            },
          });
        }
      }
    }

    let siteCount = 0;
    const excludedCount = (state.excludedHosts || []).length;
    if (state.fence) {
      siteCount = (state.fence.entries || []).length;
    } else if (isEverySite) {
      siteCount = 1;
    } else if (Array.isArray(state.livePatterns)) {
      const rows = new Set();
      for (const pattern of state.livePatterns) {
        if (H.isBroadPattern(pattern)) continue;
        const row = H.grantRowOrigin ? H.grantRowOrigin(pattern) : null;
        if (row) rows.add(row);
      }
      siteCount = rows.size;
    } else {
      siteCount = 0;
    }

    sections.push({
      id: "page",
      kind: pageKind,
      host: pageKind === "web" || pageKind === "private" ? page.host || "this page" : "this page",
      state: pageState,
      note: pageNote,
      pageNoteKey,
      siteAction,
      siteSecondary,
      pauseAction: (Copy?.MOBILE === true && !state.paused) || (!isEverySite && siteCount === 0 && !state.paused) ? null : {
        id: "set-paused",
        label: state.paused ? "resume" : "pause all",
        primary: !!state.paused,
      },
    });

    if (state.consentAccepted === true) {
      const line = Copy ? Copy.sharingSummary(isEverySite, siteCount, excludedCount) : `${siteCount} sites`;
      sections.push({ id: "siteCount", mode: isEverySite ? "all" : "selected", text: line });
    }
    sections.push({ id: "footer" });
    return sections;
  }

  async function grantSite(input, effects) {
    let origin;
    let host;
    let scheme = "https";
    try {
      if (input.startsWith("http://") || input.startsWith("https://")) {
        const u = new URL(input);
        origin = u.origin;
        host = u.hostname;
        scheme = u.protocol.replace(/:$/, "");
      } else {
        const u = new URL("https://" + input);
        origin = u.origin;
        host = u.hostname;
        scheme = "https";
      }
    } catch (_e) {
      return { ok: false, error: "invalid_origin" };
    }

    const H = globalThis.SolstoneHosts;
    const inHand = effects ? (effects.status || effects.state) : null;
    if (inHand && (inHand.consentAccepted !== true || inHand.addSiteEligible !== true)) {
      return { ok: false, denied: true, ineligible: true };
    }

    const pattern = H ? H.matchPatternFor(host) : `*://${host}/*`;
    if (inHand && inHand.fence !== null && inHand.fence !== undefined) {
      const livePatterns = inHand.livePatterns || [];
      if (H && H.grantLevel(host, livePatterns, false, scheme)) {
        return effects.cmd({ cmd: "addGrantedOrigin", origin });
      }
      try {
        effects.cmd({ cmd: "intendAddOrigin", origin });
      } catch (_e) {}
    }

    let granted = false;
    try {
      granted = await effects.requestPermission({
        origins: [pattern],
      });
    } catch (_error) {
      granted = false;
    }
    if (!granted) {
      try { effects.cmd({ cmd: "clearAddIntent", origin }); } catch (_e) {}
      return withBlockedBy({ ok: false, denied: true }, host, effects);
    }

    const freshState = await effects.cmd({ cmd: "getState" });
    if (!freshState || freshState.consentAccepted !== true) {
      try { effects.cmd({ cmd: "clearAddIntent", origin }); } catch (_e) {}
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

  async function addSite(host, effects) {
    if (effects.status?.consentAccepted !== true || effects.status?.addSiteEligible !== true) {
      return { ok: false, cancelled: true, ineligible: true };
    }
    return grantSite(host, effects);
  }

  globalThis.SolstonePopupView = { arrange, siteCountLine, grantSite, addSite };
})();
