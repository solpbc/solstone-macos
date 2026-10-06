// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import Testing
@testable import solstone

@Suite("Audio elapsed timeline")
struct AudioTimelineTests {
    @Test func captureClockUsesSampleContinuityAndRejectsUnanchoredTime() throws {
        var clock = MicrophoneBufferClock()
        let host = mach_absolute_time()
        let unanchored = clock.admit(MicrophoneBufferTime(AVAudioTime(sampleTime: 0, atRate: 48_000)), frames: 4800, sampleRate: 48_000)
        #expect(unanchored == nil)
        let firstResult = clock.admit(MicrophoneBufferTime(AVAudioTime(hostTime: host, sampleTime: 0, atRate: 48_000)), frames: 4800, sampleRate: 48_000)
        let first = try #require(firstResult)
        #expect(!first.continuous)
        for index in 1...100 {
            // Host jitter/drift cannot manufacture gaps in contiguous samples.
            let jitter = Double(index) * 0.00002 + (index.isMultiple(of: 2) ? 0.0003 : -0.0003)
            let time = AVAudioTime(hostTime: host + AVAudioTime.hostTime(forSeconds: Double(index) / 10 + jitter),
                sampleTime: Int64(index * 4800), atRate: 48_000)
            let admitted = clock.admit(MicrophoneBufferTime(time), frames: 4800, sampleRate: 48_000)
            #expect(admitted?.continuous == true)
        }
        let extrapolatedResult = clock.admit(MicrophoneBufferTime(AVAudioTime(sampleTime: 484_800, atRate: 48_000)), frames: 4800, sampleRate: 48_000)
        let extrapolated = try #require(extrapolatedResult)
        #expect(extrapolated.continuous)
        #expect(abs(CMTimeSubtract(extrapolated.time, first.time).seconds - 10.1023) < 0.0001)
        let gapResult = clock.admit(MicrophoneBufferTime(AVAudioTime(hostTime: host + AVAudioTime.hostTime(forSeconds: 14),
            sampleTime: 672_000, atRate: 48_000)), frames: 4800, sampleRate: 48_000)
        let gap = try #require(gapResult)
        #expect(!gap.continuous)
        clock.reset()
        let resetSampleOnly = clock.admit(MicrophoneBufferTime(AVAudioTime(sampleTime: 672_000, atRate: 48_000)), frames: 4800, sampleRate: 48_000)
        let newRateSampleOnly = clock.admit(MicrophoneBufferTime(AVAudioTime(sampleTime: 0, atRate: 96_000)), frames: 9600, sampleRate: 96_000)
        #expect(resetSampleOnly == nil && newRateSampleOnly == nil)
    }

