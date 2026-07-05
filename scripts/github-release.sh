#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Cut a GitHub Release for a macOS app: annotated tag plus `gh release create`
# with the signed/notarized DMG attached and release notes pulled from the
# app's changelog via scripts/extract_changelog.sh.
#
# Usage: scripts/github-release.sh --app {sol|journal} [<version>]
set -euo pipefail

APP=""
VERSION_ARG=""
DRY_RUN="${GITHUB_RELEASE_DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "error: --app requires sol or journal" >&2; exit 2; }
      APP="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -*)
      echo "error: unknown option $1" >&2
      exit 2
      ;;
    *)
      [[ -z "$VERSION_ARG" ]] || { echo "error: only one version argument is allowed" >&2; exit 2; }
      VERSION_ARG="$1"
      shift
      ;;
  esac
done

case "$APP" in
  sol|journal) ;;
  "")
    echo "error: --app {sol|journal} is required" >&2
    exit 2
    ;;
  *)
    echo "error: unknown app '$APP' (expected sol or journal)" >&2
    exit 2
    ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

read_plist_version() {
  python3 -c "import plistlib; print(plistlib.load(open('$1','rb'))['CFBundleShortVersionString'])"
}

case "$APP" in
  sol)
    INFO_PLIST="Sources/solstone/Info.plist"
    CHANGELOG="CHANGELOG.md"
    VERSION="${VERSION_ARG:-$(read_plist_version "$INFO_PLIST")}"
    TAG="v${VERSION}"
    DMG="sol-${VERSION}.dmg"
    TITLE="solstone-macos ${VERSION}"
    LATEST_FLAG=""
    ;;
  journal)
    INFO_PLIST="Sources/journal/Info.plist"
    CHANGELOG="CHANGELOG-journal.md"
    VERSION="${VERSION_ARG:-$(read_plist_version "$INFO_PLIST")}"
    TAG="journal-v${VERSION}"
    DMG="journal-${VERSION}.dmg"
    TITLE="journal-macos ${VERSION}"
    LATEST_FLAG="--latest=false"
    ;;
esac

if [[ "$DRY_RUN" == "1" ]]; then
  echo "APP=${APP}"
  echo "VERSION=${VERSION}"
  echo "TAG=${TAG}"
  echo "DMG=${DMG}"
  echo "TITLE=${TITLE}"
  echo "CHANGELOG=${CHANGELOG}"
  if [[ -n "$LATEST_FLAG" ]]; then
    echo "LATEST_ARGS=${LATEST_FLAG}"
  else
    echo "LATEST_ARGS=(default)"
  fi
  echo "git tag -a ${TAG} -m '${TITLE}'"
  echo "git push origin ${TAG}"
  echo "gh release create ${TAG} ${DMG} --title '${TITLE}' --notes-file <notes> ${LATEST_FLAG}"
  exit 0
fi

if [[ ! -f "$DMG" ]]; then
  echo "error: $DMG not found in $(pwd)" >&2
  echo "       scp it from the build host first, then retry." >&2
  exit 1
fi

# Pre-flight the CHANGELOG block before tagging — fail before any side effect if
# the `## [VERSION]` entry is missing.
NOTES_FILE=$(mktemp)
trap 'rm -f "$NOTES_FILE"' EXIT
scripts/extract_changelog.sh "$VERSION" "$CHANGELOG" > "$NOTES_FILE"

git tag -a "$TAG" -m "$TITLE"
if ! git push origin "$TAG"; then
  echo "error: git push origin ${TAG} failed; the tag was created locally but not pushed." >&2
  echo "       Resolve the push and create the release manually:" >&2
  echo "       gh release create ${TAG} ${DMG} --title '${TITLE}' --notes-file <(scripts/extract_changelog.sh ${VERSION} ${CHANGELOG}) ${LATEST_FLAG}" >&2
  exit 1
fi

if ! gh release create "$TAG" "$DMG" \
    --title "$TITLE" \
    --notes-file "$NOTES_FILE" \
    ${LATEST_FLAG:+$LATEST_FLAG}; then
  echo "error: gh release create failed; the git tag ${TAG} is pushed." >&2
  echo "       Re-run manually:" >&2
  echo "       gh release create ${TAG} ${DMG} --title '${TITLE}' --notes-file <(scripts/extract_changelog.sh ${VERSION} ${CHANGELOG}) ${LATEST_FLAG}" >&2
  exit 1
fi

echo "✓ tagged ${TAG} and created GitHub release with ${DMG} attached"
