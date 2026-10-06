---
name: screencapturekit
description: >
  ScreenCaptureKit patterns for continuous screen and audio capture on macOS.
  Persistent streams, content filtering, frame status optimization, segment rotation,
  and health monitoring. Use when working with SCStream, SCContentFilter, or display capture.
---

# ScreenCaptureKit Patterns

Continuous 1fps screen + system audio capture in solstone-macos. macOS 15.0+.

## 1. Architecture: Persistent Streams

**The core design decision: SCStream instances survive segment rotations. Only output callbacks change.**

Why: Recreating an SCStream with `capturesAudio = true` causes audible interference with system audio. Music stutters. Call audio drops. Preserve it across normal rotations where possible; confirmed interruption and terminal stop have separate recovery policies.

**System audio** (`SystemAudioCaptureManager.swift`): One SCStream lives for the entire recording session. `SystemAudioStreamOutput` holds a mutable `onAudioBuffer` callback. At rotation, `clearCallback()` detaches the old segment, then `setCallback()` wires to the new segment's `PerSourceAudioManager`. Normal rotation keeps the transport alive. Callback detachment/attachment can leave a capture interval; persistence does not guarantee zero gaps. Production destinations copy/admit bounded PCM promptly and execute native writer calls outside the output routing lock.

**Video** (`ScreenshotCapturer.swift`): Video streams are per-segment (recreated each rotation) because video-only SCStreams (`capturesAudio = false`) don't interfere with system audio. Each `ScreenshotCapturer` owns its own SCStream for one display.

The asymmetry is intentional. Audio needs persistence; video doesn't.

## 2. SCStream Lifecycle

Correct order from `ScreenshotCapturer.start()` and `SystemAudioCaptureManager.startStream()`:

