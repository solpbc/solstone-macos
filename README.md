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

## The ja1r linkage gate

A production publish is fail-closed on fresh evidence from the ja1r rig: sol and
the journal are installed and upgraded together on a clean machine, and every
lane must come back green for the exact commit being published. Staging
publishes are not gated — `make publish-appcast-staging` and
`make publish-appcast-journal-staging` stay runnable before the rig has produced
any evidence at all.

The harness lives in `extro-tools` (`tools/solstone-macos-gate`), pinned to one
revision in `scripts/ja1r-gate/extro-tools.rev`. That file is the only place the
revision is written, and the sync never follows extro-tools `main`. Moving to a
newer harness is a deliberate one-line edit.

**1. Sync the rig.** Pushes the pinned harness and this exact `HEAD` to ja1r,
reads the revision marker back off the rig, and writes
`.ja1r-gate/sync-receipt.json`. It refuses to touch the rig if either checkout is
dirty or the harness is not at the pin, and it never builds, installs, resets an
app, runs a lane, or publishes.

```bash
make ja1r-gate-sync
```

**2. Run the lanes on ja1r.** The harness prints one JSON object per lane to
stdout and writes no files itself, so redirect each lane into the report file the
verifier expects, in `.ja1r-gate/reports/`:

<!-- ja1r-report-filenames:start -->
- `drag.json`
- `sparkle.json`
- `fresh-journal-first.json`
- `fresh-sol-first.json`
- `sol-upgrade.json`
- `journal-upgrade.json`
<!-- ja1r-report-filenames:end -->

```bash
# on ja1r, from ~/extro-tools/tools/solstone-macos-gate
GATE="python3 gate.py --checkout $HOME/projects/solstone-macos --expect-solstone <target-runtime-pin>"

$GATE --lane drag    --from <legacy-sol> --to <sol> --to-build <sol-build> \
                     --journal <journal> --journal-build <journal-build>   > drag.json
$GATE --lane sparkle --from <legacy-sol> --to <sol> --to-build <sol-build> \
                     --journal <journal> --journal-build <journal-build>   > sparkle.json
$GATE --lane fresh --order journal-first --to <sol> --to-build <sol-build> \
                     --journal <journal> --journal-build <journal-build>   > fresh-journal-first.json
$GATE --lane fresh --order sol-first     --to <sol> --to-build <sol-build> \
                     --journal <journal> --journal-build <journal-build>   > fresh-sol-first.json
$GATE --lane sol-upgrade --from <sol-baseline> --from-build <sol-baseline-build> \
                     --to <sol> --to-build <sol-build> \
                     --journal <journal> --journal-build <journal-build>   > sol-upgrade.json
$GATE --lane journal-upgrade --to <companion-sol> --to-build <companion-sol-build> \
                     --journal <journal-baseline> --journal-build <journal-baseline-build> \
                     --journal-to <journal> --journal-to-build <journal-build> \
                     --expect-solstone-baseline <baseline-runtime-pin> > journal-upgrade.json
```

Pass `--expect-solstone <target-runtime-pin>` on every lane. On
`journal-upgrade`, also pass `--expect-solstone-baseline <baseline-runtime-pin>`
on that lane only; the harness rejects that flag everywhere else. Without the
required pins, the harness either refuses the lane or reports a skipped
runtime-pin check, and the verifier refuses the set.

**3. Verify, then publish.** The verifier is offline and stdlib-only, so the
publish never depends on the rig being reachable. `publish-appcast` requires
`verify-ja1r-gate-sol`, and `publish-appcast-journal` requires
`verify-ja1r-gate-journal`; `verify-ja1r-gate-paired` checks all six for a joint
release. There is no opt-out.

```bash
make verify-ja1r-gate-journal \
  JA1R_GATE_SOL_VERSION=1.4.5 JA1R_GATE_SOL_BUILD=56 \
  JA1R_GATE_JOURNAL_BASELINE_VERSION=1.0.3 JA1R_GATE_JOURNAL_BASELINE_BUILD=4 \
  JA1R_GATE_LEGACY_SOL_VERSION=1.3.31 \
  JA1R_GATE_JOURNAL_RUNTIME_PIN=0.8.3 \
  JA1R_GATE_JOURNAL_BASELINE_RUNTIME_PIN=0.8.2
```

Every expected version, build, and baseline is typed in. The verifier never
reads an expected value out of the evidence it is checking, and only the app
actually being published takes its identity from its own `Info.plist` — in a
sol-only release the journal riding along is the *released* journal, not
whatever the tree happens to hold. Missing variables are listed by name before
anything is published.

What the verifier proves is narrow and deliberate: that the evidence set is
complete for the profile, that every report is a terminal `PASS` from the pinned
harness, that all six describe the exact commit being published with the right
versions and both install orders, that the AX contract scope was clean, and that
the target journal runtime pin — plus the journal-upgrade baseline runtime pin
when that lane is in profile — was genuinely enforced. The reports' own oracles
remain authoritative — this is a freshness and completeness check, so that last
release's green JSON cannot authorize this one.

One honest limit: the harness does not stamp its own revision into its reports.
The sync receipt records the revision marker read back off the rig, so a stale or
unsynced harness cannot be waved through by typing the expected hash — but the
binding is the sync's observation, not something the reports themselves carry.
The load-bearing freshness proof is the product commit and the version identities.

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
