// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import solstone

@Suite("Audio terminal evidence")
struct AudioTerminalEvidenceTests {
    @Test(arguments: [false, true])
    func snapshotsRemainPromptDuringNativeAppendAndSilenceFlush(silence: Bool) async throws {
        let root = try makeTempDirectory("audio-blocked-append")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"),
            trackType: .systemAudio, segmentStartTime: .zero)
        let entered = LockedCounter()
        let gate = DispatchSemaphore(value: 0)
        writer._nativeAppendHookForTesting = { entered.increment(); gate.wait() }
        defer { gate.signal() }
        let frames = silence ? 24_000 : 4800
        let operation = Task.detached {
            let buffer = try terminalPCM(frames: frames, frequency: silence ? 0 : 220)
            writer.appendPCMBuffer(buffer, presentationTime: .zero)
            return await writer.finish()
        }
        await entered.waitUntilCount(1)
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = writer.statisticsSnapshot
        #expect(start.duration(to: clock.now) < .milliseconds(100))
        #expect(snapshot.receivedFrames == frames && snapshot.acceptedFrames == 0)
        #expect(snapshot.statisticsAvailable == true && snapshot.statisticsComplete == false)
        #expect(!writer.nativeWriterIsQuiescent)
        gate.signal()
        _ = try await operation.value
        let final = writer.statisticsSnapshot
        #expect(final.acceptedFrames == frames && final.statisticsComplete == true)
        #expect(writer.nativeWriterIsQuiescent)
    }

    @MainActor
    @Test(arguments: [false, true])
    func realFinishTimeoutQuarantinesOwnershipAndScannerCannotReadmit(collision: Bool) async throws {
        let root = try makeTempDirectory("audio-native-owner")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026-10-05")
        let dir = day.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = PerSourceAudioManager(outputDirectory: dir, timePrefix: "120000")
        let segment = SegmentWriter(outputDirectory: dir, timePrefix: "120000", audioFinishTimeoutSeconds: 0.02,
            screenshotCapturerFactory: { _, _, _, _, _, _ in FakeScreenshotCapturer() },
            audioManagerFactory: { _, _, _, _ in manager })
        try await segment.start(sources: .screen, displayInfos: [DisplayInfo(displayID: 42, width: 100, height: 100,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100))])
        let writer = try #require(manager._sourceWriterForTesting("system"))
        writer.appendPCMBuffer(try terminalPCM(frames: 48_000, frequency: 220), presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        let gate = OneShotContinuationGate()
        let entered = LockedCounter()
        let completed = LockedCounter()
        writer._finishAdmissionHookForTesting = { entered.increment(); await gate.wait() }
        writer.onComplete = { completed.increment() }
        defer { gate.release() }
        let result = try #require(await segment.finishCapture())
        #expect(entered.count == 1 && result.audioInputs.isEmpty)
        #expect(manager.audioStatistics()["system"]?.acceptedFrames == 48_000)
        let before = try terminalCapture(dir)
        let beforeSource = try #require((before["sources"] as? [[String: Any]])?.first)
        #expect(beforeSource["received_frames"] as? Int == 48_000)
        #expect(beforeSource["accepted_frames"] as? Int == 48_000)
        #expect(beforeSource["writer_status"] as? String == "unknown")
        #expect(beforeSource["statistics_complete"] as? Bool == false)
        let failedDir = day.appendingPathComponent("120000.failed")
        if collision { try FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: dir.path)
        let callbacks = LockedCounter()
        let probes = LockedCounter()
        let remixes = LockedCounter()
        let queue = RemixQueue(durationLoader: { _ in probes.increment(); return CMTime(seconds: 1, preferredTimescale: 600) },
            nativeQuiescenceTimeoutSeconds: 0.01, remixerFactory: { _ in remixes.increment(); return FakeRemixer(.success) })
        await queue.setOnSegmentComplete { _, outcome in
            if case .failed = outcome {} else { Issue.record("Owned audio was promoted") }
            callbacks.increment()
        }
        await queue.enqueue(terminalJob(result))
        await queue.waitForCompletion()
        #expect(callbacks.count == 1 && probes.count == 0 && remixes.count == 0)
        let preserved = collision ? dir : failedDir
        #expect(FileManager.default.fileExists(atPath: preserved.appendingPathComponent("120000_audio_system.m4a").path))
        let capture = try terminalCapture(preserved)
        #expect(capture["state"] as? String == "failed")
        #expect((capture["failures"] as? [[String: Any]])?.first?["stage"] as? String == "native_ownership")
        let scanner = IncompleteSegmentRecovery(capturesDirectory: root, finalizer: queue)
        #expect(await scanner.recoverAll() == 0)
        #expect(await queue.inFlightPaths().contains(dir.standardizedFileURL.path) == collision)
        let sidecar = preserved.appendingPathComponent("120000_meta.json")
        let frozen = try Data(contentsOf: sidecar)
        gate.release()
        await completed.waitUntilCount(1)
        #expect(try Data(contentsOf: sidecar) == frozen)
        #expect(!FileManager.default.fileExists(atPath: day.appendingPathComponent("120000_1").path))
        if !collision { #expect(!FileManager.default.fileExists(atPath: dir.path)) }
    }

    @MainActor
    @Test func lateNativeFinishBeforeQueueHandoffImprovesDurableEvidence() async throws {
        let root = try makeTempDirectory("audio-late-native-finish")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = PerSourceAudioManager(outputDirectory: dir, timePrefix: "120000")
        let segment = SegmentWriter(outputDirectory: dir, timePrefix: "120000", audioFinishTimeoutSeconds: 0.02,
            screenshotCapturerFactory: { _, _, _, _, _, _ in FakeScreenshotCapturer() },
            audioManagerFactory: { _, _, _, _ in manager })
        try await segment.start(sources: .screen, displayInfos: [DisplayInfo(displayID: 42, width: 100, height: 100,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100))])
        let writer = try #require(manager._sourceWriterForTesting("system"))
        writer.appendPCMBuffer(try terminalPCM(frames: 48_000, frequency: 220), presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        let gate = OneShotContinuationGate()
        let completed = LockedCounter()
        writer._finishAdmissionHookForTesting = { await gate.wait() }
        writer.onComplete = { completed.increment() }
        defer { gate.release() }
        let result = try #require(await segment.finishCapture())
        gate.release()
        await completed.waitUntilCount(1)
        let queue = RemixQueue()
        await queue.enqueue(terminalJob(result))
        await queue.waitForCompletion()
        let final = root.appendingPathComponent("120000_1")
        let meta = final.appendingPathComponent("120000_1_meta.json")
        let frozen = try Data(contentsOf: meta)
        let rootMeta = try #require(try JSONSerialization.jsonObject(with: frozen) as? [String: Any])
        let capture = try #require(rootMeta["audio_capture"] as? [String: Any])
        let source = try #require((capture["sources"] as? [[String: Any]])?.first)
        #expect(source["accepted_frames"] as? Int == 48_000)
        #expect(source["statistics_complete"] as? Bool == true && source["writer_status"] as? String == "completed")
        #expect(capture["state"] as? String == "partial" && source["state"] as? String == "partial")
        #expect((source["failures"] as? [[String: Any]])?.contains(where: { $0["stage"] as? String == "finish" }) == true)
        result.audioDiagnostics?.statistics("system", AudioWriterStatistics(receivedFrames: 99_999, acceptedFrames: 99_999))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try Data(contentsOf: meta) == frozen)
        #expect(try await terminalDecode(final.appendingPathComponent("120000_1_audio.m4a")).count == 48_000)
    }

    @Test(arguments: ["invalid", "zero", "negative", "timeout", "throw"])
    func unusableDurationsPersistUnknownFailureWithoutChangingSourceBytes(kind: String) async throws {
        let root = try makeTempDirectory("audio-unusable-duration")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data("unreadable source retained".utf8)
        try bytes.write(to: dir.appendingPathComponent("120000_audio_system.m4a"))
        let callbacks = LockedCounter()
        let queue = RemixQueue(durationProbeTimeoutSeconds: 0.01, durationLoader: { _ in
            switch kind {
            case "invalid": return .invalid
            case "zero": return .zero
            case "negative": return CMTime(seconds: -1, preferredTimescale: 600)
            case "timeout": try await Task.sleep(for: .seconds(60)); return .zero
            default: throw CocoaError(.fileReadCorruptFile)
            }
        })
        await queue.setOnSegmentComplete { _, outcome in
            if case .failed = outcome {} else { Issue.record("Invented duration authorized promotion") }
            callbacks.increment()
        }
        await queue.enqueue(.init(segmentDirectory: dir, timePrefix: "120000", capturedDurationSeconds: nil,
            audioInputs: [], silenceMusic: false, micMetadataJSON: nil))
        await queue.waitForCompletion()
        let failed = root.appendingPathComponent("120000.failed")
        #expect(callbacks.count == 1)
        #expect(try Data(contentsOf: failed.appendingPathComponent("120000_audio_system.m4a")) == bytes)
        let capture = try terminalCapture(failed)
        let source = try #require((capture["sources"] as? [[String: Any]])?.first)
        #expect(capture["state"] as? String == "failed" && source["state"] as? String == "unknown")
        #expect(source["statistics_available"] as? Bool == false && source["statistics_complete"] as? Bool == false)
        #expect((source["failures"] as? [[String: Any]])?.first?["stage"] as? String == "duration")
        #expect(await queue.inFlightPaths().isEmpty)
    }

    @Test func listingFailureKeepsKnownEvidenceAndCallsFailureOnce() async throws {
        let root = try makeTempDirectory("audio-listing-evidence")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recorder = try AudioCaptureRecorder(directory: dir, timePrefix: "120000", expected: [("system", "system")])
        recorder.statistics("system", AudioWriterStatistics(receivedFrames: 960, acceptedFrames: 480,
            statisticsAvailable: true, statisticsComplete: false))
        try recorder.seal()
        let bytes = Data("unreadable source retained".utf8)
        try bytes.write(to: dir.appendingPathComponent("120000_audio_system.m4a"))
        let callbacks = LockedCounter()
        let queue = RemixQueue(directoryLister: { _ in throw CocoaError(.fileReadNoPermission) })
        await queue.setOnSegmentComplete { _, result in
            if case .failed = result {} else { Issue.record("Listing failure was successful") }
            callbacks.increment()
        }
        await queue.enqueue(.init(segmentDirectory: dir, timePrefix: "120000", capturedDurationSeconds: 1,
            audioInputs: [], silenceMusic: false, micMetadataJSON: nil, audioDiagnostics: recorder))
        await queue.waitForCompletion()
        let failed = root.appendingPathComponent("120000.failed")
        #expect(callbacks.count == 1)
        #expect(try Data(contentsOf: failed.appendingPathComponent("120000_audio_system.m4a")) == bytes)
        let capture = try terminalCapture(failed)
        let sources = try #require(capture["sources"] as? [[String: Any]])
        #expect(sources.count == 1 && sources[0]["received_frames"] as? Int == 960)
        #expect(sources[0]["accepted_frames"] as? Int == 480)
        #expect(sources[0]["statistics_complete"] as? Bool == false)
        #expect((capture["failures"] as? [[String: Any]])?.first?["stage"] as? String == "listing")
    }

    @Test func corruptVideoFallsBackToRealFragmentedAudioAndPreservesBadSibling() async throws {
        let root = try makeTempDirectory("audio-fragment-orphan")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = try SingleTrackAudioWriter(url: dir.appendingPathComponent("120000_audio_system.m4a"),
            trackType: .systemAudio, segmentStartTime: .zero)
        for second in 0..<3 {
            writer.appendPCMBuffer(try terminalPCM(frames: 48_000, frequency: Double(220 + second * 220)),
                presentationTime: CMTime(seconds: Double(second), preferredTimescale: 48_000))
        }
        _ = await writer.finish()
        let badVideo = Data("corrupt video retained".utf8)
        let badAudio = Data("corrupt sibling retained".utf8)
        try badVideo.write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))
        try badAudio.write(to: dir.appendingPathComponent("120000_audio_bad-mic.m4a"))
        let outcomes = LockedValue<SegmentReconciliation>()
        let queue = RemixQueue()
        await queue.setOnSegmentComplete { _, outcome in outcomes.set(outcome) }
        await queue.enqueue(.init(segmentDirectory: dir, timePrefix: "120000", capturedDurationSeconds: nil,
            audioInputs: [], silenceMusic: false, micMetadataJSON: nil))
        await queue.waitForCompletion()
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let final = try #require(dirs.first(where: { $0.lastPathComponent.hasPrefix("120000_") }))
        let key = final.lastPathComponent
        #expect(key == "120000_3")
        #expect(try Data(contentsOf: final.appendingPathComponent("\(key)_display_42_screen.mp4")) == badVideo)
        #expect(try Data(contentsOf: final.appendingPathComponent("\(key)_audio_bad-mic.m4a")) == badAudio)
        let audio = final.appendingPathComponent("\(key)_audio.m4a")
        let samples = try await terminalDecode(audio)
        #expect(abs(samples.count - 144_000) <= 1024)
        for second in 0..<3 {
            let window = samples[(second * 48_000 + 12_000)..<(second * 48_000 + 36_000)]
            let crossings = zip(window, window.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
            #expect(abs(Double(crossings) * 2 - Double(220 + second * 220)) < 12)
        }
        let meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: final.appendingPathComponent("\(key)_meta.json"))) as? [String: Any])
        let rows = try #require((meta["audio_capture"] as? [String: Any])?["remix"] as? [[String: Any]])
        #expect(rows.contains(where: { $0["source_id"] as? String == "bad-mic" && $0["state"] as? String == "unreadable" }))
        if case .audioLoss(1) = outcomes.current {} else { Issue.record("Unreadable sibling was concealed") }
    }
}

private func terminalJob(_ result: SegmentCaptureResult) -> RemixQueue.RemixJob {
    .init(segmentDirectory: result.segmentDirectory, timePrefix: result.timePrefix, capturedDurationSeconds: result.capturedDurationSeconds,
        audioInputs: result.audioInputs, silenceMusic: result.silenceMusic, micMetadataJSON: result.micMetadataJSON,
        audioDiagnostics: result.audioDiagnostics, audioOwnership: result.audioOwnership)
}

private func terminalCapture(_ dir: URL) throws -> [String: Any] {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("120000_meta.json"))) as? [String: Any]
    return try #require(root?["audio_capture"] as? [String: Any])
}

private func terminalPCM(frames: Int, frequency: Double) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames { buffer.floatChannelData![0][frame] = frequency == 0 ? 0 : Float(0.2 * sin(2 * .pi * frequency * Double(frame) / 48_000)) }
    return buffer
}

private func terminalDecode(_ url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(output)
    #expect(reader.startReading())
    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        let block = try #require(CMSampleBufferGetDataBuffer(buffer))
        var decoded = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: decoded.count * 4, destination: &decoded) == noErr)
        samples.append(contentsOf: decoded)
    }
    #expect(reader.status == .completed)
    return samples
}
