---
name: macos-app-lifecycle
description: >
  macOS app lifecycle patterns for background recording apps. MenuBarExtra, TCC permissions
  for screen recording and microphone, login items, graceful shutdown, configuration,
  and direct distribution packaging. Use when working with app structure, permissions,
  or distribution.
---

## MenuBarExtra Architecture

`SolstoneCaptureApp.swift` — status bar app, no dock icon, no main window.

- **`.menuBarExtraStyle(.menu)`** — standard dropdown (vs `.window` for detachable popover). Label renders `StatusIcon`, which derives `MenubarPresentation` from `AppState.menubarPresentation(durableUpdateStatus:)` and draws `MenubarIconGlyphView` with bundled template PDF assets plus an optional badge.
- **`LSUIElement = true`** in Info.plist hides from Dock and Cmd-Tab.
- **`Window` scene alongside MenuBarExtra** — Settings window with ID `"settings"`, opened via `@Environment(\.openWindow)`. Needs `NSApp.activate(ignoringOtherApps: true)` because menu bar apps don't take focus.
- **`@NSApplicationDelegateAdaptor`** — bridges to `AppDelegate` for `applicationWillTerminate`. SwiftUI Scene has no shutdown hook.
- **`@State private var appState = AppState()`** — root state, passed as parameter to all views (not `@EnvironmentObject`).

## TCC Permissions for Recording

### Info.plist usage descriptions

All four declared in `Sources/SolstoneCapture/Info.plist`:

| Key | Trigger |
|-----|---------|
| `NSScreenCaptureUsageDescription` | First `SCStream` capture request |
| `NSMicrophoneUsageDescription` | First `AVAudioEngine` input access |
| `NSSystemAudioRecordingUsageDescription` | System audio capture via SCStream |
| `NSSpeechRecognitionUsageDescription` | `SoundAnalysis` request |

### How permissions work

**Screen recording:** No `requestAccess()`. Prompts on first `SCShareableContent.current` or `SCStream.startCapture()`. Grant in System Settings > Privacy & Security > Screen Recording. May need app restart. `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()` exist but aren't used.

**Microphone:** Prompts on first `AVAudioEngine` input access. No restart needed.

**System audio / Speech recognition:** Prompted via framework calls. Plist keys required.

### Error handling

Permission denied surfaces as framework errors (SCStream/AVAudioEngine fails), caught in `CaptureManager.startRecording()`, set on `AppState.errorMessage`. No specific "permission denied" type — catch the framework error.

**Revoked while running:** Stream silently produces black/empty frames. Health checks detect anomalies and surface state changes.

### Testing

```bash
make reset-permissions  # tccutil reset ScreenCapture/Microphone for app.solstone.observer
tccutil reset All app.solstone.observer  # reset everything
```

Restart app after reset to re-trigger dialogs.

## Login Items

Uses `SMAppService` in `AppState.swift`:

- **`SMAppService.mainApp.register()`** / **`.unregister()`** — throws on failure.
- **`.status`** — `.enabled`, `.notFound`, or `.requiresApproval` (user hasn't approved in System Settings > General > Login Items).
- Status may not update immediately after `register()` — macOS processes asynchronously. Code refreshes after both success and error.
- UI toggle uses `Binding(get:set:)` calling `appState.setLoginItemEnabled(_:)`.

## Graceful Shutdown

Two shutdown paths:

**Menu quit** (`MenuContent.swift`): `await appState.stopRecording()` then `NSApplication.shared.terminate(nil)`. Completes current segment and flushes writers.

**AppDelegate** (`applicationWillTerminate`): Waits for RemixQueue to drain. Semaphore-based because the delegate method is synchronous.

- **`ProcessInfo.beginActivity(options: [.suddenTerminationDisabled, .automaticTerminationDisabled])`** — prevents macOS from SIGKILL during logout/shutdown while remix completes.
- **`DispatchSemaphore.wait(timeout: .now() + 30)`** — 30s safety net. If remix hangs, exit anyway.
- **`setOnSegmentComplete(nil)`** — clears upload-trigger callback before final processing to avoid sync during shutdown.
- **`Task.detached`** — required because `applicationWillTerminate` is nonisolated and `RemixQueue` is an actor.

## Configuration Persistence

`AppConfig.swift` — struct with `save()`/`load()` methods.

**UserDefaults:** All settings including server key. Complex types (`microphonePriority: [MicrophoneEntry]`, `excludedApps: [AppEntry]`) are JSON-encoded to `Data` before storing.

**Auto-saving:** SettingsView uses `Binding(get:set:)` that calls `appState.updateConfig()` on every set — updates in-memory state, propagates to managers, persists.

**JSON migration:** `loadOrCreateDefault()` checks `~/Library/Application Support/Solstone/config.json` and `~/.sck-cli.json` on first launch, migrates to UserDefaults, renames old file to `.migrated`.

## Direct Distribution Packaging

```bash
make release-universal                    # arm64 + x86_64
make bundle-dist                          # signed universal .app with hardened runtime

# Sign with hardened runtime (required for notarization)
codesign --deep --force --options runtime \
    --sign "Developer ID Application: <Team> (<ID>)" SolstoneCapture.app

# Notarize + staple
xcrun notarytool submit SolstoneCapture.app \
    --apple-id dev@example.com --team-id XXXXXXXXXX \
    --password @keychain:AC_PASSWORD --wait
xcrun stapler staple SolstoneCapture.app

# Package as DMG (-format UDZO = zlib compressed)
hdiutil create -volname "solstone observer" \
    -srcfolder SolstoneCapture.app -ov -format UDZO SolstoneCapture.dmg

# DMG must be signed + notarized + stapled separately
codesign --sign "Developer ID Application: <Team> (<ID>)" SolstoneCapture.dmg
xcrun notarytool submit SolstoneCapture.dmg ... --wait
xcrun stapler staple SolstoneCapture.dmg
```

For sandboxed builds, pass `--entitlements` with `com.apple.security.device.audio-input`. Currently non-sandboxed — TCC handles microphone access directly.

## @Observable State Flow

- **`@Observable @MainActor`** on `AppState`, `PauseManager`, `AudioDeviceMonitor`, `UploadCoordinator`. Rule: if it drives SwiftUI views or uses `Timer.scheduledTimer`, it's `@MainActor @Observable`.
- **`@Bindable var appState`** in views for custom `Binding` creation. `Binding(get:set:)` with side effects is the standard pattern — `set` copies config struct, mutates, calls `appState.updateConfig()`.
- **Timer-driven refresh:** `PauseManager.refreshTick` incremented every 1s. Views reference it (`let _ = appState.pauseManager.refreshTick`) to force re-render for countdown. Timer `tolerance = 0.5` reduces energy impact.
- **Parameter passing, not environment:** `appState` passed as init parameter, not `@EnvironmentObject`.

## Reference Files

All under `Sources/solstone/`: `SolstoneCaptureApp.swift` (entry, MenuBarExtra, AppDelegate), `AppState.swift` (root state, login items), `MenuContent.swift` (menu, quit handler), `SettingsView.swift` (tabs, Bindings, auto-save), `PauseManager.swift` (pause state, timer refresh), `AppConfig.swift` (UserDefaults, migration), `Info.plist` (LSUIElement, TCC descriptions). `Makefile` at package root.
