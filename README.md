<img src="docs/static/sol-wordmark.svg" alt="solstone" width="300">

# The solstone app for mac

The solstone app runs on your mac.

## About

This repository contains the native Swift menu-bar app for mac. The journal is a separate app and download. Your journal is always private, only yours: it lives on your devices. [The privacy policy](https://solpbc.org/privacy) sets out the narrow data handling for optional hosted services. Install it on the computer where you choose to keep your journal: <https://solstone.app/download/journal>.

## Install

For most people, download the app from <https://solstone.app/download/macos> and follow its first-run setup.

## Build from source

Build from source when you need to modify the app.

### Prerequisites

- [mac, version 15 or later](Package.swift#L10)
- [The full Xcode app](Makefile#L298) with [Swift 6.1 or later](Package.swift#L1)
- Open Xcode once and complete its first-run setup before building.

```bash
git clone https://github.com/solpbc/solstone-macos.git
cd solstone-macos
make bundle-adhoc
make run
```

These Make targets build a local test app. They do not build or bundle the journal. Use [the local test build guide](docs/local-test-build.md) for its local-signing and verification details.

## Development commands

- `make bundle-adhoc`: Build the local test app.
- `make run`: Launch `solstone.app` and stream logs; run it after `make bundle-adhoc`.
- `make build`: Compile a debug build without assembling an app bundle.
- `make test`: Run the Swift tests.
- `make ci`: Run the full project gate.
- `make icons`: Regenerate app assets when you change their SVG sources.
- `make clean`: Remove build artifacts.

## Permissions

mac presents permission prompts for what you choose to share. The relevant settings include Screen & System Audio Recording and Microphone.

## Architecture

This is one Swift Package Manager repository. `solstone` is the app executable, `solstone-watchdog` is its helper, and shared code lives alongside them in the package. See [Package.swift](Package.swift) for the target graph.

## Local files

- Material waiting to reach your journal: `~/Library/Application Support/Solstone/captures/YYYY-MM-DD/HHMMSS_DDD/`
- App configuration: UserDefaults

## Logging

The app uses mac unified logging with subsystem `app.solstone.observer`.

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
