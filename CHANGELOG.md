# Changelog

All notable changes to Solstone Capture will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Clearer local-network permission handling for LAN and Tailscale servers.
- Reliable settings-window Dock behavior and reopen handling.
- Install flow split into `make cert` plus human-run `make allow`.
