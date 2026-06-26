---
name: coreaudio-hal
description: >
  CoreAudio Hardware Abstraction Layer patterns for macOS audio device management.
  Device enumeration, property listeners, device pinning, transport types, and
  lifecycle monitoring. Use when working with AudioObjectPropertyAddress, device
  IDs, or microphone management.
---

# CoreAudio HAL Patterns

CoreAudio HAL is a C-level property-query API. You never "open" a device — you query properties on object IDs. These patterns are from solstone-macos production code.

**Source files:** `MicrophoneMonitor.swift` (enumeration, properties), `AudioDeviceMonitor.swift` (device list observation), `CaptureManager.swift` (default mic listener), `ExternalMicCapture.swift` (device pinning), `ObjCExceptionCatcher.m` (exception bridge).

## 1. HAL API Fundamentals

Every query follows: build `AudioObjectPropertyAddress` -> get data size -> allocate -> get data.

```swift
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var dataSize: UInt32 = 0
AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
// allocate buffer...
AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &buffer)
```

**Scopes:** `kAudioObjectPropertyScopeGlobal` for device-level props; `kAudioDevicePropertyScopeInput` for input-specific (stream config, channels). **Element:** Always `kAudioObjectPropertyElementMain`. All functions return `OSStatus` (`noErr` = success).

## 2. Device Enumeration

Query `kAudioHardwarePropertyDevices` on `AudioObjectID(kAudioObjectSystemObject)` -> array of `AudioDeviceID`. Buffer math: `dataSize / MemoryLayout<AudioDeviceID>.size`.

**Filter to inputs** via `kAudioDevicePropertyStreamConfiguration` with input scope — check `dataSize > 0` before dereferencing, then `bufferList.mNumberBuffers > 0`. See `hasInputChannels()` in `MicrophoneMonitor.swift`.

**Exclude aggregate devices:** Voice processing creates `CADefaultDeviceAggregate-*` — filter by name prefix.

**Default input:** `kAudioHardwarePropertyDefaultInputDevice` on system object -> single `AudioDeviceID`. Check `!= kAudioDeviceUnknown`.

## 3. Property Listeners

Use `HALPropertyListener` as the single wrapper for `AudioObjectAddPropertyListenerBlock` and `AudioObjectRemovePropertyListenerBlock`. Do not add direct call sites elsewhere.

**Critical rules:**

1. **Use a private serial off-main queue** — never `DispatchQueue.main`, never a concurrent/global queue.
2. **Remove with the same queue and same block reference used for add** — HAL matches on object ID, address, queue identity, and block identity.
3. **Invalidate at deterministic stop** — call `invalidate()` when the owning service stops; `deinit` is a fallback only.
4. **Hop to `@MainActor` inside the handler** — owner callbacks are `@MainActor`, and owners should capture `[weak self]`.
5. **Rebuild the address for removal** — store selector/scope/element and construct a fresh `AudioObjectPropertyAddress`.

**Deadlock avoided:** `AudioObjectRemovePropertyListenerBlock` synchronously drains in-flight listener blocks under the HAL's CAGuard; if those blocks are dispatched to the main queue and removal also runs on main, the drain waits on main while main waits on the drain -> deadlock (observed beachball when an iPhone Continuity mic is connected).

**Common targets:**
- `kAudioHardwarePropertyDevices` on system object — device added/removed (`AudioDeviceMonitor`)
- `kAudioHardwarePropertyDefaultInputDevice` on system object — default mic changed (`CaptureManager`)

## 4. Device Properties

| Selector | Swift Type | Notes |
|----------|-----------|-------|
| `kAudioDevicePropertyDeviceNameCFString` | `Unmanaged<CFString>?` | `takeRetainedValue()` or leak |
| `kAudioDevicePropertyDeviceUID` | `Unmanaged<CFString>?` | Persistent across reboots (usually) |
| `kAudioDevicePropertyDeviceManufacturerCFString` | `Unmanaged<CFString>?` | `takeRetainedValue()` |
| `kAudioDevicePropertyNominalSampleRate` | `Float64` | 0 on disconnected devices |
| `kAudioDevicePropertyTransportType` | `UInt32` | See transport map below |
| `kAudioDevicePropertyStreamConfiguration` | `AudioBufferList` | Variable size — query first |
| `kAudioDevicePropertyDeviceIsAlive` | `UInt32` | 1 = connected, 0 = gone |

**CFString pattern:** Declare `var name: Unmanaged<CFString>?`, size as `MemoryLayout<Unmanaged<CFString>?>.size`, then `name?.takeRetainedValue()` to transfer ownership. Bridges to `String` automatically.

## 5. Transport Types

