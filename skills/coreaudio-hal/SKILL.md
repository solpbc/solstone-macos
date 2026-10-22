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
- `kAudioHardwarePropertyDefaultInputDevice` on system object: default input device. Persistent microphone capture does not listen to it.
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

AUHAL (HAL Output Audio Unit) pins directly to hardware. Pinning does not make capture immune to every route change: the selected device can still disappear, change format, or change its observable input layout, and those events need a fresh resolution. `AudioDeviceID` is ephemeral: `ExternalMicCapture.startCapture()` resolves the selected UID with a successful fresh lookup before each native start or recovery attempt. A cached device list is not proof the device is present. If that UID is unavailable, report failure instead of binding an obsolete ID or a similarly named source. Interfaces with more than two inputs record only the specific channel chosen by the user. Mono and stereo interfaces downmix through the standard converter unless a saved layout fingerprint no longer matches, in which case they wait for a new choice.

**Setup order** (see `NativeMicrophoneCaptureEngine.start()`):

1. Instantiate AUHAL unit (`kAudioUnitType_Output`, `kAudioUnitSubType_HALOutput`, `kAudioUnitManufacturer_Apple`)
2. `open()`: initializes the component instance
3. Enable IO on bus 1 (input) and disable IO on bus 0 (output)
4. **Pin** via `AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, size)`: yes, "Output" in the name works for input devices
5. **Readback check**: read `kAudioOutputUnitProperty_CurrentDevice` back and require the returned size to be an `AudioDeviceID`
6. Format negotiation: query the hardware ASBD on input scope bus 1, then set the client format on output scope bus 1 to Float32 non-interleaved matching the hardware rate and channel count
7. Register the input callback with `kAudioOutputUnitProperty_SetInputCallback` on **global scope, element 0**. The callback refcon is a retained context, not the engine. Render uses bus 1
8. `initialize()` then `start()`, both with delivery still closed. Either may invoke the callback synchronously
9. Read back the bound device and the **output-scope bus-1 client format** after start, including property sizes and the supported buffer slice. Open admission only after those match

**Teardown order**:
Close delivery, wait until every callback path is idle, then `stop`, then `uninitialize`, then `dispose`. Keep the native handle and the callback context when any of those fails, including an early startup failure. A nil handle is success only after dispose has already succeeded. While a persistent UID still has an unresolved owner, do not allocate a replacement. If the idle wait expires, keep the owner rather than uninitializing a live render.

**Selected-device listeners and config-change recovery**:
`ExternalMicCapture` registers `HALPropertyListener` instances on the pinned device for `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyStreamConfiguration`, and `kAudioDevicePropertyNominalSampleRate`. A pinned aggregate also listens for `kAudioAggregateDevicePropertyFullSubDeviceList` and `kAudioAggregateDevicePropertyActiveSubDeviceList`. An in-place member reorder notifies those list properties and does not notify stream configuration. That notification stops admitting the previous ordinal immediately. It does not listen for system default input or output changes. A default-route change alone does not restart a healthy pinned capture, and it also does not promise that the selected device itself will keep working. Selected-device loss and that device's format change ask for a fresh engine. Layout drift, including a same-count member reorder or a multichannel interface that becomes stereo, revokes unaccepted audio and stops that capture without a capture-failure report and without rotating the segment. The writer for audio already accepted stays. Unaccepted audio and converter history do not cross a choice change.

## 7. Edge Cases

- **Unavailable format**: a reported nominal rate is not the unit's actual stream format. Query stream format directly from the unit and validate matching sample rates and channel counts.
- **UID changes**: refresh the device list and require selection of the available UID. Do not fall back to a matching name/transport and silently change the selected source.
- **Aggregate device pollution**: voice processing creates `CADefaultDeviceAggregate-*` in device list. Filter by prefix.
- **`hasInputChannels` bounds**: validate the header, actual returned extent and checked flexible-array count before traversal. A zero-channel configuration is valid and has no input; malformed data is a diagnostic failure.
- **`kAudioOutputUnitProperty_CurrentDevice`**: the name says "Output" but works for input. The canonical way to pin an AUHAL unit to a device.
- **Listener fallback cleanup**: `deinit` may call `invalidate()`, but primary cleanup belongs at deterministic stop.
- **Fresh address for removal**: `HALPropertyListener` rebuilds `AudioObjectPropertyAddress` for removal from stored selector/scope/element.
