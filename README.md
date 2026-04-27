# solstone observer

solstone observer is a macOS status bar app — one of the owner's observers in the trinity, experiencing your screen and audio along with you. It takes in all connected displays at 1 FPS, records system and microphone audio in 5-minute segments (per-source M4A files remixed at segment boundaries), and automatically uploads to an observer server.

## Key Features

- Multi-display observation at 1 FPS
- Per-source audio recording (system audio + individual microphones)
- 5-minute segment rotation at clock boundaries
- Pause with timed auto-resume
- Server sync with automatic upload and retry
- Window exclusion for password managers and private browsers
- Dynamic microphone join/leave mid-segment
- Auto-start at login
- Auto-recovery from segment errors with escalating retry
- Incomplete segment recovery on startup

## Requirements

- macOS 15.0+
- **Xcode** (full IDE, not just Command Line Tools) — install from the Mac App Store
- Swift 6.1 (included with Xcode)

- Screen Recording permission
- Microphone permission
- System Audio Recording permission

## Install

```bash
git clone https://github.com/solpbc/solstone-macos.git
cd solstone-macos
make install
make setup
make install-app
```

`make install` and `make setup` both prepare the local development environment. `make install-app` builds a release binary, creates an app bundle, and installs it to `/Applications`. The app is unsigned — if macOS Gatekeeper blocks it, either right-click and choose "Open" or run:

```bash
xattr -cr /Applications/solstone.app
```

## Building and Running

- `make build` - Build both packages (debug)
- `make release` - Build both packages (release)
- `make run` - Run the app
- `make test` - Run tests
- `make bundle` - Create .app bundle
- `make install` - Install local development/build dependencies
- `make setup` - Alias for `make install`
- `make install-app` - Install the app to /Applications
- `make clean` - Clean all build artifacts
- `make reset` - Reset TCC permissions for testing

## Architecture

This is a two-package Swift Package Manager repository. **SolstoneCapture** is the app layer with the SwiftUI menu bar interface, application state, capture orchestration, segment management, upload flow, and pause controls. **SolstoneCaptureCore** is the recording layer with H.264 video encoding, per-source audio capture, multi-track audio remixing, microphone monitoring, and window filtering.

## File Storage

- Captures: `~/Library/Application Support/Solstone/captures/YYYY-MM-DD/HHMMSS_DDD/`
- Configuration: UserDefaults
- Server key: UserDefaults

## Logging

Uses macOS unified logging with subsystem `app.solstone.observer`.

```bash
# Stream logs in real-time
log stream --predicate 'subsystem == "app.solstone.observer"'

# Show recent logs (last hour)
log show --predicate 'subsystem == "app.solstone.observer"' --last 1h

# Filter by category
log stream --predicate 'subsystem == "app.solstone.observer" AND category == "upload"'
```

Or use Console.app and filter by subsystem `app.solstone.observer`.

## License

AGPL-3.0-only — Copyright (c) 2026 sol pbc
