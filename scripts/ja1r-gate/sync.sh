#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# Push the pinned linkage-gate harness + the exact product HEAD to the ja1r rig,
# then write a local sync receipt binding what was actually found on the rig.
#
# Establishes a versioned, fail-closed rig input and nothing else. It never
# builds, installs, resets an app, runs a lane, or publishes.
#
# Every precondition is checked BEFORE the first remote mutation, so a bad local
# state cannot leave the rig half-synced.
#
# The receipt is what makes the harness revision *evidence* rather than an
# operator's typing: it records the revision marker read back off the rig after
# rsync, bound to the product commit verified present there. The verifier
# consumes the receipt; typing the expected hash cannot forge one.
#
# Usage: scripts/ja1r-gate/sync.sh
# Env:
#   EXTRO_TOOLS_DIR   local extro-tools checkout (default ../extro-tools)
#   JA1R_HOST         rig host (default ja1r.local)
#   JA1R_HARNESS_DIR  harness destination on the rig
#   JA1R_PRODUCT_DIR  product checkout on the rig
#   JA1R_GATE_SYNC_RECEIPT  local receipt path to write

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN_FILE="$REPO_ROOT/scripts/ja1r-gate/extro-tools.rev"

EXTRO_TOOLS_DIR="${EXTRO_TOOLS_DIR:-$(dirname "$REPO_ROOT")/extro-tools}"
JA1R_HOST="${JA1R_HOST:-ja1r.local}"
JA1R_HARNESS_DIR="${JA1R_HARNESS_DIR:-\$HOME/extro-tools/tools/solstone-macos-gate}"
JA1R_PRODUCT_DIR="${JA1R_PRODUCT_DIR:-\$HOME/projects/solstone-macos}"
RECEIPT="${JA1R_GATE_SYNC_RECEIPT:-$REPO_ROOT/.ja1r-gate/sync-receipt.json}"

MARKER_NAME=".ja1r-gate-revision.json"

die() { echo "ja1r-gate-sync: $*" >&2; exit 1; }

[ -f "$PIN_FILE" ] || die "missing harness pin $PIN_FILE"
PIN="$(tr -d '[:space:]' < "$PIN_FILE")"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || die "harness pin is not a 40-hex sha: $PIN"

# ---------------------------------------------------------------------------
# Preconditions -- all local, all before any remote mutation.
# ---------------------------------------------------------------------------
# `.git` is a file, not a directory, in a linked worktree — ask git, don't stat.
git -C "$EXTRO_TOOLS_DIR" rev-parse --git-dir >/dev/null 2>&1 \
  || die "EXTRO_TOOLS_DIR is not a git worktree: $EXTRO_TOOLS_DIR"

extro_head="$(git -C "$EXTRO_TOOLS_DIR" rev-parse HEAD)"
[ "$extro_head" = "$PIN" ] || die \
  "extro-tools is at $extro_head, not the pinned $PIN — check out the pin (the sync never follows main)"

[ -z "$(git -C "$EXTRO_TOOLS_DIR" status --porcelain)" ] || die \
  "extro-tools checkout is dirty — the harness pushed to the rig must be exactly the pinned revision"

[ -d "$EXTRO_TOOLS_DIR/tools/solstone-macos-gate" ] || die \
  "pinned extro-tools has no tools/solstone-macos-gate"

[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || die \
  "product checkout is dirty — the HEAD pushed to the rig would misrepresent what gets published"

PRODUCT_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
[[ "$PRODUCT_HEAD" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve a full product HEAD"

echo "ja1r-gate-sync: harness pin $PIN"
echo "ja1r-gate-sync: product HEAD $PRODUCT_HEAD"
echo "ja1r-gate-sync: rig $JA1R_HOST"

# ---------------------------------------------------------------------------
# Remote mutation begins here.
# ---------------------------------------------------------------------------
harness_dir="$(ssh "$JA1R_HOST" "mkdir -p \"$JA1R_HARNESS_DIR\" && cd \"$JA1R_HARNESS_DIR\" && pwd")"
[ -n "$harness_dir" ] || die "cannot resolve the harness dir on $JA1R_HOST"

echo "ja1r-gate-sync: syncing harness -> $JA1R_HOST:$harness_dir"
rsync -a --delete \
  --exclude '.venv/' \
  --exclude '__pycache__/' \
  --exclude '.pytest_cache/' \
  --exclude '*.pyc' \
  "$EXTRO_TOOLS_DIR/tools/solstone-macos-gate/" \
  "$JA1R_HOST:$harness_dir/"

# Stamp the revision marker into the copied harness, then read it back. The
# harness does not record its own revision, so this marker is the only thing
# tying the code on the rig to the pin.
marker_json="$(printf '{"harness_revision": "%s", "source": "extro-tools", "tool": "tools/solstone-macos-gate", "marker_version": 1}' "$PIN")"
ssh "$JA1R_HOST" "cat > \"$harness_dir/$MARKER_NAME\"" <<<"$marker_json"

marker_rev="$(ssh "$JA1R_HOST" "python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"harness_revision\"])' \"$harness_dir/$MARKER_NAME\"")"
[ "$marker_rev" = "$PIN" ] || die \
  "revision marker read back from the rig is $marker_rev, expected $PIN"
echo "ja1r-gate-sync: harness marker verified on the rig ($marker_rev)"

# ---------------------------------------------------------------------------
# Fast-forward the rig's product checkout to the exact local HEAD.
# No rebase, no stash: a dirty or divergent rig is a hard stop.
# ---------------------------------------------------------------------------
product_dir="$(ssh "$JA1R_HOST" "cd \"$JA1R_PRODUCT_DIR\" && pwd")"
[ -n "$product_dir" ] || die "no product checkout at $JA1R_PRODUCT_DIR on $JA1R_HOST"

remote_dirty="$(ssh "$JA1R_HOST" "git -C \"$product_dir\" status --porcelain")"
[ -z "$remote_dirty" ] || die "the rig's product checkout is dirty — refusing to fast-forward it"

echo "ja1r-gate-sync: fast-forwarding $JA1R_HOST:$product_dir to $PRODUCT_HEAD"
ssh "$JA1R_HOST" "git -C \"$product_dir\" fetch --quiet origin && git -C \"$product_dir\" merge --ff-only --quiet $PRODUCT_HEAD" \
  || die "the rig's product checkout will not fast-forward to $PRODUCT_HEAD (divergent — reconcile it on the rig)"

remote_head="$(ssh "$JA1R_HOST" "git -C \"$product_dir\" rev-parse HEAD")"
[ "$remote_head" = "$PRODUCT_HEAD" ] || die \
  "the rig's product HEAD is $remote_head, expected $PRODUCT_HEAD"

for contract in ax-contract.json journal-ax-contract.json; do
  ssh "$JA1R_HOST" "test -f \"$product_dir/$contract\"" \
    || die "the rig's product checkout is missing $contract"
done
echo "ja1r-gate-sync: product HEAD verified on the rig, both AX contracts present"

# ---------------------------------------------------------------------------
# Receipt: what was actually observed on the rig, not what we hoped for.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$RECEIPT")"
cat > "$RECEIPT" <<EOF
{
  "harness_revision": "$marker_rev",
  "product_commit": "$remote_head",
  "rig": "$JA1R_HOST",
  "harness_dir": "$harness_dir",
  "product_dir": "$product_dir",
  "synced_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "ja1r-gate-sync: receipt written to $RECEIPT"
echo "ja1r-gate-sync: rig is ready — run the lanes on $JA1R_HOST, then verify the reports here."
