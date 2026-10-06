---
name: av-media-pipeline
description: >
  AVFoundation media pipeline for H.264 video encoding, multi-track audio recording,
  and intelligent audio remixing. Covers AVAssetWriter, AVAudioEngine, AudioRemixer,
  SoundAnalysis, and CMTime patterns. Use when working with video/audio recording,
  encoding, format conversion, or the remix pipeline.
---

## H.264 Video Encoding

`VideoWriter` wraps AVAssetWriter for 1fps screen capture to `.mp4`. Source: `Sources/solstone/VideoWriter.swift`, `Sources/solstone/ScreenshotCapturer.swift`

- **Codec:** `AVVideoCodecType.h264` (hardware-accelerated). BT.709 color. Frame reordering disabled.
- **Pixel format:** `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`: native hardware encoder format. SCStream delivers this directly, no CPU color conversion.
- **Keyframe interval: 90s.** Both `AVVideoMaxKeyFrameIntervalKey` and `AVVideoMaxKeyFrameIntervalDurationKey` set to 90. At 1fps = ~3-4 keyframes per 5-min segment. Maximizes P-frame compression for mostly-static screens. Keyframe spacing affects recovery, but does not establish a maximum corruption-loss bound.
- **Fragment interval: 30s.** `movieFragmentInterval = CMTime(seconds: 30, preferredTimescale: 1)` requests fragmented MP4 output. Recoverability depends on completed fragments, codec/container behavior and the interruption. This setting alone does not establish a 30-second loss bound. See Apple’s [movieFragmentInterval](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval).
- **Frame flow:** SCStream callback -> skip idle frames (`SCFrameStatus == .idle`) -> `VideoWriter.appendFrame(pixelBuffer, presentationTime:)` -> check `isReadyForMoreMediaData`, drop if not ready. PTS from `Date().timeIntervalSince(captureStartTime)` at timescale 600.

## Persistent AVAudioEngine

`MicrophoneCaptureManager` keeps `ExternalMicCapture` instances (each wrapping `AVAudioEngine`) alive across segment rotations. Data and error destinations change together. Source: `Sources/solstone/ExternalMicCapture.swift`, `Sources/solstone/MicrophoneCaptureManager.swift`

**Why:** Repeated engine teardown/start can disturb playback. Persistent engines avoid that normal rotation churn; they do not guarantee uninterrupted capture during routing changes, detachment or recovery.

**Callback swapping:** paired destinations and raw queue admission share `callbackLock`. `detachForBoundary()` captures the cutoff and queues converter EOS to the retained old destination. `setQueuedCallback(for:callback:onError:)` wires the next segment. The selection lock/revision authorizes writer admission and immediately revokes uncommitted old PCM/tails; re-enable cannot validate an obsolete destination. Ordinary `drain()` observes a fixed watermark through actual writer dispositions without EOS/reset. Segment finish waits for its conversion/EOS barrier and its own closed writer; an old same-UID writer does not gate a later segment’s finish.

**Segment evidence:** `AudioCaptureRecorder` persists source intent, failures and independent bounded writer statistics to the time-prefix `_meta.json`. Received frames advance at revision-qualified writer admission; accepted frames advance only after native acceptance. Captured quiet frames remain captured input; generated gap zeros have separate counters. Rejection before writer admission leaves explicitly incomplete counters rather than inventing 48kHz input counts. Interrupted counters are lower bounds, not proof of silence. Known/incomplete/unknown flags and failures survive seal and bounded merges. Late completion can improve sealed evidence until recorder handoff, then cannot recreate the old path or rewrite promoted metadata. The native producer tests check [the schema](../../contracts/audio-capture-v1.schema.json) and [example](../../contracts/audio-capture-v1.example.json); the journal typed projection and durable reload retain the optional fields. Remix state is separate. `RemixQueue` quarantines unresolved native ownership and preserves admission/timeline/padding failure originals; readable media alone never grants deletion authority.

**Hardware format detection: critical ordering:**
1. Access `engine.inputNode` (triggers initialization)
2. `setInputDevice()`: pin via `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice`
3. `engine.prepare()` (acquires hardware)
4. Read `inputNode.inputFormat(forBus: 0)`: actual hardware format
5. Install tap with hardware format
6. `engine.start()`

**Never use `outputFormat(forBus: 0)`**: returns cached/default values, causes crash on format mismatch.

**Device pinning:** Without it, AVAudioEngine follows system default. AirPods connect -> all unpinned engines silently switch. Pin via `AudioUnitSetProperty` on `engine.inputNode.audioUnit`.

