# Changelog

All notable changes to Solstone Capture will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.1] - 2026-05-24

### Fixed
- per-display segment videos now contain that display's actual pixels. earlier builds always wrote the primary display's pixels into every per-display file, so anyone running solstone on a multi-display Mac was recording the wrong screen until now.


## [1.3.0] - 2026-05-22

### Added
- you can now run sol's on-screen analysis entirely on your own Apple Silicon Mac. choose the on-device option in settings, and the part of sol that makes sense of what's on your screen runs locally, with nothing about those frames going to a cloud provider. it's opt-in, vision-only for now, and needs a Mac with at least 16 GB of memory. a one-time model download happens the first time you turn it on.
- the menu bar now tells you when sol's background pipeline has stopped and lets you restart it in place. if the pipeline goes quiet, you'll see "pipeline stopped" with a click-to-restart action, so you can recover without leaving the app.
- you can now power sol with your Anthropic or OpenAI account without installing anything separately. enable the provider in settings and paste your key, and solstone installs what it needs on its own.

### Changed
- the timeline view is rebuilt. it fits any window width, shows where each entry came from with a link to that day, and refreshes in place as new days roll up.
- long todo lists load faster. solstone now shows a focused first screen with a "show more" control, instead of rendering the entire list up front.
- pairing a phone is more reliable, and the paused state in the menu now reads "paused - 8 min left" so you can see at a glance when sol resumes.

### Fixed
- videos and audio in your journal that wouldn't play now play correctly, with a clearer message on the rare file that still can't.
- when transcription hit a dense stretch of speech it could fail outright; it now recovers on its own, and segments that did fail are surfaced instead of disappearing silently.
- pages occasionally got stuck loading on a cold start, and the paused and error menu-bar icons had lost their sun in 1.2.1. both are resolved, alongside internal stability improvements.

## [1.2.1] - 2026-05-18

### Changed
- the bundled solstone is updated. results are more consistent across AI providers, and your provider-tier defaults move to each provider's current model. nothing about how you use solstone changes.

### Fixed
- a name from your own contacts could be written into your journal as if it had appeared on your screen, when sol had little else to go on for a frame. that no longer happens.
- on a rare frame, sol could write a long run of repeated text into your journal. that output is now bounded before it's saved, and normal entries are unaffected.
- when sol fell back to its backup AI provider for a screen or document, the image wasn't reaching the provider, so the journal entry was a guess instead of grounded in what was on screen. the image now reaches every provider.
- updating solstone on a Mac that already had it installed could fail partway through. some upgrades over an existing install hit this — this resolves it, and updating now completes cleanly.


## [1.2.0] - 2026-05-17

### Added
- a plain-language data-flow page now ships with solstone. it lays out what's sent to your AI provider for each task, what stays on your machine, and the Article 8 covenant for what is never sent. linked from setup, the install guide, and the readme.
- first-run setup now walks through how to power sol: a hosted key to start, your own provider account (a developer key, not a consumer chat plan), and where local-only is headed.

### Changed
- installing solstone now happens inside settings → journal, not a separate window. pick the bundled solstone or connect to your own, see each step as it runs with a details view, and a single badge points you to whatever still needs attention. when it finishes, an "open journal dashboard" button opens it on your terms instead of a browser opening on its own.
- the menubar and settings wording now follows one model: your observers experience your day along with you, and everything goes to your journal, where sol keeps it. clearer language for what each part does. nothing about how solstone works changed.
- bundled solstone updated. fresh setup is clearer, the starting nav rail comes ready instead of blank, timezones resolve correctly on Macs, and help points to support.solstone.app.

## [1.1.3] - 2026-05-14

### Added
- Failure card now surfaces a **show-details** disclosure with the captured subprocess log (uv stderr, sol setup rendered transcript, or observer-create output) — monospaced, selectable, copyable. Diagnosing a failed install no longer requires Console.app.

### Changed
- Bundled solstone backend pinned to **0.3.2**, which makes `sol doctor` PATH-independent. Fresh-Mac installs no longer need a launchctl-PATH workaround.
- `uv tool install` now passes `--refresh` so freshly published solstone versions install reliably from the first attempt (no stale PyPI index cache).

### Fixed
- Subprocess environment inheritance: `Foundation.Process.environment = nil` did not deliver the .app's PATH to subprocesses in practice. The installer now passes `ProcessInfo.processInfo.environment` explicitly. This was the root cause of `npx_on_path` / `journal_sync` / `port_5015_free` doctor failures in earlier installer builds.

## [1.1.2] - 2026-05-04

### Added
- Updates tab anchored with current version + last-checked line, and surfaces auto-update preferences.
- Polished DMG window layout via create-dmg (brand background, window bounds, icon positions).

### Changed
- Settings switched from `TabView` to `NavigationSplitView` for a native-feeling sidebar.
- Menu-bar icons now ship as vector PDF templates — crisp at any density.
- `SettingsView` seeds its selected tab from init for snapshot stability; snapshot frame widened.

### Fixed
- Menu-bar icons load from the nested SwiftPM `Resources/` subdirectory.
- `UpdatesTabView` no longer shows a duplicate transient block while checking.

## [1.1.1] - 2026-04-29

### Fixed
- `sol-mac` maps a stale-socket connect failure to `app_not_running` cleanly.

## [1.1.0] - 2026-04-28

### Added
- In-app update support with an Updates tab and menu-bar "check for updates".
- Sparkle-based signed update feed integration.
- `sol-mac` IPC over a unix domain socket, including the locked `Codable` wire schema in `SolstoneCore`, the app-side `NWListener` service, and the hidden `_internal-ping` round-trip command.
- `StatusInfo.screenRecordingGranted` and `StatusInfo.microphoneGranted` (additive optional fields) so `sol-mac diagnose` and `sol-mac status` surface real TCC grants over IPC instead of "unknown".

### Changed
- Distribution builds are now packaged as signed, notarized DMGs suitable for direct install outside the App Store.
- `AppState.reloadConfigFromDisk()` is now the cross-process fast path for config reloads.

### Fixed
- Release builds now use the production Sparkle signing key.
- Signing checks are idempotent across fresh SSH sessions by resetting the session keychain search list.

## [1.0.0] - 2026-04-22

### Added
- Initial release of Solstone Capture.
- Continuous multi-display screen capture at 1 FPS.
- System audio plus per-microphone recording with dynamic mic join/leave.
- 5-minute segment rotation, pause with auto-resume, observer sync/retry, startup recovery, and privacy window exclusion.

### Changed
- H.264 recording for browser compatibility.
- Day-based local cache retention instead of size-based cleanup.

### Fixed
- Fresh-install start-at-login registration.
- Clearer local-network permission handling for journals reachable over LAN or Tailscale.
- Reliable settings-window Dock behavior and reopen handling.
- Install flow split into `make cert` plus human-run `make allow`.
