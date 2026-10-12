#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Vendor the Safari build of the solstone extension from a clean
# solstone-browser checkout into vendor/safari-extension, and record its
# source revision and tree digest in vendor/safari-extension.json.
# Usage: scripts/vendor_safari_extension.sh <solstone-browser checkout>
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(cd "${1:?solstone-browser checkout}" && pwd)"
if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
  echo "solstone-browser checkout has uncommitted changes" >&2
  exit 1
fi
REV="$(git -C "$SRC" rev-parse HEAD)"
(cd "$SRC" && node scripts/build.mjs >/dev/null)
VERSION="$(node -p "JSON.parse(require('fs').readFileSync('$SRC/extension/manifest.json','utf8')).version")"
STAGE="$SRC/dist/solstone-browser-$VERSION-safari"
test -f "$STAGE/manifest.json"
rm -rf vendor/safari-extension
cp -R "$STAGE" vendor/safari-extension
DIGEST="$(cd vendor/safari-extension && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; done | shasum -a 256 | cut -d' ' -f1)"
cat > vendor/safari-extension.json <<JSON
{
  "source": "solstone-browser",
  "revision": "$REV",
  "version": "$VERSION",
  "tree_sha256": "$DIGEST"
}
JSON
echo "vendored solstone-browser $VERSION at $REV (tree $DIGEST)"
