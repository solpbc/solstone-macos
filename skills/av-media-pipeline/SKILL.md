---
name: av-media-pipeline
description: >
  AVFoundation media pipeline for HEVC video encoding, multi-track audio recording,
  and intelligent audio remixing. Covers AVAssetWriter, AVAudioEngine, AudioRemixer,
  SoundAnalysis, and CMTime patterns. Use when working with video/audio recording,
  encoding, format conversion, or the remix pipeline.
---

## HEVC Video Encoding

`VideoWriter` wraps AVAssetWriter for 1fps screen capture to `.mp4`. Source: `SolstoneCaptureCore/.../VideoWriter.swift`, `SolstoneCapture/.../ScreenshotCapturer.swift`

- **Codec:** `AVVideoCodecType.hevc` (hardware-accelerated). BT.709 color. Frame reordering disabled.
- **Pixel format:** `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` — native HEVC encoder format. SCStream delivers this directly, no CPU color conversion.
- **Keyframe interval: 90s.** Both `AVVideoMaxKeyFrameIntervalKey` and `AVVideoMaxKeyFrameIntervalDurationKey` set to 90. At 1fps = ~3-4 keyframes per 5-min segment. Maximizes P-frame compression for mostly-static screens. Tradeoff: corruption loses up to 90s.
- **Fragment interval: 30s.** `movieFragmentInterval = CMTime(seconds: 30, preferredTimescale: 1)` — fragmented MP4 for crash resilience. Without this, crash corrupts entire file. With it, lose at most 30s.
- **Frame flow:** SCStream callback -> skip idle frames (`SCFrameStatus == .idle`) -> `VideoWriter.appendFrame(pixelBuffer, presentationTime:)` -> check `isReadyForMoreMediaData`, drop if not ready. PTS from `Date().timeIntervalSince(captureStartTime)` at timescale 600.

## Persistent AVAudioEngine

`MicrophoneCaptureManager` keeps `ExternalMicCapture` instances (each wrapping `AVAudioEngine`) alive across segment rotations. Only the `onAudioBuffer` callback changes. Source: `SolstoneCaptureCore/.../ExternalMicCapture.swift`, `SolstoneCapture/.../MicrophoneCaptureManager.swift`

**Why:** Stopping/restarting AVAudioEngine causes audible clicks/pops in system audio playback during segment rotation. Persistent engines eliminate this.

**Callback swapping:** `onAudioBuffer` is NSLock-protected. At rotation: `clearAllCallbacks()` (nil = discard), then `setCallback(for:callback:)` wires to new segment's writer.

**Hardware format detection — critical ordering:**
1. Access `engine.inputNode` (triggers initialization)
2. `setInputDevice()` — pin via `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice`
3. `engine.prepare()` (acquires hardware)
4. Read `inputNode.inputFormat(forBus: 0)` — actual hardware format
5. Install tap with hardware format
6. `engine.start()`

**Never use `outputFormat(forBus: 0)`** — returns cached/default values, causes crash on format mismatch.

**Device pinning:** Without it, AVAudioEngine follows system default. AirPods connect -> all unpinned engines silently switch. Pin via `AudioUnitSetProperty` on `engine.inputNode.audioUnit`.

**Config change:** `.AVAudioEngineConfigurationChange` fires on routing changes. Handler: stop, remove tap, clear converter, re-run startup. `isRecovering` flag prevents recursion.

**Gain:** `gainMultiplier` is `Float` (atomic on Apple platforms). Applied via `vDSP_vsmul` + `vDSP_vclip` (SIMD). Range 1.0-8.0.

**Converter caching:** `AVAudioConverter` is expensive to create. Cached in `cachedConverter`, reused across buffers, recreated only on format change.

## Per-Source Audio Architecture

Each audio source records to its own M4A during a segment. `PerSourceAudioManager` orchestrates `SingleTrackAudioWriter` instances. Source: `SolstoneCapture/.../PerSourceAudioManager.swift`, `SolstoneCaptureCore/.../SingleTrackAudioWriter.swift`

**Why individual files:** (1) No lock contention — callbacks from different sources never compete. (2) Per-source silence detection — drop a silent mic without affecting system audio. (3) Each track records its own timing offset.

**Format:** 48kHz, mono, 64kbps AAC, `.m4a` container.

**Timing offset tracking:** `SingleTrackAudioWriter` records `segmentStartTime` (from `CMClockGetHostTimeClock()`) and `firstBufferTime` (PTS of first buffer). Difference becomes `startOffset` in `AudioTrackTimingInfo` for remix alignment. Buffers retimed to `.zero` within each file.

**Silence batching (non-obvious):** Silent buffers (RMS < 0.001, ~-60dB) are accumulated, not encoded individually. Flushed as one synthetic buffer when: (a) 48000 samples (1s) accumulate, or (b) non-silent buffer arrives. Reduces encoder invocations for quiet mics. Built via `calloc` -> `CMBlockBufferCreateWithMemoryBlock` -> `CMSampleBufferCreate`.

