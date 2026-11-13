// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

(function () {
  "use strict";
  const t = (...args) => globalThis.SolstoneI18n.t(...args);

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
    if (seconds < 60) return t("browser.about.justnow");
    if (seconds < 3600) return t("browser.about.minutesago", {count:Math.floor(seconds / 60)});
    if (seconds < 86400) return t("browser.about.hoursago", {count:Math.floor(seconds / 3600)});
    return t("browser.about.daysago", {count:Math.floor(seconds / 86400)});
  }

  function block(version, value, now = Date.now() / 1000) {
    const facts = decode(value);
    let own = t("browser.about.extensionversion", {value1: String(version).replace(/^v/, "")});
    if (facts?.os) own += ` \u00b7 ${facts.os}${facts.os_version ? " " + facts.os_version : ""}`;
    if (facts?.arch) own += ` \u00b7 ${arch(facts.arch)}`;
    let journal = facts?.journal_line || t("browser.about.journalunknown");
    if (facts && facts.journal_line !== "journal unknown" && !facts.journal_current && facts.journal_seen_at_epoch_secs !== null) {
      journal += t("browser.about.lastseen", {value1: String(age(Math.max(0, Math.floor(now - facts.journal_seen_at_epoch_secs))))});
    }
    return t("browser.about.lines", {own,journal});
  }

  globalThis.SolstoneAbout = { decode, block, arch };
})();