`kAudioDevicePropertyTransportType` -> `UInt32`. Key constants: `BuiltIn`, `USB`, `Bluetooth`/`BluetoothLE` (both map to bluetooth), `Aggregate`, `Virtual`, `Thunderbolt`, `FireWire`, `PCI`, `DisplayPort`, `AVB`, `AirPlay`, `HDMI`, `ContinuityCaptureWired`, `ContinuityCaptureWireless`. All prefixed `kAudioDeviceTransportType`. See `AudioTransportType` enum in `MicrophoneMonitor.swift` for the full switch.

## 6. Device Pinning with AVAudioEngine

`AVAudioEngine` follows the system default input. When AirPods connect and become default, **every** engine silently switches. You must pin each engine to its target device.

**Order matters** (see `ExternalMicCapture.startCapture()`):

1. Access `engine.inputNode` to initialize
2. **Pin** via `AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, size)` — yes, "Output" in the name works for input devices
3. `engine.prepare()` — syncs hardware state
4. Read format with `inputNode.inputFormat(forBus: 0)` — NOT `outputFormat` which returns cached values
5. `installTap(onBus:bufferSize:format:)` using the **hardware format** — wrong format causes "sampleRate == inputHWFormat.sampleRate" crash
6. `engine.start()` — must be last

**ObjC exception catching:** `installTap` and `removeTap` can throw ObjC exceptions (not Swift errors). Wrap in `ObjCExceptionCatcher.try { }` — a minimal ObjC `@try/@catch` that converts `NSException` to `NSError`. Swift cannot catch ObjC exceptions.

**Teardown order matters too — and getting it wrong is a HARD DEADLOCK, not a crash.** The teardown is the mirror of startup: **`engine.stop()` FIRST, THEN `removeTap(onBus:)`.** `removeTap` on a *still-running* engine reconfigures the AUHAL output unit (`-[AUHALOutputUnit setInputHandler:]` → `AudioUnitSetProperty`), which grabs the CoreAudio HAL recursive_mutex. If a device change is in flight (CoreAudio's own `HALC_ShellObject_Listener` is delivering `AudioObjectPropertiesChanged` while holding that mutex and a `BindToDeviceInternal` rebind is mid-flight), you get a two-thread lock-order inversion and the whole process wedges — only `kill -9` recovers. Stopping the engine first means `removeTap` no longer drives AUHAL reconfiguration, so it never contends for the HAL mutex. Production incident: a capture **pause** (frequent + automatic — screen-lock, sleep, segment rotation) tearing the tap down while AirPods/an interface connected (1.3.23, fixed `123d9c1`).

**Confine ALL engine mutation (`start`/`stop`/`prepare`/`setInputDevice`/`installTap`/`removeTap`) to ONE private serial queue.** Never mutate the engine from the caller/main thread for `stop()` while the config-change recovery mutates it from a background queue — that is two threads into one `AVAudioEngine` and is the second front of the same deadlock. Factor `engine.stop()` + ObjC-wrapped `removeTap` into a single teardown helper, guard it with `dispatchPrecondition(condition: .onQueue(yourQueue))`, and route **both** the normal stop path and the config-change recovery through it. With everything serialized on one queue, the pause-teardown and the device-change recovery cannot run concurrently — no separate re-entrancy flag is needed beyond the existing `isRunning`/`isRecovering` guards (serialization subsumes it). See `ExternalMicCapture.teardownEngine()`.

**Config change recovery:** `.AVAudioEngineConfigurationChange` fires when the default device changes — even for pinned engines. Must tear down (stop engine, then remove tap via ObjCExceptionCatcher, clear cached converters) and re-run the full pinning sequence — all on the same serial queue. Use an `isRecovering` flag to prevent recursive recovery.

## 7. Edge Cases

- **Sample rate on disconnected devices** — returns 0 or garbage. Default to 48000: `getDeviceSampleRate(id) ?? 48000.0`
- **Bluetooth UID instability** — some devices generate new UID on reconnect. Track by name + transport type as fallback.
- **Aggregate device pollution** — voice processing creates `CADefaultDeviceAggregate-*` in device list. Filter by prefix.
- **`hasInputChannels` guard** — check `dataSize > 0` before dereferencing `AudioBufferList`. Zero means no streams.
- **`kAudioOutputUnitProperty_CurrentDevice`** — the name says "Output" but works for input. Only way to pin `AVAudioEngine` to a device.
- **Listener fallback cleanup** — `deinit` may call `invalidate()`, but primary cleanup belongs at deterministic stop.
- **Fresh address for removal** — `HALPropertyListener` rebuilds `AudioObjectPropertyAddress` for removal from stored selector/scope/element.
