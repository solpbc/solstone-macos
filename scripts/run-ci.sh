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
# trap performs teardown without altering that status. SIGKILL bypasses cleanup
# entirely, so startup recovers from a killed run instead: it refills the user
# default-keychain slot before deleting the leftover keychain, because deleting
# the keychain that holds the default empties the slot outright and wedges every
# later run. The absolute log path is printed last.
#
# Concurrency: the test keychain path is fixed and the default keychain is a
# single user-domain slot, so both are owned by this script for the whole run
# and neither can be shared. Two runs on one host would delete each other's
# keychain at startup and stomp the default mid-test, and every symptom of
# that reads as a flaky test. scripts/ci_lock.py serializes them on a host-wide
# flock, re-exec'ing this script with the lock held on fd 9.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Take the host CI lock before touching any shared state — in particular before
# truncating scratch/ci.log, which belongs to whoever currently holds the lock.
# The guard tests the fd itself rather than a marker variable, so a stale export
# in one of the long-lived tmux build windows cannot silently disable the lock.
if [ -z "${SOLSTONE_CI_LOCK_FD:-}" ] || [ ! -e "/dev/fd/${SOLSTONE_CI_LOCK_FD}" ]; then
  exec python3 "$REPO_ROOT/scripts/ci_lock.py" -- "$REPO_ROOT/scripts/run-ci.sh" "$@"
fi

CI_LOG="$REPO_ROOT/scratch/ci.log"
TEST_KC="$HOME/Library/Keychains/ci-test.keychain-db"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
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

# Put a real keychain back in the default slot BEFORE deleting any leftover.
# `security delete-keychain` on the keychain that currently holds the user
# default does not fall back to anything — it empties the slot, and every later
# read fails with "SecKeychainCopyDomainDefault user: A default keychain could
# not be found". This run would then abort at PRIOR_DEFAULT below, leaving the
# slot empty, so one killed run wedges `make ci` for the whole host until a
# human repairs it. Measured on pro5e 2026-08-19.
needs_default_repair() {
  local current
  current="$(security default-keychain -d user 2>/dev/null || true)"
  case "$current" in
    "") return 0 ;;           # already wedged — no default keychain at all
    *"$TEST_KC"*) return 0 ;; # a killed run left ours in the slot
    *) return 1 ;;
  esac
}

if needs_default_repair; then
  if [ -f "$LOGIN_KC" ]; then
    echo "note: restoring the user default keychain left behind by a killed run" >&2
    security default-keychain -d user -s "$LOGIN_KC"
  else
    echo "warn: no user default keychain, and $LOGIN_KC is missing" >&2
  fi
fi

# Clean any leftover from a prior crashed run.
security delete-keychain "$TEST_KC" 2>/dev/null || true

security create-keychain -p "$TEST_PASS" "$TEST_KC"
security set-keychain-settings -lut 7200 "$TEST_KC"
security unlock-keychain -p "$TEST_PASS" "$TEST_KC"

PRIOR_DEFAULT="$(python3 scripts/keychain_search_list.py current-default)"

python3 scripts/keychain_search_list.py prepend "$TEST_KC"
security default-keychain -d user -s "$TEST_KC"

run_tests() {
  swift test 2>&1
  python3 -m unittest discover scripts/tests 2>&1
}

# `9>&-` closes the inherited lock fd in the test phase and in tee, so the lock
# outlives this shell in no child. An orphaned test process therefore cannot
# keep the next run waiting for a run that is already over.
run_tests 9>&- | tee -a "$CI_LOG" 9>&-
