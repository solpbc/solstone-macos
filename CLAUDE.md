# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Solstone Capture is a macOS status bar application for continuous screen and audio recording. It captures all connected displays at 1 FPS and records system/microphone audio in 5-minute segments, with pause functionality and automatic upload to an observer server.

## Build Commands

```bash
# Build the package (debug)
make build

# Build release
make release

# Run the app
make run

# Run tests
make test

# Create .app bundle
make bundle

# Install to /Applications
make install

# Clean all build artifacts
make clean

# Reset TCC permissions and defaults for testing
make reset
```

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
- **VideoWriter** - HEVC hardware encoding to .mp4
- **SingleTrackAudioWriter** - Single-source M4A recording with timing metadata
- **AudioRemixer** - Combines individual M4A files into multi-track output with silence detection
- **SystemAudioStreamOutput** - SCStreamOutput routing system audio to SingleTrackAudioWriter
- **ExternalMicCapture** - AVAudioEngine capture for all microphones
- **MicrophoneMonitor** - CoreAudio device enumeration
- **WindowMask** - Filters out specific app windows from capture

## Key Design Patterns

- **5-Minute Segments**: Recording splits at clock boundaries (:00, :05, :10, etc.)
- **Multi-Display**: Captures all connected displays simultaneously
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
| `av-media-pipeline` | Working with HEVC encoding, AVAssetWriter, AVAudioEngine, audio format conversion, the remix pipeline, or SoundAnalysis |
| `macos-app-lifecycle` | Working with MenuBarExtra, TCC permissions, login items, graceful shutdown, configuration, or DMG packaging |
| `live-logging` | Debugging the running app with log stream, adding log statements, Logger categories, privacy annotations, or troubleshooting logging issues |
