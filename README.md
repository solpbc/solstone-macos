# Solstone Capture

Solstone Capture is a macOS status bar app for continuous screen and audio recording. It captures all connected displays at 1 FPS, records system and microphone audio in 5-minute segments, and automatically uploads to a remote server.

## Key Features

- Multi-display capture at 1 FPS
- Per-source audio recording (system audio + individual microphones)
- 5-minute segment rotation at clock boundaries
- Audio and video mute with timed unmute
- Server sync with automatic upload and retry
- Window exclusion for password managers and private browsers
- Dynamic microphone join/leave mid-segment
- Auto-start at login
- Auto-recovery from capture errors with escalating retry
- Incomplete segment recovery on startup

## Requirements

- macOS 15.0+
- Swift 6.1
- Swift Package Manager

- Screen Recording permission
- Microphone permission
- System Audio Recording permission

## Building and Running

- `make build` - Build both packages (debug)
- `make release` - Build both packages (release)
- `make run` - Run the app
- `make test` - Run tests
- `make bundle` - Create .app bundle
- `make install` - Install to /Applications
- `make clean` - Clean all build artifacts
- `make reset-permissions` - Reset TCC permissions for testing

## Architecture

This is a two-package Swift Package Manager repository. **SolstoneCapture** is the app layer with the SwiftUI menu bar interface, application state, capture orchestration, segment management, upload flow, and mute controls. **SolstoneCaptureCore** is the recording layer with HEVC video encoding, per-source audio capture, multi-track audio remixing, microphone monitoring, and window filtering.

## File Storage

- Captures: `~/Library/Application Support/Solstone/captures/YYYY-MM-DD/HHMMSS_DDD/`
- Configuration: UserDefaults
- Server key: Keychain

## Logging

Uses macOS unified logging with subsystem `com.solstone.capture`.

```bash
# Stream logs in real-time
log stream --predicate 'subsystem == "com.solstone.capture"'

# Show recent logs (last hour)
log show --predicate 'subsystem == "com.solstone.capture"' --last 1h

# Filter by category
log stream --predicate 'subsystem == "com.solstone.capture" AND category == "upload"'
```

Or use Console.app and filter by subsystem `com.solstone.capture`.

## License

AGPL-3.0-only — Copyright (c) 2026 sol pbc
