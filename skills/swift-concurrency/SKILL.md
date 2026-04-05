---
name: swift-concurrency
description: >
  Swift 6.1 strict concurrency patterns for solstone-macos. Diagnostics, isolation boundaries,
  Sendable conformance, actor patterns, and common pitfalls. Use when writing or reviewing
  concurrent code, resolving compiler errors, or making isolation decisions.
---

## Project Settings

Both packages use `swift-tools-version: 6.1`. Swift 6.1 enables strict concurrency by default — every Sendable violation, cross-isolation access, and non-sendable capture is a hard error. No explicit `swiftSettings` needed; the language version implies it.

Packages: `SolstoneCapture` (executable), `SolstoneCaptureCore` (library). macOS 15.0+, SPM build.

## Isolation Patterns

### @MainActor — UI-bound state

`AppState`, `CaptureManager`, `PauseManager`, `AudioDeviceMonitor`, `SystemAudioCaptureManager`, `StorageManager`, `UploadCoordinator` are all `@MainActor`. Rule: if it touches `@Observable`, `Timer.scheduledTimer`, or drives SwiftUI, it's `@MainActor`. Nothing else should be.

### actor — sequential background work

`RemixQueue` is the sole `actor`. Serializes CPU-heavy remix jobs via internal task queue. Its `RemixJob` is a `Sendable` struct (all value types). Use `actor` for sequential async state from multiple callers — not for UI state (`@MainActor`) or synchronous hot paths (`NSLock`).

### @unchecked Sendable — framework callback bridging

| Class | Framework constraint | Locking |
|-------|---------------------|---------|
| `ExternalMicCapture` | AVAudioEngine tap on audio render thread | NSLock + DispatchQueue |
| `MicrophoneCaptureManager` | Manages captures across isolation boundaries | NSLock on captures dict |
| `SystemAudioStreamOutput` | SCStreamOutput on arbitrary GCD queue | NSLock on counters |
| `SingleTrackAudioWriter` | Written from audio callbacks off-main | Internal serialization |
| `VideoWriter` | Screenshot capture callbacks | Internal serialization |
| `PerSourceAudioManager` | Audio writers from capture callbacks | Lock-based access |
| `DebugSettingHolder` | Read from @Sendable closures on capture threads | NSLock |
| `StreamDelegate` | SCStreamDelegate on arbitrary queue | Stateless forwarding |

**Invariant:** every `@unchecked Sendable` class protects mutable state with explicit locking. Audio callbacks are synchronous — they cannot `await`, making actor isolation impossible.

### nonisolated(unsafe) — three use cases

**1. deinit cleanup.** `deinit` is nonisolated, so `@MainActor` classes can't access their own properties. CaptureManager stores `defaultMicListenerBlock`, `screenLockedObserver`, `screenUnlockedObserver` as `nonisolated(unsafe)` for cleanup. AudioDeviceMonitor does the same with `listenerBlock`. Safe because writes happen on MainActor before deinit, and deinit runs after all references are gone.

**2. Static non-Sendable constants.** `SingleTrackAudioWriter` and `AudioRemixer` use `static nonisolated(unsafe) let audioSettings: [String: Any]` — `[String: Any]` isn't Sendable but is immutable after init.

**3. Cross-isolation atomic reads.** `AppState.shared` is `nonisolated(unsafe)` — set once during init, read from termination handlers.

### @preconcurrency imports

`@preconcurrency import ScreenCaptureKit` — SCContentFilter, SCStream, SCDisplay are not Sendable.
`@preconcurrency import AVFAudio` — AVAudioEngine, AVAudioFormat, AVAudioPCMBuffer are not Sendable.

Remove `@preconcurrency` when Apple adds conformances, to surface new issues.

## Diagnostic Reference

| Error | Fix |
|-------|-----|
| `Sending 'x' risks causing data races` | Value crosses isolation boundary. Use value type, actor method, or `@preconcurrency import` for framework types. |
| `Main actor-isolated ... cannot be used from nonisolated context` | Wrap in `Task { @MainActor in }` from callbacks, or mark caller `@MainActor`. |
| `Static property is not concurrency-safe` | Immutable: `nonisolated(unsafe)`. Mutable + UI: `@MainActor`. |
| `Capture of non-sendable type in @Sendable closure` | Make value Sendable (struct, actor, or @unchecked with locks). Framework types: `@preconcurrency import`. |
| `Call to main actor-isolated method in synchronous nonisolated context` | Happens in `deinit`. Store as `nonisolated(unsafe)`, clean up inline. Never dispatch to MainActor from deinit. |
| `Non-sendable type 'SCContentFilter' across actor boundary` | `@preconcurrency import ScreenCaptureKit`. Expected until Apple annotates. |

## When @unchecked Sendable is Acceptable

All four must be true: (1) class receives callbacks from Apple frameworks on non-main queues, (2) callbacks are synchronous and cannot `await`, (3) all mutable state protected by NSLock or DispatchQueue, (4) class is `final`. Otherwise use `actor` or `@MainActor`.

## Task Patterns

**`Task { @MainActor in }` — callback-to-main bridge.** Primary pattern for CoreAudio listeners, NotificationCenter observers, and Timer callbacks. Always capture `[weak self]`.

**`Task.sleep(nanoseconds:)` — timed delays.** Health checks, stream stabilization, retry backoff. Never `Thread.sleep` in async contexts.

**`Task.detached` — rare and intentional.** Only in `AppState.init` for fire-and-forget work that must not inherit MainActor (segment recovery, startup sync). Captures specific sendable values, not `self`. Regular `Task { }` inside `@MainActor` inherits main actor — that's usually what you want.

## Anti-patterns

- **@unchecked Sendable as first resort.** Try struct, actor, or @MainActor first. @unchecked is for framework interop only.
- **@MainActor on everything.** Audio classes (ExternalMicCapture, SingleTrackAudioWriter) must NOT be @MainActor — callbacks on audio threads would deadlock.
- **DispatchQueue for new code.** Use actor or @MainActor. Exception: `AudioObjectAddPropertyListenerBlock` requires a queue parameter.
- **Fake awaits to suppress warnings.** Fix the isolation instead.
- **`MainActor.run` where `Task { @MainActor in }` works.** MainActor.run is for async contexts needing a main block. Callbacks use the Task pattern.

## Swift 6.2 Preview

- **nonisolated async stays on caller's actor** (behavior change). Currently hops to global executor. Audit nonisolated async functions.
- **`@concurrent`** — explicit opt-in to background execution, replacing the old implicit hop.
- **`Task.immediate`** — synchronous start to first suspension. Useful for callback bridges.
- **Module-level `@MainActor` default** — reduces annotation burden but requires audit of opt-outs.

## Reference Files

See `reference/` directory for supplementary material on specific concurrency topics.