**Config change:** `handleConfigChange()` admits one active engine/request recovery batch under `callbackLock` before queueing. Queue serialization alone cannot coalesce notification admission. Each bounded attempt stops before removing the tap, creates a fresh engine and resolves the selected UID before binding. Exhaustion parks that request. Conversion owns its format/engine epoch and drains old tails to their retained destination; current selection revision still controls admission. See [AVAudioEngineConfigurationChange](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchange).

**Gain:** the `storedGain` getter/setter use `callbackLock`. A Float’s machine access does not provide Swift synchronization. The converted output uses one locked gain snapshot, then `vDSP_vsmul` and `vDSP_vclip`. Range 1.0–8.0; nonfinite updates become 1.

**Converter caching:** reuse `cachedConverter` only for matching source/target formats and processing epoch. Supply finite tap input once, then nil with `.noDataNow`; this is not EOS. At a genuine logical boundary, supply nil with `.endOfStream`, deliver every emitted tail frame to the retained destination and reset afterward. The 64-iteration drain ceiling is application policy and reports exhaustion. Capture-clock anchors and actual emitted frames determine PTS, including priming and format changes. See [TN3136](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions).

## Per-Source Audio Architecture

Each audio source records to its own M4A during a segment. `PerSourceAudioManager` orchestrates `SingleTrackAudioWriter` instances. Source: `Sources/solstone/PerSourceAudioManager.swift`, `Sources/solstone/SingleTrackAudioWriter.swift`, `Sources/solstone/AudioMediaAdmission.swift`

**Why individual files:** each source has an independent native writer queue and recording evidence. A held native writer does not run under capture-routing/selection locks or block healthy sibling writing. Finalization still respects the intended segment’s actual native owners.

**Format:** 48kHz, mono, 64kbps AAC, `.m4a` container.

