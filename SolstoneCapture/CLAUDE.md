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
  - AudioWriter - System audio capture to M4A
  - StreamOutput - SCStreamOutput protocol implementations (VideoStreamOutput, AudioStreamOutput)
  - MultiMicRecorder - Records from multiple microphones simultaneously with hot-swap rotation
  - MicrophoneInput - Individual microphone input handling via CoreAudio
  - MicAudioWriter - AAC encoding for microphone audio
  - MicrophoneMonitor - CoreAudio device enumeration and monitoring
  - SilenceDetector - Detects silent audio to discard inactive mic tracks
  - AudioRemixer - Combines system audio and mic audio into multi-track M4A
  - WindowMask - WindowExclusionDetector for filtering out specific app windows
  - Log/FileLogger - Logging utilities

## Key Features

- **Status Bar App**: No dock icon, menu bar only (LSUIElement = true)
- **5-Minute Segments**: Continuous recording split at clock boundaries (aligned to :00, :05, :10, etc.)
- **Multi-Display**: Captures all connected displays simultaneously
- **Multi-Microphone**: Records from up to 4 microphones with priority-based selection, silence detection, and per-mic disable
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

After segment completion, audio files are remixed:
- System audio and microphone audio are combined into a single `_audio.m4a` file
- For stable segments (no mic changes): 2 tracks (system + highest priority mic)
- For changed segments (mic joins/leaves): N+1 tracks (system + all active mics)
- Original individual audio files are deleted after successful remix

Configuration stored at:
```
~/Library/Application Support/Solstone/config.json
```

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
- Display changes and sleep/wake events trigger immediate segment rotation
- MultiMicRecorder persists across segments with hot-swap file rotation
- Silent mic tracks are automatically discarded to save space