1. **Enumerate**: `SCShareableContent.current` (async): TCC permission checked here. Throws if denied.
2. **Filter**: `SCContentFilter(display:excludingApplications:exceptingWindows:)`: always display-based.
3. **Configure**: `SCStreamConfiguration`: set initial properties before init. [updateConfiguration](https://developer.apple.com/documentation/screencapturekit/scstream/updateconfiguration(_:)) can later change configuration asynchronously and can throw; creation-time configuration is not immutable.
4. **Create**: `SCStream(filter:configuration:delegate:)`: delegate handles `didStopWithError`.
5. **Add output**: `addStreamOutput(output, type:, sampleHandlerQueue:)` before `startCapture` in this implementation. Type is `.screen` or `.audio`.
6. **Start**: `startCapture()` (async, throws): permission denial or invalid config throws here.
7. **Update filter** (optional): `updateContentFilter(filter)`: changes excluded windows without restart. Not immediately after start (see section 3).
8. **Stop**: `stopCapture()` (async, throws): handle error -3808 (see section 8).

This implementation adds outputs before starting. The delegate is supplied at creation.

## 3. Content Filtering

**Apps kept out, chosen windows let back in** (`WindowExclusionManager`, `ExclusionPlanner` in `WindowExclusionPlan.swift`). The capture filter is always `SCContentFilter(display:excludingApplications:exceptingWindows:)`. A window of an excluded application that is not in `exceptingWindows` is never captured, including one created after the filter was applied; measured on macOS 27 at 1 FPS, a new private window of a kept-out browser reached 0 frames. That is the property everything below relies on.

1. `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` gives titles, owner names, pids and layers.
2. `ExclusionPlanner.plan(...)` decides which pids are kept out and which window ids are let back in:
   - excluded apps: kept out, nothing let back;
   - a held browser: kept out, each layer-0 window let back once it reads ordinary, windows above the page (menus, tooltips) let back;
   - an app with a title-pattern window: kept out, its other windows let back.
3. `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` maps pids to `SCRunningApplication` and ids to `SCWindow`. Use `false`, so an excluded app that has no window on screen yet is still listed and kept out.

**Private browsing.** It is matched per browser in `PrivateBrowser`, and only on forms measured on macOS 27 in English:
- **Firefox:** a case-sensitive suffix on the window title, `" \u{2014} Private Browsing"`. An ordinary Firefox window shows the bare page title, so a page whose own title ends that way is matched too.
- **Safari, Chrome, Edge and Brave:** they show only the page title in `kCGWindowName`. Their private mark is in the Accessibility title (`kAXTitleAttribute`), read by `AccessibilityTitleReader` and paired to the capture window by `_AXUIElementGetWindow`. A window is private only when its Accessibility title equals its window title plus the browser's own tail (`" - Google Chrome (Incognito)"`, `", Private Browsing"`, …). A page that titles itself with the tail reads the same text in both titles, so it is never matched.
- **When this runs:** only when the owner turns on the setting's second level, and only while a real read works. `AXIsProcessTrusted()` goes stale in a running process in both directions, so never gate on it.
- **Holding windows:** a new window of a held browser stays out until it is decided, at most `ExclusionPlanner.holdLimit` (2 s), and is then let in and still re-checked. Accessibility verdicts are cached per window, because a window's private mode never changes.

**Every segment starts excluded.** Video streams are per segment, so `CaptureManager` asks `filtersForNewSegment` for the start filter. ⛔ Never start a segment's stream with the nothing-excluded base filter and update it afterwards: the first frame lands before any update, and it kept excluded apps and private windows.

**Dynamic updates:** a 1 s tick (`tolerance = 0.25`), plus app launch, activate and deactivate notifications. `updateContentFilter` runs only when the plan changes. **Video only:** the system-audio stream keeps the display's base filter, because keeping an application out of the audio filter would silence that app's audio.

**500ms stabilization delay**: after `startCapture()`, `isStreamReady` is false for 500ms, and every filter *update* checks this flag. Without it, updates during startup fail silently or drop frames. The start filter is not an update, so a segment is excluded from its first frame regardless.

## 4. Frame Status Optimization

From `VideoStreamOutput` in `ScreenshotCapturer.swift`:

SCStream delivers frames at configured rate regardless of content changes. Check `SCFrameStatus` in `CMSampleBuffer` attachments:

- Call `CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)`: cast to `[[SCStreamFrameInfo: Any]]`
- Read `attachments.first?[.status] as? Int`, init `SCFrameStatus(rawValue:)`
- `.idle` = no content change. **Skip encoding.**
- `.complete` = new content. Encode this frame.

Must pass `createIfNecessary: false`. Passing `true` creates empty attachments: never what you want for reading. The key is `SCStreamFrameInfo.status` (typed key, not string).

## 5. Audio Capture via SCStream

From `SystemAudioCaptureManager.startStream()`. System audio captured through SCStream, separate from mic capture (AVAudioEngine).

Config: `sampleRate = 48_000`, `channelCount = 1`, `capturesAudio = true`, `captureMicrophone = false`, `width = 2`, `height = 2`, `queueDepth = 1`, `minimumFrameInterval = CMTime(value: 1, timescale: 1)`.

- **width/height = 2**: Minimum valid video dimensions. Even audio-only SCStreams require valid video config. Zero or 1 fails silently.
- **captureMicrophone = false**: All mic capture via `MicrophoneCaptureManager` (AVAudioEngine) for per-device gain control.
- **48kHz**: Standardized across all sources for remix compatibility.
- **queueDepth = 1**: Minimize buffered video frames we'll discard anyway.
- **Output type `.audio` only**: Stream still produces video internally but frames are discarded by `SystemAudioStreamOutput`.

## 6. Display Change Detection

From `CaptureManager.swift`: Listen for `NSApplication.didChangeScreenParametersNotification`. On change: call `SCShareableContent.current`, compare `Set(displays.map { $0.displayID })`. If different: create new `SCContentFilter` with new primary display, call `rotateSegment()`.

**SCContentFilter is display-scoped.** A filter for display A cannot be reused on display B. New display = new filter = new segment.

Sleep/wake: `willSleepNotification` / `didWakeNotification`. On wake: wait up to 5s for audio devices, refresh displays, new filter, fresh segment. Lock/unlock: `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed notifications, same pattern.

## 7. Continuity and Recovery

`SystemAudioCaptureManager` distinguishes a requested session, a started native transport and acknowledged current PCM. A successful start alone does not prove restored audio.

- `liveRestartListenerFactory` observes HAL service restart through `HALPropertyListener`. `handleServiceRestart()` fences/re-registers that listener, records a confirmed interruption, retires the transport and coalesces current-session recovery. [didStopWithError](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate/stream(_:didstopwitherror:)) also records current-transport interruption.
- `setCallback()` replays unresolved failure across segment changes. Valid current PCM acknowledgement, qualified by stream generation and interruption revision, clears that transport fault for future segments; already recorded segment failures remain. Acknowledgement tasks are coalesced.
- A 30-second timer with 10-second tolerance reads the locked buffer count. Two empty checks can trigger fallback rebuilding, but unknown playback activity does not prove lost speech or create a confirmed interruption. Timer timing is approximate.
- `restartStream()` admits at most three recovery attempts until current PCM or a new explicit request resets the budget. Quiet successful starts cannot renew it. Generations fence every asynchronous start/reset result and the selected filter.
- `cleanupRetiredTransport()` retains unknown native cleanup ownership and blocks overlapping replacement. Known already-stopped cleanup is handled separately. Stop timeout is not cancellation or permission to forget a native stream.
- Permission denial and the owner choosing Stop Sharing end session admission. Health ticks and HAL notifications cannot automatically resurrect that stopped session.

Persistent system audio and per-segment video remain separate policies. None of these mechanisms guarantees continuous PCM during device/OS interruption.

## 8. Edge Cases and Gotchas

**Error -3808**: `com.apple.ScreenCaptureKit.SCStreamErrorDomain`, code `-3808`: stream already stopped. Always catch this on `stopCapture()`. Streams can self-stop (errors, sleep) before you call stop.

**Audio-only streams need video config**: `width = 2, height = 2` minimum. Zero dimensions fail silently at stream creation.

**Queue selection**: Both video and audio outputs use `.global(qos: .userInitiated)`. Not `.main` (blocks UI with high-frequency callbacks). Not `.background` (frames delayed, timing issues).

**Weak self in callbacks**: `VideoStreamOutput` and `SystemAudioStreamOutput` hold closures referencing owners. Always `[weak self]` or `[weak manager]` to prevent retain cycles.

**SCShareableContent.current = permission check**: This is where TCC authorization is verified. Handle the throw at recording start, before any stream setup.

**500ms stabilization is load-bearing**: `isStreamReady` in `WindowExclusionManager` gates every `updateContentFilter` call. Without the delay, updates made during startup fail silently. That is why the start filter carries the exclusions.

**Concurrent rotation guard**: `isRotatingSegment` prevents overlapping rotations when display changes and timer fires race.

**`@preconcurrency import ScreenCaptureKit`**: Required. SCK types lack concurrency annotations; without it, false sendability warnings in `@MainActor` code.