    @Test(arguments: [false, true], [10.0, 9.75, 10.25, 10.75])
    func initialBoundaryKeepsExactSuffixAndCaptureTime(planar: Bool, beforeFrames: Double) async throws {
        let root = try makeTempDirectory("timeline-boundary-grid")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"), trackType: .systemAudio,
            segmentStartTime: CMTime(value: 1, timescale: 1))
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: planar ? 2 : 1, interleaved: !planar))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12)); pcm.frameLength = 12
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<12 { pcm.floatChannelData![channel][frame] = Float(frame + channel * 20) / 100 }
        }
        let start = CMTimeSubtract(CMTime(value: 1, timescale: 1), CMTime(seconds: beforeFrames / 48_000, preferredTimescale: 192_000))
        let original = try timelineSample(pcm, time: start)
        let skipped = Int(ceil(beforeFrames)), eligible = 12 - skipped
        let clipped = try #require(writer._clipBoundaryForTesting(original, skipping: skipped))
        var oracle = CMSampleTimingInfo()
        #expect(CMSampleBufferGetSampleTimingInfo(original, at: skipped, timingInfoOut: &oracle) == noErr)
        #expect(CMSampleBufferGetPresentationTimeStamp(clipped) == oracle.presentationTimeStamp)
        #expect(CMSampleBufferGetNumSamples(clipped) == eligible)
        let retained = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(eligible)))
        retained.frameLength = AVAudioFrameCount(eligible)
        #expect(CMSampleBufferCopyPCMDataIntoAudioBufferList(clipped, at: 0, frameCount: Int32(eligible), into: retained.mutableAudioBufferList) == noErr)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<eligible { #expect(retained.floatChannelData![channel][frame] == pcm.floatChannelData![channel][frame + skipped]) }
        }
        writer.appendAudio(original)
        _ = await writer.finish()
        #expect(writer.statisticsSnapshot.receivedFrames == eligible && writer.statisticsSnapshot.acceptedFrames == eligible)
        #expect(writer.statisticsSnapshot.droppedFrames == 0 && writer.statisticsSnapshot.failures.isEmpty)
    }

    @Test func initialOutsideWindowIsQuietButOldOverlapAndClipFailureAreHonest() async throws {
        let root = try makeTempDirectory("timeline-boundary-disposition")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"), trackType: .systemAudio,
            segmentStartTime: CMTime(value: 1, timescale: 1))
        let pcm = try timelinePCM(frames: 4800, frequency: 220)
        writer.appendPCMBuffer(pcm, presentationTime: CMTime(seconds: 0.8, preferredTimescale: 48_000))
        #expect(writer.statisticsSnapshot.receivedFrames == 0 && writer.statisticsSnapshot.failures.isEmpty)
        writer._boundaryClipAdmissionForTesting = { frames in #expect(frames == 2400); return false }
        writer.appendPCMBuffer(pcm, presentationTime: CMTime(seconds: 0.95, preferredTimescale: 48_000))
        #expect(writer.statisticsSnapshot.receivedFrames == 2400 && writer.statisticsSnapshot.droppedFrames == 2400)
        writer._boundaryClipAdmissionForTesting = nil
        writer.appendPCMBuffer(pcm, presentationTime: CMTime(value: 1, timescale: 1))
        writer.appendPCMBuffer(pcm, presentationTime: CMTime(seconds: 0.95, preferredTimescale: 48_000))
        writer.appendPCMBuffer(pcm, presentationTime: CMTime(seconds: -1e12, preferredTimescale: 1))
        _ = await writer.finish()
        let statistics = writer.statisticsSnapshot
        #expect(statistics.receivedFrames == 16_800 && statistics.acceptedFrames == 4800 && statistics.droppedFrames == 12_000)
        #expect(statistics.failures.contains(where: { $0.stage == "boundary_clip" }) && statistics.failures.contains(where: { $0.stage == "timeline" }))
        #expect(try await timelineDecode(writer.url).first?.count == 4800)
    }

    @Test func realWriterRemixAndOrphanKeepEveryElapsedGap() async throws {
        let root = try makeTempDirectory("timeline-markers")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("system", "system"), ("late:mic", "microphone")])
        var inputs: [AudioRemixerInput] = []
        for (id, starts) in [("system", [1.0, 3.0]), ("late:mic", [2.0, 3.5])] {
            try recorder.admitSource(id, kind: id == "system" ? "system" : "microphone")
            let type: AudioTrackType = id == "system" ? .systemAudio : .microphone(name: "late", deviceUID: id)
            let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("120000_audio_\(id.replacingOccurrences(of: ":", with: "_")).m4a"),
                trackType: type, segmentStartTime: .zero, onStatistics: { recorder.statistics(id, $0) })
            for (index, start) in starts.enumerated() {
                writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: Double(220 + index * 440)),
                    presentationTime: CMTime(seconds: start, preferredTimescale: 48_000))
            }
            let info = await writer.finish(captureCutoff: CMTime(seconds: 4, preferredTimescale: 48_000))
            #expect(info.hasAudio && info.startOffset == .zero && abs(info.endOffset.seconds - 4) < 0.0001)
            let stats = writer.statisticsSnapshot
            #expect(stats.receivedFrames == 9600 && stats.acceptedFrames == 9600 && stats.droppedFrames == 0)
            #expect(stats.generatedFrames == 182_400 && stats.gapCount == 3 && stats.failures.isEmpty)
            let raw = try await timelineDecode(writer.url)
            #expect(raw.count == 1)
            verifyTimelineMarkers(try #require(raw.first), starts: starts, seconds: 4)
            inputs.append(.init(url: writer.url, timingInfo: info))
        }
        try recorder.seal()
        // Different creation dates must not be added to the already padded clock.
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: inputs[0].url.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1050)], ofItemAtPath: inputs[1].url.path)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard case .ready(let recovered, let unreadable) = await classifyAudioSources(in: files, timePrefix: "120000", verbose: false) else {
            Issue.record("Declared timeline should reconstruct actual sources"); return
        }
        #expect(unreadable.isEmpty && recovered.count == 2)
        #expect(recovered.allSatisfy { $0.timingInfo.startOffset == .zero && abs($0.timingInfo.endOffset.seconds - 4) < 0.02 })
        for (index, sources) in [inputs, recovered].enumerated() {
            let output = root.appendingPathComponent("mixed-\(index).m4a")
            let result = try await AudioRemixer().remix(inputs: sources, to: output, silenceMusic: false)
            #expect(result.tracksWritten == 2 && result.tracksSkipped == 0)
            let tracks = try await timelineDecode(output)
            #expect(tracks.count == 2)
            guard tracks.count == 2 else { return }
            verifyTimelineMarkers(tracks[0], starts: [1, 3], seconds: 4)
            verifyTimelineMarkers(tracks[1], starts: [2, 3.5], seconds: 4)
        }
        // A single surviving delayed source still retains the original origin.
        let single = await buildAudioInputs(from: [inputs[1].url], timePrefix: "120000", verbose: false)
        #expect(single.count == 1 && single.first?.timingInfo.startOffset == .zero)
    }

    @Test func longRecoveryGapKeepsRealResumedMarkerAtEightySeconds() async throws {
        let root = try makeTempDirectory("timeline-long-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"), trackType: .systemAudio, segmentStartTime: .zero)
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 220), presentationTime: .zero)
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 660), presentationTime: CMTime(seconds: 80, preferredTimescale: 48_000))
        _ = await writer.finish(captureCutoff: CMTime(seconds: 81, preferredTimescale: 48_000))
        let statistics = writer.statisticsSnapshot
        #expect(statistics.acceptedFrames == 9600 && statistics.droppedFrames == 0 && statistics.failures.isEmpty)
        #expect(statistics.generatedFrames == 3_878_400 && statistics.gapCount == 2)
        let decoded = try #require(try await timelineDecode(writer.url).first)
        #expect(decoded.count == 3_888_000)
        #expect(timelineRMS(decoded, from: 79.5, to: 79.9) < 0.002)
        #expect(timelineRMS(decoded, from: 80.025, to: 80.075) > 0.05)
        #expect(timelineRMS(decoded, from: 80.5, to: 80.9) < 0.002)
    }

    @Test func paddingFailurePreservesPrefixAndCannotShiftResumedSpeech() async throws {
        let root = try makeTempDirectory("timeline-backpressure")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recorder = try AudioCaptureRecorder(directory: dir, timePrefix: "120000", expected: [("system", "system")])
        try recorder.admitSource("system", kind: "system")
        let writer = try SingleTrackAudioWriter(url: dir.appendingPathComponent("120000_audio_system.m4a"), trackType: .systemAudio,
            segmentStartTime: .zero, onStatistics: { recorder.statistics("system", $0) })
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 220), presentationTime: .zero)
        writer._paddingAdmissionForTesting = { frames in #expect(frames <= 48_000); return false }
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 660), presentationTime: CMTime(seconds: 2, preferredTimescale: 48_000))
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 880), presentationTime: CMTime(seconds: 3, preferredTimescale: 48_000))
        let info = await writer.finish(captureCutoff: CMTime(seconds: 4, preferredTimescale: 48_000))
        let stats = writer.statisticsSnapshot
        #expect(stats.receivedFrames == 14_400 && stats.acceptedFrames == 4800 && stats.droppedFrames == 9600)
        #expect(stats.generatedFrames == 0 && stats.failures.contains(where: { $0.stage == "padding" }))
        let original = try Data(contentsOf: writer.url)
        let prefix = try #require(try await timelineDecode(writer.url).first)
        #expect(prefix.count == 4800)
        #expect(timelineRMS(prefix, from: 0.025, to: 0.075) > 0.05)
        try recorder.seal()
        let queue = RemixQueue()
        await queue.enqueue(.init(segmentDirectory: dir, timePrefix: "120000", capturedDurationSeconds: 4,
            audioInputs: [.init(url: writer.url, timingInfo: info)], silenceMusic: false, micMetadataJSON: nil,
            audioDiagnostics: recorder, audioOwnership: AudioNativeOwnership { writer.nativeWriterIsQuiescent }))
        await queue.waitForCompletion()
        let final = root.appendingPathComponent("120000_4")
        #expect(try Data(contentsOf: final.appendingPathComponent("120000_4_audio_system.m4a")) == original)
        let mixed = try #require(try await timelineDecode(final.appendingPathComponent("120000_4_audio.m4a")).first)
        #expect(mixed.count == 4800)
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: final.appendingPathComponent("120000_4_meta.json"))) as? [String: Any]
        #expect((meta?["audio_capture"] as? [String: Any])?["state"] as? String == "partial")
    }

    @Test(arguments: [0, 1, 2, 3])
    func declaredOriginNeverUsesLegacyFallback(control: Int) async throws {
        let root = try makeTempDirectory("timeline-origin-control")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("120000_audio_system.m4a")
        try await makeTinyValidM4A(at: file)
        if control != 0 {
            let source: [String: Any] = control == 2 ? ["source_id": "system", "timeline_origin_seconds": 1.5] : ["source_id": "system"]
            let capture: [String: Any] = ["timeline_version": control == 3 ? 99 : 1, "sources": [source]]
            try JSONSerialization.data(withJSONObject: ["audio_capture": capture]).write(to: root.appendingPathComponent("120000_meta.json"))
        }
        let inputs = await buildAudioInputs(from: [file], timePrefix: "120000", verbose: false)
        #expect(inputs.isEmpty == (control != 0))
    }

    @Test func originWriteFailureBlocksActualSourceAdmission() throws {
        let root = try makeTempDirectory("timeline-origin-write-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("system", "system")])
        let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "120000")
        manager.bindDiagnostics(recorder)
        let meta = root.appendingPathComponent("120000_meta.json")
        try FileManager.default.removeItem(at: meta)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try manager.startSystemAudio() }
        #expect(manager._sourceWriterForTesting("system") == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("120000_audio_system.m4a").path))
    }

    @Test(arguments: [false, true])
    func dynamicMicOriginPrecedesNativeStartAndFailureBlocksIt(fails: Bool) async throws {
        let root = try makeTempDirectory("timeline-dynamic-origin")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [])
        let started = LockedCounter(), observed = LockedValue<Bool>()
        let shared = MicrophoneCaptureManager()
        let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "120000", captureManager: shared,
            startMicrophoneCapture: { device in
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("120000_meta.json"))) as? [String: Any]
                let rows = (value?["audio_capture"] as? [String: Any])?["sources"] as? [[String: Any]]
                observed.set(rows?.first(where: { $0["source_id"] as? String == device.uid })?["timeline_origin_seconds"] as? Double == 0)
                started.increment()
            })
        manager.bindDiagnostics(recorder); manager.setSegmentStartTime(.zero)
        if fails {
            let meta = root.appendingPathComponent("120000_meta.json")
            try FileManager.default.removeItem(at: meta)
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        }
        let device = AudioInputDevice(id: 42, name: "late", uid: "late", manufacturer: nil, sampleRate: 48_000, transportType: .virtual)
        if fails {
            #expect(throws: (any Error).self) { try manager.addMicrophone(device) }
            #expect(started.count == 0 && manager._sourceWriterForTesting("late") == nil)
        } else {
            _ = try manager.addMicrophone(device)
            #expect(started.count == 1 && observed.current == true)
            let writer = try #require(manager._sourceWriterForTesting("late"))
            writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 220), presentationTime: CMTime(seconds: 2, preferredTimescale: 48_000))
            _ = await writer.finish()
            let inputs = await buildAudioInputs(from: [writer.url], timePrefix: "120000", verbose: false)
            #expect(inputs.count == 1 && inputs.first?.timingInfo.startOffset == .zero)
            let decoded = try #require(try await timelineDecode(writer.url).first)
            #expect(decoded.count == 100_800 && timelineRMS(decoded, from: 2.025, to: 2.075) > 0.05)
        }
    }

    @MainActor @Test func screenshotStopDefinesCutoffAndFinalizationDelayAddsNoPCM() async throws {
        let root = try makeTempDirectory("timeline-actual-cutoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let screenshot = FakeScreenshotCapturer(behavior: .hangStop)
        let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "120000")
        let segment = SegmentWriter(outputDirectory: root, timePrefix: "120000", capturerStopTimeoutSeconds: 2.2,
            audioFinishTimeoutSeconds: 2,
            screenshotCapturerFactory: { _, _, _, _, _, _ in screenshot },
            audioManagerFactory: { _, _, _, _ in manager })
        try await segment.start(sources: .screen, displayInfos: [DisplayInfo(displayID: 42, width: 100, height: 100,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100))])
        let writer = try #require(manager._sourceWriterForTesting("system"))
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 220), presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        let gate = OneShotContinuationGate(), entered = LockedCounter()
        writer._finishAdmissionHookForTesting = { entered.increment(); await gate.wait() }
        defer { gate.release() }
        let finishing = Task { await segment.finishCapture() }
        await screenshot.stopCount.waitUntilCount(1)
        try await Task.sleep(for: .milliseconds(1100))
        let sample = try makeNonSilentAudioSampleBuffer(seconds: 0.1)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        #expect(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr)
        manager.appendSystemAudio(try #require(retimed))
        await entered.waitUntilCount(1)
        let before = writer.statisticsSnapshot
        try await Task.sleep(for: .milliseconds(400))
        #expect(writer.statisticsSnapshot.generatedFrames == before.generatedFrames)
        gate.release()
        let result = try #require(await finishing.value)
        #expect(result.capturedDurationSeconds == 2)
        let input = try #require(result.audioInputs.first)
        #expect(input.timingInfo.endOffset.seconds >= 2.15 && input.timingInfo.endOffset.seconds < 2.6)
        #expect(writer.statisticsSnapshot.acceptedFrames == 9600)
        let decoded = try #require(try await timelineDecode(writer.url).first)
        #expect(abs(decoded.count - (9600 + (before.generatedFrames ?? 0))) <= 1)
    }

    @Test func rejectedCapturedSilenceCannotCompressFollowingSpeech() async throws {
        let root = try makeTempDirectory("timeline-captured-silence-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"), trackType: .systemAudio, segmentStartTime: .zero)
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 220), presentationTime: .zero)
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 0), presentationTime: CMTime(seconds: 0.1, preferredTimescale: 48_000))
        writer._appendAdmissionForTesting = { _ in false }
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 660), presentationTime: CMTime(seconds: 0.2, preferredTimescale: 48_000))
        writer._appendAdmissionForTesting = nil
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 880), presentationTime: CMTime(seconds: 0.3, preferredTimescale: 48_000))
        _ = await writer.finish(captureCutoff: CMTime(seconds: 1, preferredTimescale: 48_000))
        let statistics = writer.statisticsSnapshot
        #expect(statistics.receivedFrames == 19_200 && statistics.acceptedFrames == 4800 && statistics.droppedFrames == 14_400)
        #expect(statistics.generatedFrames == 0 && statistics.failures.contains(where: { $0.stage == "append" }))
        #expect(try await timelineDecode(writer.url).first?.count == 4800)
    }

    @Test func timestampJitterAndPartialOverlapAreNeverFailures() async throws {
        let root = try makeTempDirectory("timeline-jitter-overlap")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"), trackType: .systemAudio, segmentStartTime: .zero)
        let pcm = try timelinePCM(frames: 4800, frequency: 220)
        writer.appendPCMBuffer(pcm, presentationTime: .zero)
        // 10 samples early: clock jitter, kept whole and placed right after the previous buffer.
        writer.appendPCMBuffer(pcm, presentationTime: CMTime(value: 4790, timescale: 48_000))
        // 50 ms early: only the 2400 frames on time already written are trimmed.
        writer.appendPCMBuffer(pcm, presentationTime: CMTime(value: 9600 - 2400, timescale: 48_000))
        _ = await writer.finish()
        let statistics = writer.statisticsSnapshot
        #expect(statistics.failures.isEmpty)
        #expect(statistics.receivedFrames == 14_400 && statistics.acceptedFrames == 12_000 && statistics.droppedFrames == 2400)
        #expect(statistics.generatedFrames == 0)
        #expect(try await timelineDecode(writer.url).first?.count == 12_000)
    }

    @Test func hugeOrInvalidTimesNeverAllocatePaddingOrErasePrefix() async throws {
        let root = try makeTempDirectory("timeline-malformed-time")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"), trackType: .systemAudio, segmentStartTime: .zero)
        writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 220), presentationTime: .zero)
        for invalid in [CMTime.invalid, .positiveInfinity, CMTime(seconds: 1e12, preferredTimescale: 1)] {
            writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 660), presentationTime: invalid)
        }
        _ = await writer.finish()
        let statistics = writer.statisticsSnapshot
        #expect(statistics.receivedFrames == 19_200 && statistics.acceptedFrames == 4800 && statistics.droppedFrames == 14_400)
        #expect(statistics.generatedFrames == 0 && statistics.failures.contains(where: { $0.stage == "timeline" }))
        #expect(try await timelineDecode(writer.url).first?.count == 4800)
    }

    @Test func queuedCheckpointCannotRaceOriginIntoFirstRecoverablePrefix() async throws {
        let root = try makeTempDirectory("timeline-durable-origin")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("system", "system")])
        let entered = LockedCounter(), gate = DispatchSemaphore(value: 0), calls = LockedCounter()
        recorder._persistenceHookForTesting = { calls.increment(); if calls.count == 1 { entered.increment(); gate.wait() } }
        defer { gate.signal() }
        recorder.expect("dynamic", kind: "microphone")
        await entered.waitUntilCount(1)
        let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "120000")
        manager.bindDiagnostics(recorder); manager.setSegmentStartTime(.zero)
        let admitted = LockedCounter()
        let task = Task.detached {
            _ = try manager.startSystemAudio()
            admitted.increment()
            let writer = try #require(manager._sourceWriterForTesting("system"))
            for index in 0..<15 {
                writer.appendPCMBuffer(try timelinePCM(frames: 4800, frequency: 220),
                    presentationTime: CMTime(value: Int64(index * 4800), timescale: 48_000))
                try await Task.sleep(for: .milliseconds(10))
            }
            return writer
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(admitted.count == 0)
        gate.signal()
        let writer = try await task.value
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("120000_meta.json"))) as? [String: Any]
        let capture = try #require(meta?["audio_capture"] as? [String: Any])
        let row = try #require((capture["sources"] as? [[String: Any]])?.first(where: { $0["source_id"] as? String == "system" }))
        #expect(capture["timeline_version"] as? Int == 1 && row["timeline_origin_seconds"] as? Double == 0)
        let prefix = root.appendingPathComponent("prefix.m4a")
        var readable = false
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: writer.url), data.range(of: Data("moov".utf8)) != nil {
                try data.write(to: prefix)
                if let duration = try? await AVURLAsset(url: prefix).load(.duration), duration.seconds > 0 { readable = true; break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(readable)
        _ = await writer.finish()
    }
}

