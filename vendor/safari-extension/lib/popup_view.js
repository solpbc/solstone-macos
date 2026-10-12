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

    const siteRows = chosenOrigins.map((entry) => {
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
    const Copy = globalThis.SolstoneCopy;
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

    let pageState;
    let siteAction;

    if (!page.ok) {
      pageState = "this page can't be added";
      siteAction = { id: "add-site", label: "add this site", disabled: true, primary: true };
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
      host: page.host || "this page",
      state: pageState,
      siteAction,
      pauseAction: chosenOrigins.length === 0 && !state.paused ? null : {
        id: "set-paused",
        label: state.paused ? "resume" : "pause all",
        primary: !!state.paused,
      },
    });
    if (siteRows.length > 0) sections.push({ id: "siteCount", text: siteCountLine(siteRows) });
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

  async function addSite(host, effects) {
    if (effects.status?.consentVersion !== 1 || effects.status?.addSiteEligible !== true) {
      return { ok: false, cancelled: true, ineligible: true };
    }
    const confirmed = await effects.disclose(host);
    if (!confirmed) return { ok: false, cancelled: true };
    return grantSite(host, effects);
  }

  globalThis.SolstonePopupView = { arrange, siteCountLine, grantSite, addSite };
})();
