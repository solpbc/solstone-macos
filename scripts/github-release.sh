#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Cut a GitHub Release for solstone-macos: an annotated tag plus
# `gh release create` with the signed/notarized DMG attached and release notes
# pulled from CHANGELOG.md via scripts/extract_changelog.sh.
#
# Run on the extro host — where `gh` is authenticated and the DMG was scp'd into
# CWD during `make publish-appcast` — AFTER founder approval. Sparkle (the
# appcast published by publish-appcast.py) is the primary update channel; the
# DMG attached here is the pre-auto-update download path and the GitHub front
# door, so this step is source-release hygiene, not the distribution mechanism.
#
# Mirrors solstone-linux/scripts/release.sh and solstone/scripts/release.sh so
# all three product repos share one tag-and-release shape and one changelog
# extractor.
#
# Usage: scripts/github-release.sh [<version>]
#   <version> defaults to CFBundleShortVersionString from Info.plist.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

VERSION="${1:-$(python3 -c "import plistlib; print(plistlib.load(open('Sources/solstone/Info.plist','rb'))['CFBundleShortVersionString'])")}"
TAG="v${VERSION}"
DMG="solstone-${VERSION}.dmg"

if [[ ! -f "$DMG" ]]; then
  echo "error: $DMG not found in $(pwd)" >&2
  echo "       scp it from the build host first (see macos-release.md § step 2):" >&2
  echo "       scp pro5e.local:projects/solstone-macos/${DMG} ." >&2
  exit 1
fi

# Pre-flight the CHANGELOG block before tagging — fail before any side effect if
# the `## [VERSION]` entry is missing.
NOTES_FILE=$(mktemp)
trap 'rm -f "$NOTES_FILE"' EXIT
scripts/extract_changelog.sh "$VERSION" > "$NOTES_FILE"

git tag -a "$TAG" -m "solstone-macos ${VERSION}"
if ! git push origin "$TAG"; then
  echo "error: git push origin ${TAG} failed; the tag was created locally but not pushed." >&2
  echo "       Resolve the push and create the release manually:" >&2
  echo "       gh release create ${TAG} ${DMG} --title 'solstone-macos ${VERSION}' --notes-file <(scripts/extract_changelog.sh ${VERSION})" >&2
  exit 1
fi

if ! gh release create "$TAG" "$DMG" \
    --title "solstone-macos ${VERSION}" \
    --notes-file "$NOTES_FILE"; then
  echo "error: gh release create failed; the git tag ${TAG} is pushed." >&2
  echo "       Re-run manually:" >&2
  echo "       gh release create ${TAG} ${DMG} --title 'solstone-macos ${VERSION}' --notes-file <(scripts/extract_changelog.sh ${VERSION})" >&2
  exit 1
fi

echo "✓ tagged ${TAG} and created GitHub release with ${DMG} attached"
