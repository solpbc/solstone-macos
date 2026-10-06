---
name: coreaudio-hal
description: >
  CoreAudio Hardware Abstraction Layer patterns for macOS audio device management.
  Device enumeration, property listeners, device pinning, transport types, and
  lifecycle monitoring. Use when working with AudioObjectPropertyAddress, device
  IDs, or microphone management.
---

# CoreAudio HAL Patterns

CoreAudio HAL is a C-level property-query API. You never "open" a device: you query properties on object IDs. These patterns are from solstone-macos production code.

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

**Filter to inputs** with `kAudioDevicePropertyStreamConfiguration` and input scope. `MicrophoneMonitor.hasInputChannels()` queries the size and allocates at least the queried capacity and `MemoryLayout<AudioBufferList>.size`. It keeps capacity separate from returned bytes, validates the flexible-array header and checked count-times-stride extent against those returned bytes, and checks for any buffer with positive channels. A valid zero-buffer header means no input. Buffer count alone does not establish input channels; the fixed struct size alone cannot hold an aggregate layout. Only `kAudioHardwareBadPropertySizeError` triggers a bounded re-query, with at most three attempts. Other errors and malformed extents produce diagnostics and return false. See Apple’s [property size query](https://developer.apple.com/documentation/coreaudio/audioobjectgetpropertydatasize) and [AudioBufferList](https://developer.apple.com/documentation/coreaudiotypes/audiobufferlist).

**Exclude aggregate devices:** Voice processing creates `CADefaultDeviceAggregate-*`: filter by name prefix.

**Default input:** `kAudioHardwarePropertyDefaultInputDevice` on system object -> single `AudioDeviceID`. Check `!= kAudioDeviceUnknown`.

## 3. Property Listeners

Use `HALPropertyListener` as the single wrapper for `AudioObjectAddPropertyListenerBlock` and `AudioObjectRemovePropertyListenerBlock`. Do not add direct call sites elsewhere.

**Critical rules:**

1. **Use a private serial off-main queue**: never `DispatchQueue.main`, never a concurrent/global queue.
2. **Remove with the same queue and same block reference used for add**: HAL matches on object ID, address, queue identity, and block identity.
3. **Invalidate at deterministic stop**: call `invalidate()` when the owning service stops; `deinit` is a fallback only.
4. **Hop to `@MainActor` inside the handler**: owner callbacks are `@MainActor`, and owners should capture `[weak self]`.
5. **Rebuild the address for removal**: store selector/scope/element and construct a fresh `AudioObjectPropertyAddress`.

**Deadlock avoided:** `AudioObjectRemovePropertyListenerBlock` synchronously drains in-flight listener blocks under the HAL's CAGuard; if those blocks are dispatched to the main queue and removal also runs on main, the drain waits on main while main waits on the drain -> deadlock (observed beachball when an iPhone Continuity mic is connected).

**Common targets:**
- `kAudioHardwarePropertyDevices` on system object: device added/removed (`AudioDeviceMonitor`)
- `kAudioHardwarePropertyDefaultInputDevice` on system object: default mic changed (`CaptureManager`)
- `kAudioHardwarePropertyServiceRestarted` on system object: HAL restarted (`SystemAudioCaptureManager.liveRestartListenerFactory`)

Listener registration, callback admission and invalidation retain their current owner/revision fences. A queued callback from an invalidated listener cannot rebuild a replacement recording session. Device selection uses UID; the native ID is resolved again before each bind.

## 4. Device Properties

| Selector | Swift Type | Notes |
|----------|-----------|-------|
| `kAudioDevicePropertyDeviceNameCFString` | `Unmanaged<CFString>?` | `takeRetainedValue()` or leak |
| `kAudioDevicePropertyDeviceUID` | `Unmanaged<CFString>?` | Persistent across reboots (usually) |
| `kAudioDevicePropertyDeviceManufacturerCFString` | `Unmanaged<CFString>?` | `takeRetainedValue()` |
| `kAudioDevicePropertyNominalSampleRate` | `Float64` | 0 on disconnected devices |
| `kAudioDevicePropertyTransportType` | `UInt32` | See transport map below |
| `kAudioDevicePropertyStreamConfiguration` | `AudioBufferList` | Variable size: query first |
| `kAudioDevicePropertyDeviceIsAlive` | `UInt32` | 1 = connected, 0 = gone |

**CFString pattern:** Declare `var name: Unmanaged<CFString>?`, size as `MemoryLayout<Unmanaged<CFString>?>.size`, then `name?.takeRetainedValue()` to transfer ownership. Bridges to `String` automatically.

## 5. Transport Types

`kAudioDevicePropertyTransportType` -> `UInt32`. Key constants: `BuiltIn`, `USB`, `Bluetooth`/`BluetoothLE` (both map to bluetooth), `Aggregate`, `Virtual`, `Thunderbolt`, `FireWire`, `PCI`, `DisplayPort`, `AVB`, `AirPlay`, `HDMI`, `ContinuityCaptureWired`, `ContinuityCaptureWireless`. All prefixed `kAudioDeviceTransportType`. See `AudioTransportType` enum in `MicrophoneMonitor.swift` for the full switch.

## 6. Device Pinning with AVAudioEngine

`AVAudioEngine` can follow the system default input. Pin each engine to the selected device. `AudioDeviceID` is ephemeral: `ExternalMicCapture.startCapture()` resolves the selected UID to a fresh ID before each native start or recovery attempt. If that UID is unavailable, report failure instead of binding an obsolete ID or a similarly named source.

**Order matters** (see `ExternalMicCapture.startCapture()`):

1. Access `engine.inputNode` to initialize
2. **Pin** via `AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, size)`: yes, "Output" in the name works for input devices
3. `engine.prepare()`: syncs hardware state
4. Read format with `inputNode.inputFormat(forBus: 0)`: NOT `outputFormat` which returns cached values
5. `installTap(onBus:bufferSize:format:)` using the **hardware format**: wrong format causes "sampleRate == inputHWFormat.sampleRate" crash
6. `engine.start()`: must be last

**ObjC exception catching:** `installTap` and `removeTap` can throw ObjC exceptions (not Swift errors). Wrap in `ObjCExceptionCatcher.try { }`: a minimal ObjC `@try/@catch` that converts `NSException` to `NSError`. Swift cannot catch ObjC exceptions.

**Teardown order matters too: the running-engine teardown path caused an observed deadlock.** The teardown is the mirror of startup: **`engine.stop()` FIRST, THEN `removeTap(onBus:)`.** `removeTap` on a *still-running* engine reconfigures the AUHAL output unit (`-[AUHALOutputUnit setInputHandler:]` → `AudioUnitSetProperty`), which grabs the CoreAudio HAL recursive_mutex. If a device change is in flight (CoreAudio's own `HALC_ShellObject_Listener` is delivering `AudioObjectPropertiesChanged` while holding that mutex and a `BindToDeviceInternal` rebind is mid-flight), you get a two-thread lock-order inversion and the whole process wedges. Stopping the engine before removing the tap avoids the observed running-engine teardown path. Production incident: a capture **pause** (frequent + automatic: screen-lock, sleep, segment rotation) tearing the tap down while AirPods/an interface connected (1.3.23, fixed `123d9c1`).

**Confine ALL engine mutation (`start`/`stop`/`prepare`/`setInputDevice`/`installTap`/`removeTap`) to ONE private serial queue.** Never mutate the engine from the caller/main thread for `stop()` while the config-change recovery mutates it from a background queue: that is two threads into one `AVAudioEngine` and is the second front of the same deadlock. Factor `engine.stop()` + ObjC-wrapped `removeTap` into a single teardown helper, guard it with `dispatchPrecondition(condition: .onQueue(yourQueue))`, and route **both** the normal stop path and the config-change recovery through it. Serial execution prevents concurrent engine mutation, but does not coalesce notifications admitted before queued work begins. `ExternalMicCapture.handleConfigChange()` admits recovery under `callbackLock`, checks the active engine and requested epoch, and permits one recovery batch. The private queue then checks that request before each fresh engine/UID bind. The three-attempt batch parks after exhaustion; a newer explicit request has its own admission. See `teardownEngine()` and `handleConfigChange()`.

**Config change recovery:** [AVAudioEngineConfigurationChange](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchange) can accompany routing/format changes, including pinned engines. Admit and coalesce the current engine/request before queueing. Stop before removing the tap, create a fresh engine, resolve the UID again and repeat the pinning sequence on the same private queue. Already admitted PCM retains its destination and processing epoch. Drain a genuine old converter boundary before reset; selection revision revocation still rejects media that has not crossed its authorized writer admission.

## 7. Edge Cases

- **Unavailable format**: a reported nominal rate is not the tap’s actual format. Resolve the selected UID, prepare the engine and use valid `inputFormat(forBus:)`. Do not start a tap from a guessed 48kHz hardware format.
- **UID changes**: refresh the device list and require selection of the available UID. Do not fall back to a matching name/transport and silently change the selected source.
- **Aggregate device pollution**: voice processing creates `CADefaultDeviceAggregate-*` in device list. Filter by prefix.
- **`hasInputChannels` bounds**: validate the header, actual returned extent and checked flexible-array count before traversal. A zero-channel configuration is valid and has no input; malformed data is a diagnostic failure.
- **`kAudioOutputUnitProperty_CurrentDevice`**: the name says "Output" but works for input. Only way to pin `AVAudioEngine` to a device.
- **Listener fallback cleanup**: `deinit` may call `invalidate()`, but primary cleanup belongs at deterministic stop.
- **Fresh address for removal**: `HALPropertyListener` rebuilds `AudioObjectPropertyAddress` for removal from stored selector/scope/element.
