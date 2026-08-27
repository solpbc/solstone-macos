#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Fails when a committed generated brand asset (AppIcon.icns x2, the menubar
# template PDFs, the wordmark PNGs, or the machine-generated
# assets/icon-journal.svg) no longer matches what `make icons` produces from
# its current SVG/JournalMarkKit source. `make icons` pins SOURCE_DATE_EPOCH,
# so regenerate-and-diff is deterministic — a real content change is the only
# thing that can produce a diff here.
#
# Never call this from a dirty tree: it regenerates in place, so it needs a
# known-clean baseline to diff against, and it restores that baseline itself
# on the way out (pass or fail) so it never leaves the tree mutated.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GENERATED_PATHS=(
  Sources/solstone/Resources
  Sources/journal/Resources
  assets/icon-journal.svg
)

if ! git diff --quiet -- "${GENERATED_PATHS[@]}"; then
  echo "error: working tree already has uncommitted changes under a generated-brand-asset path:" >&2
  git diff --name-only -- "${GENERATED_PATHS[@]}" | sed 's/^/  /' >&2
  echo "commit or stash before running the brand-asset freshness check." >&2
  exit 1
fi

restore() {
  git checkout -q -- "${GENERATED_PATHS[@]}"
}
trap restore EXIT

if ! make icons > /tmp/brand-asset-freshness-icons.log 2>&1; then
  echo "error: 'make icons' failed — see /tmp/brand-asset-freshness-icons.log" >&2
  cat /tmp/brand-asset-freshness-icons.log >&2
  exit 1
fi

stale="$(git diff --name-only -- "${GENERATED_PATHS[@]}")"
if [ -n "$stale" ]; then
  echo "error: generated brand asset(s) are stale relative to their source:" >&2
  echo "$stale" | sed 's/^/  /' >&2
  echo "fix: run 'make icons' locally and commit the regenerated files." >&2
  exit 1
fi

echo "brand assets are current with their sources."
