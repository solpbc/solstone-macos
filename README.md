<img src="docs/static/sol-wordmark.svg" alt="solstone" width="300">

# The solstone app for macos

The solstone app runs on your mac. It takes in what you choose to share with it, and all of it goes into your journal.

## About

This repository contains the native Swift menu-bar app for macos. The journal is a separate app and download. Install it on the computer where you choose to keep your journal: <https://solstone.app/download/journal>.

## Install

For most people, install the signed and notarized DMG from <https://solstone.app/download/macos>. It installs the solstone app, opens first-run setup, and updates over a signed channel.

## Build from source

Build from source when you need to modify the app. Use [the local test build guide](docs/local-test-build.md) for the supported public path.

```bash
git clone https://github.com/solpbc/solstone-macos.git
cd solstone-macos
make install
make build
make test
make run
```

## Development commands

- `make build`: Build both packages (debug)
- `make run`: Launch `solstone.app` from the source tree and stream logs
- `make test`: Run tests
- `make ci`: Run Swift and Python tests
- `make install`: Install local development and build dependencies
- `make setup`: Alias for `make install`
- `make clean`: Clean all build artifacts

## Permissions

macos presents the permission prompts needed for the material you choose to share. The relevant settings include Screen Recording, Microphone, and System Audio Recording.

## Architecture

This is one Swift Package Manager repository. Production targets are `SolstoneCore`, `solstone` (the executable app and recording layer in `Sources/solstone/`), `solstone-watchdog`, and `ObjCHelpers`; SPL tunnel code comes from the shared `spl-swift` package. Test targets are `solstoneTests`.

## File storage

- Intake segments: `~/Library/Application Support/Solstone/captures/YYYY-MM-DD/HHMMSS_DDD/`
- Configuration: UserDefaults
- Journal key: UserDefaults

## Logging

Uses macos unified logging with subsystem `app.solstone.observer`.

```bash
# Stream logs in real time
log stream --predicate 'subsystem == "app.solstone.observer"'

# Show recent logs (last hour)
log show --predicate 'subsystem == "app.solstone.observer"' --last 1h

# Filter by category
log stream --predicate 'subsystem == "app.solstone.observer" AND category == "upload"'
```

Or use Console.app and filter by subsystem `app.solstone.observer`.

## License

AGPL-3.0-only. Copyright (c) 2026 sol pbc.
