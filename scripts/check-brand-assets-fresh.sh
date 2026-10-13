#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Fails when a committed generated brand asset no longer matches what the
# package's `make icons` produces from its current source. `make icons` pins
# SOURCE_DATE_EPOCH, so regenerate-and-diff is deterministic: a real content
# change is the only thing that can produce a diff here.
#
# Usage, from a package root: check-brand-assets-fresh.sh <generated path>...
#   capture (this repository): Sources/solstone/Resources
#   Journal app (solstone-journal, platforms/macos):
#     Sources/journal/Resources/AppIcon.icns assets/icon-journal.svg
# Each package's `make check-brand-assets-fresh` passes its own paths.
#
# Never call this from a dirty tree: it regenerates in place, so it needs a
# known-clean baseline to diff against, and it restores that baseline itself
# on the way out (pass or fail) so it never leaves the tree mutated.

set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: check-brand-assets-fresh.sh <generated path>..." >&2; exit 2; }
GENERATED_PATHS=("$@")

if ! git diff --quiet -- "${GENERATED_PATHS[@]}"; then
  echo "error: working tree already has uncommitted changes under a generated-brand-asset path:" >&2
  git diff --name-only -- "${GENERATED_PATHS[@]}" | sed 's/^/  /' >&2
  echo "commit or stash before running the brand-asset freshness check." >&2
  exit 1
fi

LOG="$(mktemp -t brand-asset-freshness-icons)"
restore() {
  git checkout -q -- "${GENERATED_PATHS[@]}"
}
trap restore EXIT

if ! make icons > "$LOG" 2>&1; then
  echo "error: 'make icons' failed — see $LOG" >&2
  cat "$LOG" >&2
  exit 1
fi
rm -f "$LOG"

stale="$(git diff --name-only -- "${GENERATED_PATHS[@]}")"
if [ -n "$stale" ]; then
  echo "error: generated brand asset(s) are stale relative to their source:" >&2
  echo "$stale" | sed 's/^/  /' >&2
  echo "fix: run 'make icons' locally and commit the regenerated files." >&2
  exit 1
fi

echo "brand assets are current with their sources."
