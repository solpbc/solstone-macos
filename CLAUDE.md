# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

solstone observer is a macOS status bar application — one of the owner's observers, experiencing screen and audio along with the owner on macOS. It pairs with the owner's journal; sol is the keeper who lives in and tends that journal. It takes in all connected displays at 1 FPS and system/microphone audio in 5-minute segments (per-source M4A files remixed at segment boundaries), supports pause, and uploads automatically to the owner's journal.

## Build Commands

```bash
# Build the package (debug)
make build

# Build the signed .app bundle (Developer ID + hardened runtime + bundled uv/python)
make bundle-dist

# Launch solstone.app from the source tree and stream logs (requires bundle-dist first)
make run

# Run tests
make test

# Full CI gate (terminology + Swift tests + Python tests)
make ci

# Install local development/build dependencies
make install
make setup

# Clean all build artifacts
make clean

# Reset TCC permissions and defaults for testing
make reset

# Build signed + notarized + stapled DMG (release pipeline)
make release-dmg
```

Signing uses the sol pbc Developer ID identities in the sol-signing keychain. There is no self-signed dev cert.

## Repository Structure

This is a single-package Swift repository using Swift Package Manager with Swift 6.1 and requiring macOS 15.0+.

- **Sources/solstone/** - All Swift source files (app layer + recording engine)
- **Sources/ObjCHelpers/** - Objective-C exception catcher target
- **Tests/solstoneTests/** - All test files

## Architecture

### Sources/solstone/
- **SolstoneCaptureApp.swift** - SwiftUI entry point with MenuBarExtra
- **AppState.swift** - Observable application state, coordinates all managers
- **CaptureManager.swift** - Orchestrates continuous recording with segment rotation
- **SegmentWriter.swift** - Manages individual 5-minute recording segments
- **PerSourceAudioManager.swift** - Manages per-source audio writers, handles dynamic mic join/leave
- **UploadService.swift** - Handles segment upload with sync and retry logic
- **PauseManager.swift** - Tracks pause state with timed auto-resume
- **StorageManager.swift** - File organization and segment directory creation
- **AudioDeviceMonitor.swift** - Monitors audio device additions/removals
- **VideoWriter** - H.264 hardware encoding to .mp4
- **SingleTrackAudioWriter** - Single-source M4A recording with timing metadata
- **AudioRemixer** - Combines individual M4A files into multi-track output with silence detection
- **SystemAudioStreamOutput** - SCStreamOutput routing system audio to SingleTrackAudioWriter
- **ExternalMicCapture** - AVAudioEngine capture for all microphones
- **MicrophoneMonitor** - CoreAudio device enumeration
- **WindowMask** - Filters out specific app windows from capture

## Key Design Patterns

- **5-Minute Segments**: Recording splits at clock boundaries (:00, :05, :10, etc.)
- **Multi-Display**: Observes all connected displays simultaneously
- **Per-Source Audio Files**: Each audio source (system + mics) records to individual M4A during segment
- **Dynamic Mic Join/Leave**: Mics can connect/disconnect mid-segment without rotation
- **Audio Remix on Segment End**: Individual M4A files combined into single multi-track output
- **Timing Offset Tracking**: Each source tracks start/end time for proper remix alignment
- **Silent Track Detection**: RMS-based silence detection during remix, silent tracks skipped
- **Window Exclusion**: Filters out password managers and private browser windows

## File Paths

Segments: `~/Library/Application Support/Solstone/captures/YYYY-MM-DD/HHMMSS_DDD/`
Config: UserDefaults (standard macOS preferences storage)
Server Key: UserDefaults

## Technical Notes

- Uses @Observable (macOS 14+ Observation framework)
- MainActor isolation for UI-related state
- SCDisplay is not Sendable; DisplayInfo struct used for cross-actor communication
- Segment rotation triggers on display changes and sleep/wake events (NOT mic changes)
- Audio sources write to individual M4A files during segment, remixed at end
- Interleaved track reading during remix ensures AVAssetWriter receives data from all tracks together
- Silent mic tracks automatically detected via RMS analysis and skipped during remix

## Logging

Uses macOS unified logging (`os.Logger`) with subsystem `app.solstone.observer`. Categories: `general`, `capture`, `audio`, `upload`, `setup`, `storage`. See the `live-logging` skill for full details.

```bash
# Stream logs in real-time (use full path — fish has a `log` builtin)
/usr/bin/log stream --predicate 'subsystem == "app.solstone.observer"' --level debug

# Filter by category
/usr/bin/log stream --predicate 'subsystem == "app.solstone.observer" AND category == "audio"' --level debug
```

## Skills

Specialized knowledge packs in `skills/`, symlinked from `.claude/skills/` and `.agents/skills/`. Each contains a `SKILL.md` with codebase-grounded patterns and optional `reference/` files for supplementary material.

| Skill | When to use |
|-------|------------|
| `swift-concurrency` | Writing or reviewing concurrent code, resolving strict concurrency compiler errors, making isolation decisions (@MainActor vs actor vs @unchecked Sendable) |
| `screencapturekit` | Working with SCStream, SCContentFilter, display capture, system audio capture, or frame status optimization |
| `coreaudio-hal` | Working with AudioObjectPropertyAddress, device enumeration, property listeners, device pinning, or transport types |
| `av-media-pipeline` | Working with H.264 encoding, AVAssetWriter, AVAudioEngine, audio format conversion, the remix pipeline, or SoundAnalysis |
| `macos-app-lifecycle` | Working with MenuBarExtra, TCC permissions, login items, graceful shutdown, configuration, or DMG packaging |
| `live-logging` | Debugging the running app with log stream, adding log statements, Logger categories, privacy annotations, or troubleshooting logging issues |

## Brand

- System-anatomy canon has two registers; do not collapse them. Owner-facing copy says solstone-macos is **one of the owner's observers** in the two-part owner model (`observers + journal`), and **sol is the keeper** who lives in and tends the journal. Never enumerate a three-part "trinity" or `observers + sol agent + journal` in owner-visible copy. Co-experience voice uses `experience along with`, `observe alongside`, and `take in`; banned surveillance verbs in owner-visible copy are `watch`, `capture`, `record`, `monitor`, `track`, and `collect`.
- Architecture/engineering register: the system is `observers + sol agent + journal`. Use that register only in architecture statements, technical notes, code paths, and developer guidance. Branded surfaces (UI strings, README/INSTALL prose, log messages owners see) follow the owner-facing register; code identifiers (`CaptureManager`, the `captures/` directory, the `capture` log category, `app.solstone.observer`, Swift class/method names) stay verbatim — `capture` remains a code-only word here.
- Boundary examples: Apple permission proper-names that point the owner at System Settings/TCC, accessibility labels/hints, and log-only `Logger.*` strings stay in their own registers and are not rewritten as owner copy.
- Follow lowercase-first UI copy in visible product text.
- Exceptions are limited to HIG cancel/destructive labels, `accessibilityHint` / `accessibilityLabel`, third-party proper nouns, OS-required path strings (e.g. `Application Support/Solstone/...`), protocol and URL literals, and AM/PM or date abbreviations.
- Sync vendored brand SVGs with `make brand-sync` (writes into `assets/`).
- The brand source directory is kept outside this repo; set `BRAND_DIR=/path/to/brand make brand-sync` to point at it.
- `Sources/solstone/Resources/Assets.xcassets/AccentColor.colorset/` carries canonical `solOrange` (`#E8923A`) for the mark accent. `#B06A1A` is orange ink for text, links, and focus rings only; do not use it for the mark.
- Render PNGs from the SVG sources via `make icons` — never downsample a larger PNG. Per-size hand-tuned variants live alongside the canonical (`assets/icon-app-16.svg`, `assets/icon-app-32.svg`).
- Data covenants: no analytics, no tracking, no telemetry, no phone-home — see sol pbc charter.


## Engineering Principles

sol pbc's coding standards, distilled — inlined because a coding agent working
in this repo can't read the private org standards.

- **Honest state, always earned.** Never render an "observing" / "uploaded" / "ok" state unless the durable fact is true; derive presentation from the authoritative lifecycle and fail closed on unknown. Green is the hardest state to display.
- **Fail clearly, never silently.** Surface capture / upload / permission failures via `os.Logger` at the right category; never swallow an error into a success-looking path. A liveness-dependent wait (notarization, archive, codesign) needs a timeout — a hung process fires no completion signal.
- **Shared protocols are code, not prose.** When a token / identifier vocabulary is consumed by 2+ systems (e.g. the AX / automation token set this app emits to a test harness), it must be a generated, committed, drift-gated artifact from one Swift source of truth — not a hand-maintained prose table that can drift out of sync with what the app emits.
- **KISS / YAGNI.** Add background modes, fallbacks, and lifecycle scaffolding only when a concrete scenario requires it. No speculative machinery; no backwards-compatibility shims — update call sites directly.
- **Verify before you claim.** ScreenCaptureKit / CoreAudio / AVFoundation behavior is verified against the live API and real hardware, not recalled, before it lands in code or a commit.
