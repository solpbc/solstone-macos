# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Solstone Capture is a macOS status bar application that provides continuous screen and audio recording. It captures all connected displays and records in 5-minute segments, with mute functionality, auto-start at login support, and automatic upload to a remote server.

## Build Commands

```bash
# Build debug version
make build

# Build release version
make release

# Build universal binary (arm64 + x86_64)
make release-universal

# Run the app (builds if needed)
make run

# Create .app bundle for distribution
make bundle

# Install to /Applications
make install

# Clean build artifacts
make clean
```

## Architecture

### Source Files (Sources/SolstoneCapture/)

- **SolstoneCaptureApp.swift** - SwiftUI app entry point with MenuBarExtra
- **AppState.swift** - Observable application state, coordinates managers
- **AppConfig.swift** - Configuration struct with persistence (server URL, mic priority, app exclusions)
- **MenuContent.swift** - SwiftUI view for the status bar dropdown menu
- **SettingsView.swift** - Settings window with Server, Microphones, and Status tabs
- **CaptureManager.swift** - Orchestrates continuous recording with segment rotation
- **SegmentWriter.swift** - Manages a single 5-minute recording segment
- **MuteManager.swift** - Tracks audio/video mute state with timed unmute
- **StorageManager.swift** - File organization and segment directory creation
- **AudioDeviceMonitor.swift** - Monitors audio device additions/removals
- **UploadService.swift** - Handles segment upload to remote server with sync, retry, and storage cleanup

### Dependencies

- **SolstoneCaptureCore** - Shared Swift package with recording components:
  - VideoWriter - HEVC hardware encoding to .mp4
  - MultiTrackAudioWriter - Multi-track M4A recording (system audio + mics)
  - MultiTrackStreamOutput - SCStreamOutput routing to MultiTrackAudioWriter
  - ExternalMicCapture - AVAudioEngine capture for all microphones
  - SilentTrackRemover - Removes silent tracks from M4A at segment end
  - SilenceDetector - RMS-based silence detection per audio track
  - MicrophoneMonitor - CoreAudio device enumeration
  - WindowMask - WindowExclusionDetector for filtering out specific app windows
  - Log/FileLogger - Logging utilities

## Key Features

- **Status Bar App**: No dock icon, menu bar only (LSUIElement = true)
- **5-Minute Segments**: Continuous recording split at clock boundaries (aligned to :00, :05, :10, etc.)
- **Multi-Display**: Captures all connected displays simultaneously
- **Multi-Track Audio**: Records to single M4A with tracks for system audio and each microphone
- **Mic Change Detection**: Segment rotation triggers when enabled mics connect/disconnect
- **Silent Track Removal**: Empty mic tracks automatically removed at segment end
- **Mute Controls**: Separate audio/video mute with timed auto-unmute
- **Auto-Start**: SMAppService integration for login item support
- **Window Exclusion**: Filters out specified apps (e.g., password managers) and private browser windows
- **Segment Upload**: Full sync with remote server, retry logic, and configurable local storage retention

## File Organization

Segments are stored in:
```
~/Library/Application Support/Solstone/captures/
└── YYYY-MM-DD/
    └── HHMMSS_DDD/                              # Start time + actual duration in seconds
        ├── HHMMSS_DDD_display_<id>_screen.mp4   # One per display (HEVC)
        └── HHMMSS_DDD_audio.m4a                 # Multi-track: system audio + mic(s)
```

Audio is recorded directly to a single multi-track M4A:
- Track 0: System audio (always present, via SCStream)
- Track 1+: All microphones (via AVAudioEngine/ExternalMicCapture)
- Silent mic tracks are removed at segment end

Configuration stored in UserDefaults (standard macOS preferences).
Server API key stored securely in Keychain.

## Technical Details

- **Platform**: macOS 15.0+ required
- **Swift**: 6.1 with strict concurrency
- **Video**: HEVC in .mp4 container, 1 FPS
- **System Audio**: AAC in M4A, 48kHz, mono
- **Microphone Audio**: AAC in M4A at native device sample rate
- **Frameworks**: ScreenCaptureKit, AVFoundation, ServiceManagement, CoreAudio

## Permissions Required

- Screen Recording (System Settings > Privacy & Security)
- Microphone Access
- System Audio Recording

## Development Notes

- The app uses @Observable (macOS 14+ Observation framework)
- MainActor isolation is used for UI-related state
- SCDisplay is not Sendable, so DisplayInfo struct is used for cross-actor communication
- Segment rotation happens automatically at 5-minute clock boundaries
- Display changes, sleep/wake events, and mic connect/disconnect trigger immediate segment rotation
- MultiTrackAudioWriter records all audio sources to a single M4A file
- SilentTrackRemover re-encodes to remove empty mic tracks at segment end
