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

## 6. Device Pinning with AUHAL

AUHAL (HAL Output Audio Unit) pins directly to hardware. Default input route switches do not touch pinned units. `AudioDeviceID` is ephemeral: `ExternalMicCapture.startCapture()` resolves the selected UID to a fresh ID via a fresh device enumeration before each native start or recovery attempt. If that UID is unavailable, report failure instead of binding an obsolete ID or a similarly named source. Interfaces with more than two inputs record only the specific channel chosen by the user, while mono and stereo interfaces downmix through the standard converter.

**Setup order** (see `NativeMicrophoneCaptureEngine.start()`):

1. Instantiate AUHAL unit (`kAudioUnitType_Output`, `kAudioUnitSubType_HALOutput`, `kAudioUnitManufacturer_Apple`)
2. `open()`: initializes the component instance
3. Enable IO on bus 1 (input) and disable IO on bus 0 (output)
4. **Pin** via `AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, size)`: yes, "Output" in the name works for input devices
5. **Readback check**: read `kAudioOutputUnitProperty_CurrentDevice` back to confirm CoreAudio bound the intended device
6. Format negotiation: query hardware ASBD, set bus 1 client format to Float32 non-interleaved matching hardware rate and channel count
7. Set render callback on bus 1 via `kAudioOutputUnitProperty_SetInputCallback`
8. `initialize()`: prepares the unit for rendering
9. `start()`: starts capturing audio

**Teardown order**:
Always stop the unit before disposing: `unit.stop()` first, then `unit.dispose()`. Never retain more than one parked unit whose dispose failed (`maximumUndisposedInputUnits = 1`).

**Selected-device listeners and config-change recovery**:
Instead of listening to global default-device changes, `ExternalMicCapture` registers `HALPropertyListener` instances on the pinned device for `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyStreamConfiguration`, and `kAudioDevicePropertyNominalSampleRate`. Routing changes to system default input or output do not disrupt pinned captures. When a device property changes or the device is replaced in `handleDeviceChange`, the capture rebinds or re-resolves on the private `writerQueue`. Unaccepted audio and converter history are revoked across choice or layout drift without dropping writer destinations.

## 7. Edge Cases

- **Unavailable format**: a reported nominal rate is not the unit's actual stream format. Query stream format directly from the unit and validate matching sample rates and channel counts.
- **UID changes**: refresh the device list and require selection of the available UID. Do not fall back to a matching name/transport and silently change the selected source.
- **Aggregate device pollution**: voice processing creates `CADefaultDeviceAggregate-*` in device list. Filter by prefix.
- **`hasInputChannels` bounds**: validate the header, actual returned extent and checked flexible-array count before traversal. A zero-channel configuration is valid and has no input; malformed data is a diagnostic failure.
- **`kAudioOutputUnitProperty_CurrentDevice`**: the name says "Output" but works for input. The canonical way to pin an AUHAL unit to a device.
- **Listener fallback cleanup**: `deinit` may call `invalidate()`, but primary cleanup belongs at deterministic stop.
- **Fresh address for removal**: `HALPropertyListener` rebuilds `AudioObjectPropertyAddress` for removal from stored selector/scope/element.