**Muted state (non-obvious):** Muted sources generate silence buffers preserving timing. System audio: zeroed `CMSampleBuffer` via `CMAudioSampleBufferCreateReadyWithPacketDescriptions`. Mics: zero-filled `AVAudioPCMBuffer`. Maintains timing continuity — track duration stays correct while muted.

## AudioRemixer

Merges per-source M4A files into single multi-track M4A. Source: `SolstoneCaptureCore/.../AudioRemixer.swift`

**Pipeline:** Filter (drop hasAudio=false) -> speech analysis -> drop no-speech tracks -> store silence ranges for system audio -> `AVAssetReader`+`AVAssetReaderTrackOutput` per input (PCM Float32) -> `AVAssetWriter` with one input per track -> interleaved read/write -> atomic rename (temp UUID -> final URL).

**Interleaved reading (non-obvious):** AVAssetWriter with multiple inputs expects data from all tracks roughly together in time. Draining one track before starting another stalls the writer. The loop iterates round-robin: one buffer per track per iteration. If `isReadyForMoreMediaData` is false, buffer goes into `pendingSamples[idx]` for retry next iteration. 1ms `Task.sleep` prevents CPU spin.

**Timing alignment:** Each buffer retimed via `CMSampleBufferCreateCopyWithNewTiming`, adding track's `startOffset` to PTS. Aligns tracks that started at different points within the segment.

**Music silencing:** `zeroBuffer()` creates a new CMSampleBuffer with identical timing but zeroed data via `CMAudioSampleBufferCreateReadyWithPacketDescriptions`. Buffer PTS checked against silence ranges with `CMTimeRangeContainsTime`.

## SoundAnalysis Integration

`SystemAudioAnalyzer` classifies audio using on-device SoundAnalysis. Source: `SolstoneCaptureCore/.../SystemAudioAnalyzer.swift`

- `SNAudioFileAnalyzer(url:)` processes completed M4A files (fast, on-device, no internet)
- `SNClassifySoundRequest(classifierIdentifier: .version1)` — pre-trained classifier
- `ClassificationObserver` implements `SNResultsObserving`
- Identifiers are **hard-coded strings**: `"speech"`, `"music"` — no enum in API

**Thresholds:** Speech > 0.3, music > 0.6. Music-only = music > 0.6 AND speech < 0.3. Asymmetric: speech threshold lower because it's more important to preserve.

**Range processing:**
1. Collect music-only `CMTimeRange` values
2. Sort by start time (`CMTimeCompare` returns -1/0/1, not boolean)
3. Merge adjacent ranges within **5-second gap** — bridges classification fluctuations
4. Shrink each range by **0.2s padding** at both ends — prevents clipping speech edges
5. Discard negative-duration ranges (too short to survive padding)

**Fail-open:** If analysis fails, return `.unavailable` (hasSpeech=true, empty silenceRanges). Audio kept as-is. Never discard audio due to analysis failure.

## CMTime Patterns

- **Audio timescale: 48000** (1-sample precision). Video timescale: 600.
- **Monotonic clock:** `CMClockGetTime(CMClockGetHostTimeClock())` for segment starts and mic PTS. Never `Date()` for media timing.
- **CMTimeCompare returns -1/0/1**, not boolean. Use `CMTimeCompare(a, b) < 0` for a < b.
- **Buffer retiming:** `CMSampleBufferCreateCopyWithNewTiming` — shallow copy, shared audio data. Used in SingleTrackAudioWriter (retime to zero) and AudioRemixer (apply offset).
- **Segment duration from wall clock:** `Date().timeIntervalSince(captureStartTime)` — wall clock is correct here for human-meaningful directory names (e.g., `143022_297`).

## Segment Lifecycle

Source: `SolstoneCapture/.../SegmentWriter.swift`

1. **Create** `HHMMSS.incomplete/` directory
2. **Start:** `ScreenshotCapturer` per display + `PerSourceAudioManager` (system audio + mics). Segment time from `CMClockGetHostTimeClock()`
3. **Record:** SCStream video, system audio via `SystemAudioCaptureManager`, mics via `MicrophoneCaptureManager`. Each source writes independently
4. **Rotate:** `finishCapture()` stops capturers, clears audio callbacks (engines persist), finishes writers. Returns `SegmentCaptureResult`
5. **Rename:** `HHMMSS.incomplete/` -> `HHMMSS_DDD/` (DDD = actual seconds). Files renamed too
6. **Background remix:** `RemixQueue` (actor) runs `AudioRemixer.remix()` — merge, drop silent, silence music-only, delete source M4As
7. **Upload:** Coordinator picks up completed segments

**Gap minimization:** `finishCapture()` returns immediately — does NOT wait for remix. New segment starts while old one remixes in background.
