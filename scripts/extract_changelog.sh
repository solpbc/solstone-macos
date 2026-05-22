#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Extract a single version's block from CHANGELOG.md.
# Usage: extract_changelog.sh <version> [<changelog-path>]
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $(basename "$0") <version> [<changelog-path>]" >&2
  exit 2
fi

VERSION="$1"
CHANGELOG="${2:-CHANGELOG.md}"

if [[ ! -f "$CHANGELOG" ]]; then
  echo "error: $CHANGELOG not found" >&2
  exit 1
fi

# Escape regex metacharacters in the version (dots, etc.) for the awk pattern.
ESCAPED=$(printf '%s\n' "$VERSION" | sed 's/[][\\.*^$/]/\\&/g')
AWK_ESCAPED="${ESCAPED//\\/\\\\}"

OUTPUT=$(awk -v pat="^## \\\\[${AWK_ESCAPED}\\\\]" '
  /^## \[/ { if (seen) exit }
  $0 ~ pat { seen=1 }
  seen
' "$CHANGELOG")

if [[ -z "$OUTPUT" ]]; then
  echo "error: no CHANGELOG.md entry for version ${VERSION}" >&2
  exit 1
fi

printf '%s\n' "$OUTPUT"