private func timelineSample(_ pcm: AVAudioPCMBuffer, time: CMTime) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(pcm.format.sampleRate)),
        presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
        sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    let result = try #require(sample)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
    return result
}

private func timelinePCM(frames: Int, frequency: Double) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames { buffer.floatChannelData![0][frame] = Float(0.2 * sin(2 * .pi * frequency * Double(frame) / 48_000)) }
    return buffer
}

private func timelineDecode(_ url: URL) async throws -> [[Float]] {
    let asset = AVURLAsset(url: url)
    var tracks: [[Float]] = []
    for track in try await asset.loadTracks(withMediaType: .audio) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var decoded = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: decoded.count * 4, destination: &decoded) == noErr)
            samples += decoded
        }
        #expect(reader.status == .completed)
        tracks.append(samples)
    }
    return tracks
}

private func timelineRMS(_ samples: [Float], from: Double, to: Double) -> Double {
    let lower = Int(from * 48_000), upper = Int(to * 48_000)
    guard lower >= 0, upper <= samples.count, upper > lower else { return .infinity }
    return sqrt(samples[lower..<upper].reduce(0.0) { $0 + Double($1 * $1) } / Double(upper - lower))
}

private func verifyTimelineMarkers(_ samples: [Float], starts: [Double], seconds: Double) {
    #expect(abs(samples.count - Int(seconds * 48_000)) <= 1024)
    for start in starts { #expect(timelineRMS(samples, from: start + 0.025, to: start + 0.075) > 0.05) }
    #expect(timelineRMS(samples, from: 0.25, to: 0.75) < 0.002)
    #expect(timelineRMS(samples, from: 2.25, to: 2.75) < 0.002)
    #expect(timelineRMS(samples, from: 3.75, to: 3.95) < 0.002)
}
