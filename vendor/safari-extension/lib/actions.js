// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  function heldShare(result) {
    return result?.result === "share_held" || result?.result === "question_every_site" || result?.result === "question_changed";
  }

  function shareFailure(result) {
    if (heldShare(result)) return "";
    if (result?.error || result?.ok === false) return result?.error || "storage_error";
    return "";
  }

  // Safari does not ask. A missing request is not a decline. Only a request
  // that resolves false is.
  async function requestEverySite(effects) {
    if (effects.brand === "safari" || typeof effects.requestPermission !== "function") return null;
    try {
      return await effects.requestPermission({ origins: ["*://*/*"] });
    } catch (_e) {
      return null;
    }
  }

  function announceShare(effects, sentence) {
    if (!sentence) return;
    if (typeof effects.showOk === "function") effects.showOk(sentence);
    else if (typeof effects.showActionMessage === "function") effects.showActionMessage(sentence);
  }

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
    if (action.id === "retry-all-sites") {
      const result = await cmd({ cmd: "retryAllSites" });
      if (result?.error || result?.ok === false) effects.showError(result?.error || "storage_error");
      await refresh();
      return true;
    }
    if (action.id === "share-every-site") {
      const requested = await requestEverySite(effects);
      if (requested === false) {
        await refresh();
        if (typeof effects.showDenied === "function") effects.showDenied(action);
        return true;
      }
      const result = await cmd({ cmd: "shareEverySite" });
      const failure = shareFailure(result);
      if (failure) effects.showError(failure);
      await refresh();
      if (!failure && !heldShare(result)) {
        announceShare(effects, globalThis.SolstoneCopy?.accessCopy(effects.brand).nowAllowed);
      }
      return true;
    }
    if (action.id === "share-them-too") {
      const result = await cmd({ cmd: "shareThemToo", shown: action.shown });
      const failure = shareFailure(result);
      if (failure) effects.showError(failure);
      await refresh();
      return true;
    }
    if (action.id === "keep-my-sites") {
      const result = await cmd({ cmd: "keepMySites" });
      if (result?.error || result?.ok === false) effects.showError(result?.error || "storage_error");
      await refresh();
      return true;
    }
    if (action.id === "remove-site") {
      const result = await cmd({ cmd: "removeGrantedOrigin", origin: action.origin });
      if (result?.error || result?.saved === false || result?.ok === false) effects.showError(result?.error || "storage_error");
      await refresh();
      return result;
    }
    if (action.id === "exclude-site" || action.id === "include-site" || action.id === "leave-out") {
      const result = await cmd({ cmd: "setLeftOut", host: action.host || action.origin, out: action.id !== "include-site" });
      if (result?.error || result?.ok === false) effects.showError(result.error || "storage_error");
      await refresh();
      return true;
    }
    return false;
  }

  globalThis.SolstoneActions = { run };
})();
