#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Cut or recover a GitHub Release for a macOS app.
#
# Usage:
#   scripts/github-release.sh --app sol [<version>]
#   scripts/github-release.sh --app journal --build <build> [<version>]
set -euo pipefail

GIT_BIN="${GIT_BIN:-git}"
GH_BIN="${GH_BIN:-gh}"
RELEASE_IDENTITY_BIN="${RELEASE_IDENTITY_BIN:-scripts/release_identity.py}"
EXTRACT_CHANGELOG_BIN="${EXTRACT_CHANGELOG_BIN:-scripts/extract_changelog.sh}"
GIT_REMOTE="${GIT_REMOTE:-origin}"

APP=""
VERSION_ARG=""
BUILD_ARG=""
DRY_RUN="${GITHUB_RELEASE_DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "error: --app requires sol or journal" >&2; exit 2; }
      APP="$2"
      shift 2
      ;;
    --build)
      [[ $# -ge 2 ]] || { echo "error: --build requires a value" >&2; exit 2; }
      BUILD_ARG="$2"
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

REPO_ROOT=$("$GIT_BIN" rev-parse --show-toplevel)
cd "$REPO_ROOT"

case "$APP" in
  sol)
    [[ -z "$BUILD_ARG" ]] || { echo "error: --build is only valid for journal" >&2; exit 2; }
    INFO_PLIST="Sources/solstone/Info.plist"
    if [[ -n "$VERSION_ARG" ]]; then
      IDENTITY_ARGS=(identity --app sol --version "$VERSION_ARG")
    else
      IDENTITY_ARGS=(identity --app sol --plist "$INFO_PLIST")
    fi
    ;;
  journal)
    INFO_PLIST="Sources/journal/Info.plist"
    if [[ -n "$VERSION_ARG" ]]; then
      [[ -n "$BUILD_ARG" ]] || { echo "error: --build is required when journal version is supplied" >&2; exit 2; }
      IDENTITY_ARGS=(identity --app journal --version "$VERSION_ARG" --build "$BUILD_ARG")
    else
      [[ -z "$BUILD_ARG" ]] || { echo "error: omit --build when reading journal identity from plist" >&2; exit 2; }
      IDENTITY_ARGS=(identity --app journal --plist "$INFO_PLIST")
    fi
    ;;
esac

identity_field() {
  "$RELEASE_IDENTITY_BIN" "${IDENTITY_ARGS[@]}" --field "$1"
}

VERSION="$(identity_field short_version)"
BUILD=""
if [[ "$APP" == "journal" ]]; then
  BUILD="$(identity_field bundle_version)"
fi
TAG="$(identity_field github_tag)"
DMG="$(identity_field dmg_name)"
TITLE="$(identity_field github_title)"
CHANGELOG="$(identity_field changelog_path)"
CHANGELOG_KEY="$(identity_field changelog_key)"
LATEST_FLAG="$(identity_field github_latest_arg)"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "APP=${APP}"
  echo "VERSION=${VERSION}"
  if [[ "$APP" == "journal" ]]; then
    echo "BUILD=${BUILD}"
  fi
  echo "TAG=${TAG}"
  echo "DMG=${DMG}"
  echo "TITLE=${TITLE}"
  echo "CHANGELOG=${CHANGELOG}"
  if [[ "$APP" == "journal" ]]; then
    echo "CHANGELOG_KEY=${CHANGELOG_KEY}"
  fi
  if [[ -n "$LATEST_FLAG" ]]; then
    echo "LATEST_ARGS=${LATEST_FLAG}"
  else
    echo "LATEST_ARGS=(default)"
  fi
  echo "git tag -a ${TAG} -m '${TITLE}'"
  echo "git push ${GIT_REMOTE} ${TAG}"
  echo "gh release create ${TAG} ${DMG} --title '${TITLE}' --notes-file <notes> ${LATEST_FLAG}"
  exit 0
fi

if [[ ! -f "$DMG" ]]; then
  echo "error: $DMG not found in $(pwd)" >&2
  echo "       scp it from the build host first, then retry." >&2
  exit 1
fi

NOTES_FILE=$(mktemp)
RELEASE_JSON=$(mktemp)
RELEASE_VIEW_ERR=$(mktemp)
trap 'rm -f "$NOTES_FILE" "$RELEASE_JSON" "$RELEASE_VIEW_ERR"' EXIT
"$EXTRACT_CHANGELOG_BIN" "$CHANGELOG_KEY" "$CHANGELOG" > "$NOTES_FILE"

if [[ "$APP" == "journal" ]]; then
  "$RELEASE_IDENTITY_BIN" check-journal-pin \
    --journal-plist Sources/journal/Info.plist \
    --makefile Makefile \
    --bundle-config Sources/JournalRuntime/BundleConfig.swift \
    --expected-version "$VERSION"
fi

HEAD_COMMIT=$("$GIT_BIN" rev-parse HEAD)

local_tag_commit() {
  "$GIT_BIN" rev-parse --verify "refs/tags/${TAG}^{commit}" 2>/dev/null
}

