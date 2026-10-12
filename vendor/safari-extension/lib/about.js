// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";

  const KEYS = ["protocol_version", "os", "os_version", "arch", "journal_line", "journal_current", "journal_seen_at_epoch_secs"];
  const clean = (value) => typeof value === "string" && !/[\u0000-\u001f\u007f]/.test(value);

  function decode(value) {
    if (!value || typeof value !== "object" || Array.isArray(value) ||
        Object.keys(value).length !== KEYS.length || !KEYS.every(key => Object.hasOwn(value, key)) ||
        value.protocol_version !== 1 || ![value.os, value.os_version, value.arch, value.journal_line].every(clean) ||
        typeof value.journal_current !== "boolean" ||
        !(value.journal_seen_at_epoch_secs === null || (Number.isSafeInteger(value.journal_seen_at_epoch_secs) && value.journal_seen_at_epoch_secs >= 0)) ||
        !/^journal .+$/.test(value.journal_line) || value.journal_line.length > 8192 || value.journal_line.includes(" \u00b7 last seen ") ||
        (value.journal_line === "journal unknown" && (value.journal_current || value.journal_seen_at_epoch_secs !== null))) return null;
    return Object.fromEntries(KEYS.map(key => [key, value[key]]));
  }

  function arch(value) {
    if (["aarch64", "ARM64", "arm64-v8a", "arm64"].includes(value)) return "arm64";
    if (["amd64", "x64", "AMD64", "x86_64"].includes(value)) return "x86_64";
    return value;
  }

  function age(seconds) {
    if (seconds < 60) return "just now";
    const [count, unit] = seconds < 3600 ? [Math.floor(seconds / 60), "minute"] :
      seconds < 86400 ? [Math.floor(seconds / 3600), "hour"] : [Math.floor(seconds / 86400), "day"];
    return `${count} ${unit}${count === 1 ? "" : "s"} ago`;
  }

  function block(version, value, now = Date.now() / 1000) {
    const facts = decode(value);
    let own = `solstone extension ${String(version).replace(/^v/, "")}`;
    if (facts?.os) own += ` \u00b7 ${facts.os}${facts.os_version ? " " + facts.os_version : ""}`;
    if (facts?.arch) own += ` \u00b7 ${arch(facts.arch)}`;
    let journal = facts?.journal_line || "journal unknown";
    if (facts && journal !== "journal unknown" && !facts.journal_current && facts.journal_seen_at_epoch_secs !== null) {
      journal += ` \u00b7 last seen ${age(Math.max(0, Math.floor(now - facts.journal_seen_at_epoch_secs)))}`;
    }
    return `${own}\n${journal}`;
  }

  globalThis.SolstoneAbout = { decode, block, arch };
})();
