// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  async function run(action, effects) {
    if (!action || !effects) return false;
    const cmd = effects.cmd;
    const refresh = effects.refresh;
    if (action.id === "get-app") {
      effects.openApp();
      return true;
    }
    if (action.id === "open-settings" || action.id === "finish-setup") {
      effects.openSettings();
      return true;
    }
    if (action.id === "update-now") {
      const fresh = await cmd({ cmd: "getState" });
      if (fresh?.updateCheck === "update-available") effects.reload();
      else await refresh();
      return true;
    }
    if (action.id === "dismiss-loss") {
      await cmd({ cmd: "dismissLoss", seq: action.seq || effects.lossSeq?.() });
      await refresh();
      return true;
    }
    if (action.id === "dismiss-truncation") {
      const result = await cmd({ cmd: "dismissTruncation", origin: action.origin, bound: action.bound });
      if (result?.ok === false) effects.showError(result.error || "storage_error");
      else await refresh();
      return true;
    }
    if (action.id === "allow-again" || action.id === "allow-again-all") {
      // Giving the browser's access back to a site the owner already chose
      // needs no app or pause check, so it asks the browser straight away.
      const origins = action.id === "allow-again-all" ? (effects.inactiveOrigins?.() || []) : [action.origin];
      const result = effects.grantChosen ? await effects.grantChosen(origins) : await effects.grantSite(action.origin);
      if (result?.denied) effects.showDenied(action);
      else if (result?.error) effects.showError(result.error);
      await refresh();
      return true;
    }
    if (action.id === "remove-site") {
      const result = await cmd({ cmd: "removeGrantedOrigin", origin: action.origin });
      if (result?.error || result?.ok === false) effects.showError(result.error || "storage_error");
      await refresh();
      return true;
    }
    if (action.id === "allow-all-sites") {
      const result = await effects.allowAllSites();
      if (result?.denied) effects.showDenied(action);
      else if (result?.error) effects.showError(result.error);
      await refresh();
      return true;
    }
    if (action.id === "retry-all-sites") {
      const result = await cmd({ cmd: "refreshSiteAccess" });
      if (result?.error) effects.showError(result.error);
      await refresh();
      return true;
    }
    if (action.id === "exclude-site" || action.id === "include-site" || action.id === "leave-out") {
      const result = await cmd({ cmd: "setLeftOut", host: action.host || action.origin, out: action.id !== "include-site" });
      if (result?.error || result?.ok === false) effects.showError(result.error || "storage_error");
      await refresh();
      return true;
    }
    if (action.id === "offer-add") {
      const result = await cmd({ cmd: "adoptOffer", origin: action.origin });
      if (result?.error || result?.ok === false) effects.showError(result?.error || "storage_error");
      await refresh();
      return true;
    }
    if (action.id === "offer-decline") {
      const result = await cmd({ cmd: "declineOffer", origin: action.origin });
      if (result?.error || result?.ok === false) effects.showError(result?.error || "storage_error");
      await refresh();
      return true;
    }
    return false;
  }

  globalThis.SolstoneActions = { run };
})();
