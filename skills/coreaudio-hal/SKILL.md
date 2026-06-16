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

**Config change recovery:** `.AVAudioEngineConfigurationChange` fires when the default device changes — even for pinned engines. Must tear down (stop engine, remove tap via ObjCExceptionCatcher, clear cached converters) and re-run the full pinning sequence. Use an `isRecovering` flag to prevent recursive recovery.

## 7. Edge Cases

- **Sample rate on disconnected devices** — returns 0 or garbage. Default to 48000: `getDeviceSampleRate(id) ?? 48000.0`
- **Bluetooth UID instability** — some devices generate new UID on reconnect. Track by name + transport type as fallback.
- **Aggregate device pollution** — voice processing creates `CADefaultDeviceAggregate-*` in device list. Filter by prefix.
- **`hasInputChannels` guard** — check `dataSize > 0` before dereferencing `AudioBufferList`. Zero means no streams.
- **`kAudioOutputUnitProperty_CurrentDevice`** — the name says "Output" but works for input. Only way to pin `AVAudioEngine` to a device.
- **Listener fallback cleanup** — `deinit` may call `invalidate()`, but primary cleanup belongs at deterministic stop.
- **Fresh address for removal** — `HALPropertyListener` rebuilds `AudioObjectPropertyAddress` for removal from stored selector/scope/element.