remote_tag_commit() {
  local output peeled direct
  if ! output=$("$GIT_BIN" ls-remote --tags "$GIT_REMOTE" "refs/tags/${TAG}" "refs/tags/${TAG}^{}"); then
    return 2
  fi
  peeled=$(printf '%s\n' "$output" | awk -v ref="refs/tags/${TAG}^{}" '$2 == ref { print $1; exit }')
  direct=$(printf '%s\n' "$output" | awk -v ref="refs/tags/${TAG}" '$2 == ref { print $1; exit }')
  if [[ -n "$peeled" ]]; then
    printf '%s\n' "$peeled"
    return 0
  fi
  if [[ -n "$direct" ]]; then
    printf '%s\n' "$direct"
    return 0
  fi
  return 1
}

LOCAL_TAG_COMMIT=""
if LOCAL_TAG_COMMIT=$(local_tag_commit); then
  if [[ "$LOCAL_TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
    echo "error: local tag ${TAG} points at ${LOCAL_TAG_COMMIT}, expected ${HEAD_COMMIT}" >&2
    exit 1
  fi
fi

REMOTE_TAG_COMMIT=""
REMOTE_TAG_STATUS=0
REMOTE_TAG_COMMIT=$(remote_tag_commit) || REMOTE_TAG_STATUS=$?
if [[ "$REMOTE_TAG_STATUS" == "2" ]]; then
  echo "error: could not read remote tag ${TAG} from ${GIT_REMOTE}" >&2
  exit 1
fi
if [[ "$REMOTE_TAG_STATUS" == "0" && "$REMOTE_TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
  echo "error: remote tag ${TAG} points at ${REMOTE_TAG_COMMIT}, expected ${HEAD_COMMIT}" >&2
  exit 1
fi

if [[ -z "$LOCAL_TAG_COMMIT" && "$REMOTE_TAG_STATUS" != "0" ]]; then
  "$GIT_BIN" tag -a "$TAG" -m "$TITLE"
  LOCAL_TAG_COMMIT="$HEAD_COMMIT"
fi

if [[ "$REMOTE_TAG_STATUS" != "0" ]]; then
  "$GIT_BIN" push "$GIT_REMOTE" "$TAG"
fi

DMG_SIZE=$(python3 -c 'import os, sys; print(os.path.getsize(sys.argv[1]))' "$DMG")
if "$GH_BIN" release view "$TAG" --json tagName,name,body,assets > "$RELEASE_JSON" 2>"$RELEASE_VIEW_ERR"; then
  RELEASE_STATE_STATUS=0
  RELEASE_STATE=$(python3 - "$RELEASE_JSON" "$TAG" "$TITLE" "$NOTES_FILE" "$DMG" "$DMG_SIZE" <<'PY'
import json
import sys

release_path, expected_tag, expected_title, notes_path, asset_name, asset_size = sys.argv[1:]
with open(release_path, "r", encoding="utf-8") as handle:
    release = json.load(handle)
with open(notes_path, "r", encoding="utf-8") as handle:
    expected_body = handle.read()

if release.get("tagName") != expected_tag:
    print("conflict: tagName")
    raise SystemExit(20)
if release.get("name") != expected_title:
    print("conflict: title")
    raise SystemExit(20)
if release.get("body") != expected_body:
    print("conflict: notes")
    raise SystemExit(20)

for asset in release.get("assets") or []:
    if asset.get("name") != asset_name:
        continue
    size = asset.get("size")
    if size is None or str(size) != str(asset_size):
        print("conflict: asset")
        raise SystemExit(20)
    print("complete")
    raise SystemExit(0)

print("missing-asset")
raise SystemExit(10)
PY
  ) || RELEASE_STATE_STATUS=$?
  RELEASE_STATE_STATUS=${RELEASE_STATE_STATUS:-0}
  case "$RELEASE_STATE_STATUS" in
    0)
      echo "✓ GitHub release ${TAG} already matches ${DMG}"
      exit 0
      ;;
    10)
      "$GH_BIN" release upload "$TAG" "$DMG"
      echo "✓ uploaded missing GitHub release asset ${DMG} to ${TAG}"
      exit 0
      ;;
    *)
      echo "error: GitHub release ${TAG} conflicts (${RELEASE_STATE})" >&2
      exit 1
      ;;
  esac
else
  if ! grep -qiE 'not found|could not find|no release found' "$RELEASE_VIEW_ERR"; then
    cat "$RELEASE_VIEW_ERR" >&2
    echo "error: could not read GitHub release ${TAG}" >&2
    exit 1
  fi
fi

if ! "$GH_BIN" release create "$TAG" "$DMG" \
    --title "$TITLE" \
    --notes-file "$NOTES_FILE" \
    ${LATEST_FLAG:+$LATEST_FLAG}; then
  echo "error: gh release create failed for ${TAG}" >&2
  exit 1
fi

echo "✓ ensured ${TAG} GitHub release with ${DMG} attached"
