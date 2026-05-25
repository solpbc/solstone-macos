#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Terminology guard for owner-visible naming of the journal/upload referent.
# Flags new occurrences of the words "service" or "server" in surfaces the
# owner reads.
#
# Rule, canonical from the lode contract / decision
# 260516-cmo-observer-surface-journal-terminology § 5:
# The journal/upload referent → flagged. OS-daemon *Service / config-key /
# internal-identifier / SPL Keychain / installer JSONL protocol / log-only
# diagnostics → allowed. The two senses of "service" are different words.
#
# Excluded classes:
# - OS-daemon *Service types (SyncService, HeartbeatService, SolMacIPCService,
#   NWListener) are cross-process IPC engineering terms. They naturally sit
#   outside this scan as identifiers/comments, and Sources/SPLTunnel/,
#   Sources/SolstoneCore/, and Sources/sol-mac/ are not walked.
# - Installer JSONL protocol values ("service" step, "--skip-service" flag,
#   service_up_failed codes) are mirrored from upstream Python.
#   Sources/solstone/InstallerJSONLEvents.swift is explicitly excluded by glob.
# - Config keys (serverURL, serverKey, serviceMode) are single tokens; they are
#   not matched by \b(server|service)\b because the next character is a word
#   character.
# - Internal identifiers (Tab.service, serviceTab, BundledServiceCard, etc.)
#   are not inside string literals, so layer A naturally excludes them.
# - SPL Keychain terms (kSecAttrService, service: parameter labels) live under
#   Sources/SPLTunnel/, which is not scanned.
# - Log-only diagnostics are filtered out by Logger.* after the string-literal
#   scan; they never reach the owner UI.
# - CLI back-compat alias case "service", "journal": at
#   Sources/solstone/SettingsView.swift:165 is explicitly allowlisted for
#   owners who scripted `open` against the prior tab name in lode waiim7rj AC4.
# - Settings tab raw value case `service = "service"` is persistence plumbing,
#   not owner-visible copy.
# - UICopy's "home server" phrase names an owner-provided machine example,
#   not the journal/upload referent.

swift_matches="$(
  rg -n --pcre2 '"[^"]*\b(service|server)\b[^"]*"' \
    Sources/solstone -g '*.swift' \
    -g '!Sources/solstone/InstallerJSONLEvents.swift' \
  | rg -v 'Logger\.' \
  | grep -v '"service", "journal"' \
  | grep -v '"service", "restart"' \
  | grep -v '"service", "uninstall"' \
  | grep -v '"service-uninstall"' \
  | grep -v '"sol service uninstall' \
  | grep -vE '^Sources/solstone/SettingsView\.swift:[0-9]+:[[:space:]]+case service = "service"$' \
  | grep -vE '^Sources/solstone/UICopy\.swift:[0-9]+:.*JOURNAL_MODE_ANOTHER_MACHINE_TRADEOFF.*home server' \
  || true
)"

narrative_matches="$(
  rg -n -i --pcre2 '\b(service|server)\b' \
    README.md INSTALL.md Sources/solstone/Info.plist \
  || true
)"

matches=""
[ -n "$swift_matches" ] && matches+="$swift_matches"$'\n'
[ -n "$narrative_matches" ] && matches+="$narrative_matches"$'\n'

if [ -n "$matches" ]; then
  echo "terminology assertion failed:"
  printf '%s' "$matches"
  exit 1
fi

echo "terminology assertion passed"
