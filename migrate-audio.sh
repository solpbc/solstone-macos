#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 sol pbc
#
# migrate-audio.sh - Merge legacy audio files into multi-track M4A using ffmpeg

set -e

# Parse arguments
SEGMENT_DIR=""
DELETE_ORIGINALS=false
FORCE=false

for arg in "$@"; do
    case $arg in
        --delete)
            DELETE_ORIGINALS=true
            ;;
        --force)
            FORCE=true
            ;;
        -*)
            echo "Unknown option: $arg"
            exit 1
            ;;
        *)
            SEGMENT_DIR="$arg"
            ;;
    esac
done

if [ -z "$SEGMENT_DIR" ]; then
    echo "Usage: $0 <segment-directory> [--delete] [--force]"
    echo ""
    echo "Merges legacy audio files (*_system.m4a, *_mic*_*.m4a) into a single"
    echo "multi-track *_audio.m4a file."
    echo ""
    echo "Options:"
    echo "  --delete    Delete original files after successful merge"
    echo "  --force     Overwrite existing *_audio.m4a file"
    echo ""
    echo "Examples:"
    echo "  $0 ~/captures/2024-01-15/143022_299"
    echo "  $0 ~/captures/2024-01-15/143022_299 --delete"
    echo "  $0 ~/captures/2024-01-15/143022_299 --force"
    exit 1
fi

# Resolve to absolute path
SEGMENT_DIR="$(cd "$SEGMENT_DIR" && pwd)"

# Check for existing _audio.m4a (already migrated)
if ls "$SEGMENT_DIR"/*_audio.m4a 1>/dev/null 2>&1; then
    if [ "$FORCE" = true ]; then
        echo "Removing existing audio file (--force)"
        rm -f "$SEGMENT_DIR"/*_audio.m4a
    else
        echo "Already migrated: $SEGMENT_DIR (use --force to overwrite)"
        exit 0
    fi
fi

# Find system audio file
SYSTEM_FILE="$(ls "$SEGMENT_DIR"/*_system.m4a 2>/dev/null | head -1)"
if [ -z "$SYSTEM_FILE" ]; then
    echo "No system audio found in $SEGMENT_DIR"
    exit 0
fi

# Get prefix from system file (e.g., "143022_299")
PREFIX="$(basename "$SYSTEM_FILE" | sed 's/_system\.m4a$//')"
OUTPUT="$SEGMENT_DIR/${PREFIX}_audio.m4a"

# Build arrays for inputs and maps separately
INPUTS=()
MAPS=()
INPUTS+=(-i "$SYSTEM_FILE")
MAPS+=(-map 0:a)

# Find mic files sorted by number and add to args
MIC_FILES_TO_DELETE=()
i=1
while IFS= read -r mic; do
    [ -z "$mic" ] && continue
    INPUTS+=(-i "$mic")
    MAPS+=(-map "$i:a")
    MIC_FILES_TO_DELETE+=("$mic")
    ((i++))
done < <(ls "$SEGMENT_DIR"/*_mic*_*.m4a 2>/dev/null | sort -t'_' -k3 -n || true)

# Run ffmpeg: inputs first, then maps, then output options
echo "Merging to $(basename "$OUTPUT")..."
ffmpeg -hide_banner -loglevel warning "${INPUTS[@]}" "${MAPS[@]}" -c:a aac -b:a 64k -ar 48000 -ac 1 "$OUTPUT"

echo "Created: $OUTPUT"

# Delete originals if requested
if [ "$DELETE_ORIGINALS" = true ]; then
    rm -f "$SYSTEM_FILE"
    for mic in "${MIC_FILES_TO_DELETE[@]}"; do
        rm -f "$mic"
    done
    rm -f "$SEGMENT_DIR/mics.json"
    echo "Deleted original files"
fi
