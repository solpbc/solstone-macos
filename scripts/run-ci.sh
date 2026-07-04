#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# `make ci` wrapper: run swift + python tests inside an ephemeral macOS test
# keychain.
#
# Why: tests that exercise SecItemAdd against the default user keychain (e.g.
# Tests/SPLTunnelTests/SPLKeychainTests.swift) fail under non-interactive SSH
# with errSecInteractionNotAllowed (-25308) because the login keychain is
# locked and refuses to fire a GUI unlock prompt. The login keychain is the
# default keychain on a fresh user account, so any kSecClassGenericPassword
# write goes there by default.
#
# How: create a fresh keychain with a random per-run password, swap it in as
# the user-domain default and the head of the user-domain search list, run
# tests, then restore prior state and delete the keychain on EXIT. Because
# SPLKeychain (and any well-formed keychain helper) calls SecItemAdd without
# kSecUseKeychain, items follow the default keychain — redirecting the
# default routes all writes transparently. No production code or test code
# changes needed.
#
# Trap reliability: the trap fires on normal exit, test failure, SIGINT, and
# SIGTERM. SIGKILL bypasses it; the leading `security delete-keychain ...
# 2>/dev/null || true` line recovers from any prior crashed-run leftover.

set -euo pipefail

TEST_KC="$HOME/Library/Keychains/ci-test.keychain-db"
TEST_PASS="$(openssl rand -hex 16)"

# Clean any leftover from a prior crashed run.
security delete-keychain "$TEST_KC" 2>/dev/null || true

security create-keychain -p "$TEST_PASS" "$TEST_KC"
security set-keychain-settings -lut 7200 "$TEST_KC"
security unlock-keychain -p "$TEST_PASS" "$TEST_KC"

PRIOR_LIST=$(security list-keychains -d user | tr -d '"' | xargs)
PRIOR_DEFAULT=$(security default-keychain -d user | tr -d '"' | xargs || true)
PRIOR_DEFAULT="${PRIOR_DEFAULT:-$HOME/Library/Keychains/login.keychain-db}"

security list-keychains -d user -s "$TEST_KC" $PRIOR_LIST
security default-keychain -d user -s "$TEST_KC"

# $PRIOR_LIST is embedded at trap-definition time so its space-separated
# entries reach `security list-keychains -s` as discrete arguments;
# $PRIOR_DEFAULT and $TEST_KC are deferred to trap-fire time (set once, never
# mutated, safe under `set -u`).
trap '
  security default-keychain -d user -s "$PRIOR_DEFAULT" >/dev/null 2>&1 || true
  security list-keychains -d user -s '"$PRIOR_LIST"' >/dev/null 2>&1 || true
  security delete-keychain "$TEST_KC" >/dev/null 2>&1 || true
' EXIT

swift test
python3 -m unittest discover scripts/tests
