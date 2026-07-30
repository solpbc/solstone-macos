#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# `make ci` wrapper: run swift + python tests inside an ephemeral macOS test
# keychain and retain the combined output in scratch/ci.log.
#
# Why: tests that exercise SecItemAdd against the default user keychain can fail
# under non-interactive SSH with errSecInteractionNotAllowed (-25308) because the
# login keychain is locked and refuses to fire a GUI unlock prompt. The login
# keychain is the default keychain on a fresh user account, so any
# kSecClassGenericPassword write goes there by default.
#
# How: create a fresh keychain with a random per-run password, make it the
# user-domain default, and add it to the head of the user-domain search list
# via the shared keychain_search_list.py helper. Teardown re-reads live state:
# it restores the prior default only if the CI keychain is still default, and
# removes only this run's keychain from the search list instead of restoring a
# start-time snapshot. Because SPLKeychainStore (and any well-formed keychain
# helper) calls SecItemAdd without kSecUseKeychain, items follow the default
# keychain — redirecting the default routes all writes transparently.
#
# Trap reliability: INT exits 130 and TERM exits 143, then the guarded EXIT
# trap performs teardown without altering that status. SIGKILL bypasses cleanup;
# the leading `security delete-keychain ... 2>/dev/null || true` line recovers
# from any prior crashed-run leftover. The absolute log path is printed last.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CI_LOG="$REPO_ROOT/scratch/ci.log"
TEST_KC="$HOME/Library/Keychains/ci-test.keychain-db"
TEST_PASS="$(openssl rand -hex 16)"
PRIOR_DEFAULT=""
TEARDOWN_DONE=0

mkdir -p "$(dirname "$CI_LOG")"
: > "$CI_LOG"

teardown() {
  if [ "$TEARDOWN_DONE" = "1" ]; then
    return 0
  fi
  TEARDOWN_DONE=1

  if [ -n "$PRIOR_DEFAULT" ]; then
    python3 scripts/keychain_search_list.py restore-default-if-current "$TEST_KC" "$PRIOR_DEFAULT" || {
      echo "warn: failed to restore prior default keychain" >&2
      true
    }
  else
    echo "warn: prior default keychain was not recorded; skipping default restore" >&2 || true
  fi

  python3 scripts/keychain_search_list.py remove "$TEST_KC" || {
    echo "warn: failed to remove CI keychain from user search list" >&2
    true
  }

  security delete-keychain "$TEST_KC" >/dev/null 2>&1 || {
    echo "warn: failed to delete CI keychain: $TEST_KC" >&2
    true
  }

  printf 'full log: %s\n' "$CI_LOG" || true
  true
}

trap 'teardown' EXIT
trap 'trap - INT; exit 130' INT
trap 'trap - TERM; exit 143' TERM

# Clean any leftover from a prior crashed run.
security delete-keychain "$TEST_KC" 2>/dev/null || true

security create-keychain -p "$TEST_PASS" "$TEST_KC"
security set-keychain-settings -lut 7200 "$TEST_KC"
security unlock-keychain -p "$TEST_PASS" "$TEST_KC"

PRIOR_DEFAULT="$(python3 scripts/keychain_search_list.py current-default)"

python3 scripts/keychain_search_list.py prepend "$TEST_KC"
security default-keychain -d user -s "$TEST_KC"

swift test 2>&1 | tee -a "$CI_LOG"
