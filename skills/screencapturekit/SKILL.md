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

Why: Recreating an SCStream with `capturesAudio = true` causes audible interference with system audio. Music stutters. Call audio drops. The stream must stay alive.

**System audio** (`SystemAudioCaptureManager.swift`): One SCStream lives for the entire recording session. `SystemAudioStreamOutput` holds a mutable `onAudioBuffer` callback. At rotation, `clearCallback()` detaches the old segment, then `setCallback()` wires to the new segment's `PerSourceAudioManager`. The stream never stops. Zero gap.

**Video** (`ScreenshotCapturer.swift`): Video streams are per-segment (recreated each rotation) because video-only SCStreams (`capturesAudio = false`) don't interfere with system audio. Each `ScreenshotCapturer` owns its own SCStream for one display.

The asymmetry is intentional. Audio needs persistence; video doesn't.

## 2. SCStream Lifecycle

Correct order from `ScreenshotCapturer.start()` and `SystemAudioCaptureManager.startStream()`:

1. **Enumerate**: `SCShareableContent.current` (async) — TCC permission checked here. Throws if denied.
2. **Filter**: `SCContentFilter(display:excludingApplications:exceptingWindows:)` — always display-based.
3. **Configure**: `SCStreamConfiguration` — set all properties before passing to init. Cannot reconfigure after creation.
4. **Create**: `SCStream(filter:configuration:delegate:)` — delegate handles `didStopWithError`.
5. **Add output**: `addStreamOutput(output, type:, sampleHandlerQueue:)` — **must** happen before `startCapture`. Type is `.screen` or `.audio`.
6. **Start**: `startCapture()` (async, throws) — permission denial or invalid config throws here.
7. **Update filter** (optional): `updateContentFilter(filter)` — changes excluded windows without restart. Not immediately after start (see section 3).
8. **Stop**: `stopCapture()` (async, throws) — handle error -3808 (see section 8).

Steps 4-6 must be this exact order. Adding output after starting is undefined. Delegate must be set at creation.

## 3. Content Filtering

**Two-layer window exclusion** (`WindowExclusionDetector` in `WindowMask.swift`):

1. `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` — titles and owner names. Only reliable way to inspect window titles; `SCWindow` doesn't expose them.
2. `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` — maps window IDs to `SCWindow` objects for `SCContentFilter`.

**Private browsing** (`isPrivateBrowserWindow()`): Safari: "Private". Chrome: "Incognito". Firefox: "Private Browsing". Case-insensitive title match.

**Dynamic updates** (`CaptureManager.swift`): 5-second polling timer (`tolerance = 2.0`). Also triggers on `didActivateApplicationNotification` / `didDeactivateApplicationNotification`. Only calls `updateContentFilter` when `Set<CGWindowID>` actually changes. Updates both video and audio streams.

**500ms stabilization delay**: After `startCapture()`, `isStreamReady` is false for 500ms. All filter updates check this flag. Without the delay, filter updates during startup fail silently or cause frame drops. See `startNewSegmentWithDirectory()`.

## 4. Frame Status Optimization

From `VideoStreamOutput` in `ScreenshotCapturer.swift`:

SCStream delivers frames at configured rate regardless of content changes. Check `SCFrameStatus` in `CMSampleBuffer` attachments:

- Call `CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)` — cast to `[[SCStreamFrameInfo: Any]]`
- Read `attachments.first?[.status] as? Int`, init `SCFrameStatus(rawValue:)`
- `.idle` = no content change. **Skip encoding.** Saves ~70% of frames in typical desktop use.
- `.complete` = new content. Encode this frame.

Must pass `createIfNecessary: false`. Passing `true` creates empty attachments — never what you want for reading. The key is `SCStreamFrameInfo.status` (typed key, not string).

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

## 7. Health Monitoring

From `SystemAudioCaptureManager.swift`. Audio streams silently stop producing buffers after sleep/wake.

- 30-second timer, 10s tolerance. `getAndResetBufferCount()` on `SystemAudioStreamOutput` (thread-safe via `NSLock`).
- 2 consecutive zero-buffer checks (60s) triggers restart. Single zero just warns.
- Restart: save callback, `stopCapture()` (handle -3808), nil references, 500ms delay, `startStream(filter:)`, restore callback.
- `SCStreamDelegate.didStopWithError` provides immediate detection for hard errors (complements the polling).

## 8. Edge Cases and Gotchas

**Error -3808**: `com.apple.ScreenCaptureKit.SCStreamErrorDomain`, code `-3808` — stream already stopped. Always catch this on `stopCapture()`. Streams can self-stop (errors, sleep) before you call stop.

**Audio-only streams need video config**: `width = 2, height = 2` minimum. Zero dimensions fail silently at stream creation.

**Queue selection**: Both video and audio outputs use `.global(qos: .userInitiated)`. Not `.main` (blocks UI with high-frequency callbacks). Not `.background` (frames delayed, timing issues).

**Weak self in callbacks**: `VideoStreamOutput` and `SystemAudioStreamOutput` hold closures referencing owners. Always `[weak self]` or `[weak manager]` to prevent retain cycles.

**SCShareableContent.current = permission check**: This is where TCC authorization is verified. Handle the throw at recording start, before any stream setup.

**500ms stabilization is load-bearing**: `isStreamReady` flag in `CaptureManager` gates all `updateContentFilter` calls. Without the delay, initial window exclusion updates fail silently.

**Concurrent rotation guard**: `isRotatingSegment` prevents overlapping rotations when display changes and timer fires race.

**`@preconcurrency import ScreenCaptureKit`**: Required. SCK types lack concurrency annotations; without it, false sendability warnings in `@MainActor` code.
