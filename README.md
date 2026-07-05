# solstone observer

solstone observer is a macOS status bar app — one of your observers, experiencing your screen and audio along with you. It takes in all connected displays at 1 FPS, plus system and microphone audio in 5-minute segments (per-source M4A files remixed at segment boundaries), then syncs to your journal automatically.

## Key Features

- Multi-display observation at 1 FPS
- Per-source audio: system audio + individual microphones
- 5-minute segment rotation at clock boundaries
- Pause with timed auto-resume
- Journal sync with automatic upload and retry
- Diagnostics-only observer health beacon on the existing journal heartbeat
- Window exclusion for password managers and private browsers
- Dynamic microphone join/leave mid-segment
- Auto-start at login
- Auto-recovery from segment errors with escalating retry
- Incomplete segment recovery on startup

The health beacon carries operational sync state only. It intentionally excludes screen/audio content and local segment file paths; journal-side ingest rejections are a separate health source from the journal.

## Requirements

- macOS 15.0+
- **Xcode** (full IDE, not just Command Line Tools) — install from the Mac App Store
- Swift 6.1 (included with Xcode)

- Screen Recording permission
- Microphone permission
- System Audio Recording permission

## Install

end users: install the signed + notarized DMG from <https://solstone.app/download/macos>. it installs the native observer and journal, opens the first-run wizard, and updates over a signed channel.

Source build (requires sol pbc Apple Developer Program identities in the local keychain):

```bash
git clone https://github.com/solpbc/solstone-macos.git
cd solstone-macos
make install         # dev dependencies (Xcode check, optional librsvg)
make bundle-dist     # produce signed solstone.app without the journal runtime
make bundle-dist-journal # produce signed journal.app with bundled runtime
make run             # launch solstone.app from the source tree + stream logs
```

`make bundle-dist` signs under `Developer ID Application: sol pbc (7QCG8V4M6H)` with hardened runtime. Without those identities the build fails at `signing-check`; install the DMG instead.

## Building and Running

- `make build` - Build both packages (debug)
- `make release` - Build both packages (release)
- `make bundle-dist` - Build the signed sol .app bundle without the journal runtime (Developer ID + hardened runtime)
- `make bundle-dist-journal` - Build the signed journal .app bundle with bundled runtime
- `make run` - Launch `solstone.app` from the source tree and stream logs
- `make test` - Run tests
- `make ci` - Run terminology + Swift tests + Python tests
- `make install` - Install local development/build dependencies
- `make setup` - Alias for `make install`
- `make clean` - Clean all build artifacts
- `make reset` - Reset TCC permissions for testing
- `make release-dmg` - Build signed + notarized + stapled sol DMG (`sol-<version>.dmg`)
- `make release-dmg-journal` - Build signed + notarized + stapled journal DMG
- `make release-dmg-both` - Build signed + notarized + stapled sol + journal DMGs

## Architecture

This is one Swift Package Manager repository. Production targets are `SolstoneCore`, `SPLTunnel`, `solstone` (the executable app and recording layer in `Sources/solstone/`), `solstone-watchdog`, and `ObjCHelpers`. Test targets are `solstoneTests` and `SPLTunnelTests`.

## File Storage

- Captures: `~/Library/Application Support/Solstone/captures/YYYY-MM-DD/HHMMSS_DDD/`
- Configuration: UserDefaults
- Journal key: UserDefaults

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