**Capture-clock placement:** the segment starts on the host clock. Microphone PTS comes from valid tap `AVAudioTime`, with same-epoch clock anchors and actual converter output frames; system input retains its capture PTS. Intersect the first buffer with the segment window without retiming its pre-origin samples into capture. Raw files use the segment origin, persisted before recoverable media as `timeline_version = 1` and source `timeline_origin_seconds = 0`. Explicit leading/internal/trailing PCM zeros preserve elapsed holes through the capture cutoff; generated frames and gaps remain separate evidence. Failed required padding/native acceptance parks continuation and retains the usable prefix. A declared new origin missing or invalid during orphan recovery cannot use the legacy creation-date fallback. See [tap time](https://developer.apple.com/documentation/avfaudio/avaudionodetapblock) and [host clock conversion](https://developer.apple.com/documentation/coremedia/cmclockmakehosttimefromsystemunits(_:)).

**Bounded admission:** `AudioMediaBudget` follows the persistent system source or microphone UID across rotation, capture replacement and still-owned old writers. Separate raw/writer/temporary stages each cap owned PCM at 4MiB, a declared 12MiB sum. Raw/writer stages also cap four 48k-equivalent seconds and 64 copying/queued/executing jobs; temporary work caps 8 jobs. Each input is at most one second. Reserve before copying/allocation and charge actual backing bytes until application-owned resources are released, including native append in flight. High-channel input can hit bytes sooner. Saturation/copy failure parks future admission and records sticky source failure; committed queued media drains only to its old writer. The bound excludes framework pools and process RSS. Legacy isolated capture instances do not share a global budget.

**Silence batching:** quiet captured frames (RMS below 0.001) accumulate until at most one second or the smaller byte-budget limit, voiced input, ordinary writer observation or finish. Receipt completion waits for the batch’s real native acceptance/failure. Ordinary observation neither resets conversion nor generates trailing padding. Gap zeros and quiet captured frames have different counters.

**Interrupted audio:** `SingleTrackAudioWriter` sets one-second `initialMovieFragmentInterval` and `movieFragmentInterval`. Interrupted production-writer fixtures on macOS 15.7.7 and 27.0 preserved advancing readable prefixes after the first fragment and verified decoded markers; pre-first-fragment input remained unavailable. The measured two-second accepted-frame tail criterion applies to those fixtures, not arbitrary power loss, formats or physical devices. Requalify the exact source/binary after writer changes. Apple’s [initial interval](https://developer.apple.com/documentation/avfoundation/avassetwriter/initialmoviefragmentinterval) requests fragment timing; it is not a loss guarantee.

**Completion:** all intended append calls must return before [finishWriting](https://developer.apple.com/documentation/avfoundation/avassetwriter/finishwriting(completionhandler:)); inspect final writer status. A queued call, quiet batch or empty budget is not a completion oracle. Native calls have no application hard-latency/cancellation guarantee. Bounded finalization timeout retains ownership and quarantines unresolved originals.

**Audio pipeline:** Each audio source writes directly to its own M4A file. Raw per-source recording does not apply music silencing. Pause stops capture.

## AudioRemixer

Merges per-source M4A files into single multi-track M4A. Source: `Sources/solstone/AudioRemixer.swift`

**Pipeline:** Load readable audio tracks -> optional system music analysis -> `AVAssetReader` PCM Float32 output per source -> one writer input per source -> interleaved checked read/write -> completed output -> per-source outcomes. The finalizer persists outcomes before deleting fully copied source files. Negative speech classification never deletes a readable recording.

**Interleaved reading (non-obvious):** AVAssetWriter with multiple inputs expects data from all tracks roughly together in time. Draining one track before starting another stalls the writer. The loop iterates round-robin: one buffer per track per iteration. If `isReadyForMoreMediaData` is false, buffer goes into `pendingSamples[idx]` for retry next iteration. 1ms `Task.sleep` prevents CPU spin.

**Timing alignment:** Each buffer retimed via `CMSampleBufferCreateCopyWithNewTiming`, adding track's `startOffset` to PTS. Aligns tracks that started at different points within the segment.

**Music silencing:** `AudioBufferUtils.silencedCopy(of:ranges:)` zeroes only PCM frames wholly inside confirmed music intervals. Other frames in the same buffer remain intact. Incomplete/failed analysis returns no silence ranges.

## SoundAnalysis Integration

`SystemAudioAnalyzer` classifies audio using on-device SoundAnalysis. Source: `Sources/solstone/SystemAudioAnalyzer.swift`

- `SNAudioFileAnalyzer(url:)` processes completed M4A files (fast, on-device, no internet)
- `SNClassifySoundRequest(classifierIdentifier: .version1)`: pre-trained classifier
- `ClassificationObserver` implements `SNResultsObserving`
- Identifiers are **hard-coded strings**: `"speech"`, `"music"`: no enum in API

**Thresholds:** Speech > 0.3, music > 0.6. Music-only = music > 0.6 AND speech < 0.3. Asymmetric: speech threshold lower because it's more important to preserve.

**Range processing:**
1. Collect music-only `CMTimeRange` values
2. Sort by start time (`CMTimeCompare` returns -1/0/1, not boolean)
3. Merge overlapping or exactly adjacent ranges; never bridge a positive gap. Subtract speech-positive and unknown overlapping windows
4. Shrink each range by **0.2s padding** at both ends
5. Discard negative-duration ranges (too short to survive padding)

**Fail-open:** Failure or malformed analysis returns `.unavailable`. Incomplete coverage returns empty silence ranges with status `incomplete`. Audio is kept as-is. Never discard audio due to analysis failure.

## CMTime Patterns

- **Audio timescale: 48000** (1-sample precision). Video timescale: 600.
- **Monotonic clock:** host clock for segment origins; tap capture time and emitted converter frames for microphone PTS. Worker execution time and `Date()` do not define audio placement.
- **CMTimeCompare returns -1/0/1**, not boolean. Use `CMTimeCompare(a, b) < 0` for a < b.
- **Buffer retiming:** `CMSampleBufferCreateCopyWithNewTiming` retains the backing audio; timing changes do not trim or deep copy PCM. The writer explicitly copies the eligible boundary range. `AudioRemixer` applies the durable source offset.
- **Segment duration from wall clock:** `Date().timeIntervalSince(captureStartTime)`: wall clock is correct here for human-meaningful directory names (e.g., `143022_297`).

## Segment Lifecycle

Source: `Sources/solstone/SegmentWriter.swift`

1. **Create** `HHMMSS.incomplete/` directory
2. **Start:** `ScreenshotCapturer` per display + `PerSourceAudioManager` (system audio + mics). Segment time from `CMClockGetHostTimeClock()`
3. **Record:** SCStream video, system audio via `SystemAudioCaptureManager`, mics via `MicrophoneCaptureManager`. Each source writes independently
4. **Rotate:** `finishCapture()` stops screenshot admission, detaches audio callbacks at the cutoff, drains conversion/EOS and intended native writers, then seals evidence. Bounded timeout retains unresolved owners in `SegmentCaptureResult`
5. **Finalize:** `RemixQueue` requires native quiescence before probing/remixing or promotion. Unresolved ownership goes to `.failed` quarantine; the orphan scanner cannot readmit it
6. **Background remix:** readable audio can recover alongside corrupt video. Completed directories/files are promoted to `HHMMSS_DDD`. Source deletion requires persisted per-source copy outcomes and no applicable preservation failure; a readable prefix alone is insufficient
7. **Upload:** Coordinator picks up completed segments

**Gap minimization:** capture finalization does not wait for background remix, but it does await bounded screenshot/audio finalization. The next segment may start while the prior one remixes. Persistent engines/streams reduce churn; callback and lifecycle boundaries still require live continuity checks.
