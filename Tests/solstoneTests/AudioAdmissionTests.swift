// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import SolstoneCore
import Testing
@testable import solstone

@Suite("Audio admission", .serialized)
struct AudioAdmissionTests {
    @Test(arguments: [(48_000.0, 1, 4_096, 12), (44_100.0, 1, 4_096, 11),
                      (96_000.0, 16, 10_000, 4), (48_000.5, 1, 4_096, 12)])
    func quietBatchOvershootKeepsEveryFrameAndQueuedOwnership(fixture: (Double, Int, Int, Int)) async throws {
        let (rate, channels, frames, quietCount) = fixture
        let root = try makeTempDirectory("quiet-batch-overshoot"); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"),
            trackType: .systemAudio, segmentStartTime: .zero)
        let chunks = LockedArray<(Int, Double)>([]), calls = LockedCounter(), hold = AdmissionNativeHold()
        writer._silentBufferAdmissionForTesting = { count, time in chunks.append((count, time.seconds)); return true }
        writer._nativeAppendHookForTesting = { calls.increment(); if calls.count == 2 { hold.enter() } }
        defer { hold.release() }
        var receipts: [AudioWriteReceipt] = []
        for index in 0..<(quietCount + 2) {
            let tone = index == quietCount ? 660.0 : 0
            let pcm = try admissionPCM(frames: frames, frequency: tone, rate: rate, channels: AVAudioChannelCount(channels))
            let time = CMTime(seconds: Double(index * frames) / rate, preferredTimescale: 1_000_000_000)
            // Microphone admission is mono; multichannel input follows the
            // production system-audio CMSampleBuffer boundary.
            let receipt = channels == 1 ? writer.enqueuePCMBuffer(pcm, presentationTime: time)
                : writer.enqueueAudio(try admissionSample(pcm, time: time))
            receipts.append(try #require(receipt))
        }
        let fence = writer.makeObservationFence()
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1) }
        #expect(!fence.isComplete && receipts.allSatisfy { !$0.signal.isComplete })
        #expect(writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.writer.rawValue].jobs == receipts.count)
        admissionBudgetIsBounded(writer.mediaBudget)
        hold.release(); await fence.wait()
        #expect(receipts.allSatisfy { $0.signal.isComplete })
        _ = await writer.finish()
        let stats = writer.statisticsSnapshot, total = (quietCount + 2) * frames
        #expect(stats.receivedFrames == total && stats.acceptedFrames == total && stats.droppedFrames == 0)
        #expect(stats.generatedFrames == 0 && stats.failures.isEmpty && stats.statisticsComplete == true)
        let generated = chunks.all
        #expect(generated.count >= 3)
        for (count, _) in generated {
            #expect(count > 0 && Double(count) / rate <= 1)
            #expect(count * channels * 4 <= AudioMediaBudget.bytesPerStage / 2)
        }
        #expect(abs(generated[0].1) < 1 / rate)
        #expect(abs(generated[1].1 - Double(generated[0].0) / rate) < 1 / rate)
        if channels == 16 { #expect(generated[0].0 * channels * 4 == AudioMediaBudget.bytesPerStage / 2) }
        let decoded = try #require(try await admissionDecode(writer.url).first)
        #expect(abs(decoded.count - Int((Double(total) * 48_000 / rate).rounded())) <= 2)
        let markerStart = Double(quietCount * frames) / rate
        #expect(admissionRMS(decoded, start: 0.025, end: min(0.5, markerStart - 0.025)) < 0.002)
        #expect(admissionTone(decoded, frequency: 660, start: markerStart + 0.025,
            end: markerStart + Double(frames) / rate - 0.025) > 0.08)
        #expect(hold.timeouts.count == 0)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test(arguments: [false, true])
    func laterQuietChunkFailurePreservesPrefixAndAccountsForEveryRejectedFrame(allocation: Bool) async throws {
        let root = try makeTempDirectory("quiet-chunk-failure"); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"),
            trackType: .systemAudio, segmentStartTime: .zero)
        let calls = LockedCounter()
        if allocation {
            writer._silentBufferAdmissionForTesting = { _, _ in calls.increment(); return calls.count != 2 }
        } else {
            writer._appendAdmissionForTesting = { _ in calls.increment(); return calls.count != 2 }
        }
        var receipts: [AudioWriteReceipt] = []
        for index in 0..<14 {
            let frequency = index < 12 ? 0.0 : 660.0
            receipts.append(try #require(writer.enqueuePCMBuffer(try admissionPCM(frames: 4_096, frequency: frequency),
                presentationTime: CMTime(value: Int64(index * 4_096), timescale: 48_000))))
        }
        await writer.makeObservationFence().wait(); _ = await writer.finish()
        let stats = writer.statisticsSnapshot
        #expect(stats.receivedFrames == 14 * 4_096 && stats.acceptedFrames == 48_000)
        #expect(stats.droppedFrames == 14 * 4_096 - 48_000 && stats.generatedFrames == 0)
        #expect(stats.receivedFrames == stats.acceptedFrames + stats.droppedFrames && stats.statisticsComplete == true)
        #expect(stats.failures.contains { $0.stage == (allocation ? "silence" : "append") })
        #expect(receipts.allSatisfy { $0.signal.isComplete })
        let decoded = try #require(try await admissionDecode(writer.url).first)
        #expect(decoded.count == 48_000 && admissionRMS(decoded, start: 0.025, end: 0.975) < 0.002)
        #expect(admissionTone(decoded, frequency: 660, start: 0.025, end: 0.975) < 0.002)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0], [AVAudioChannelCount(1), AVAudioChannelCount(2)])
    func normalBurstChargesRawAndNativeWorkUntilActualAcceptance(rate: Double, channels: AVAudioChannelCount) async throws {
        let root = try makeTempDirectory("normal-admission"); defer { try? FileManager.default.removeItem(at: root) }
        let device = admissionDevice("normal", rate: rate), shared = MicrophoneCaptureManager()
        let capture = ExternalMicCapture(device: device, gain: 1); shared._installForTesting(capture)
        shared.updateSelection([device])
        let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "normal", captureManager: shared,
            startMicrophoneCapture: { _ in })
        let host = mach_absolute_time(); manager.setSegmentStartTime(admissionHostTime(host))
        _ = try manager.addMicrophone(device)
        let writer = try #require(manager._sourceWriterForTesting(device.uid)), hold = AdmissionNativeHold()
        writer._nativeStartWritingHookForTesting = { hold.enter() }; defer { hold.release() }
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = Int(rate / 10), pcm = try admissionPCM(frames: frames, frequency: 220, rate: rate, channels: channels)
        capture._suspendProcessingForTesting()
        for index in 0..<10 {
            capture._enqueueForTesting(pcm, targetFormat: target, when: admissionWhen(host, frame: Int64(index * frames), rate: rate))
        }
        let raw = writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.raw.rawValue]
        #expect(raw.jobs == 10 && raw.bytes == 10 * frames * Int(channels) * 4)
        #expect(raw.equivalentFrames == 48_000)
        admissionBudgetIsBounded(writer.mediaBudget)
        capture._resumeProcessingForTesting()
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1) }
        _ = manager.prepareToFinishCapture() // real conversion EOS, still outside native writer lock
        try await withTimeout(seconds: 2) { await capture.drainConversion() }
        let pending = writer.statisticsSnapshot
        #expect(pending.receivedFrames == 48_000 && pending.acceptedFrames == 0 && pending.droppedFrames == 0)
        #expect(writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.raw.rawValue].jobs == 0)
        #expect(writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.writer.rawValue].jobs > 0)
        admissionBudgetIsBounded(writer.mediaBudget)
        hold.release()
        let inputs = try await withTimeout(seconds: 2) { await manager.finishAll() }
        let finishedInput = try #require(inputs.first)
        let decoded = try #require(try await admissionDecode(finishedInput.url).first)
        #expect(decoded.count == 48_000)
        for index in 0..<10 {
            #expect(admissionTone(decoded, frequency: 220, start: Double(index) / 10 + 0.025,
                end: Double(index) / 10 + 0.075) > 0.08)
        }
        let final = writer.statisticsSnapshot
        #expect(final.receivedFrames == 48_000 && final.acceptedFrames == 48_000 && final.droppedFrames == 0)
        #expect(final.statisticsComplete == true && final.failures.isEmpty && hold.timeouts.count == 0)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test func ordinaryObservationHasFixedWatermarkWhileLaterMediaContinues() async throws {
        let root = try makeTempDirectory("observation-watermark"); defer { try? FileManager.default.removeItem(at: root) }
        let device = admissionDevice("watermark"), shared = MicrophoneCaptureManager(), capture = ExternalMicCapture(device: admissionDevice("watermark"), gain: 1)
        shared._installForTesting(capture); shared.updateSelection([device])
        let host = mach_absolute_time(), writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"),
            trackType: .microphone(name: device.name, deviceUID: device.uid), segmentStartTime: admissionHostTime(host),
            mediaBudget: shared.mediaBudget(for: device.uid))
        shared.setQueuedCallback(for: device.uid, callback: { writer.enqueuePCMBuffer($0, presentationTime: $1) }, onError: { writer.reportCaptureFailure($0) })
        let first = AdmissionNativeHold(), later = AdmissionNativeHold(), calls = LockedCounter(), observed = LockedCounter()
        writer._nativeAppendHookForTesting = { calls.increment(); if calls.count == 1 { first.enter() } else { later.enter() } }
        capture._observationQueuedForTesting = { observed.increment() }
        defer { first.release(); later.release() }
        capture._enqueueForTesting(try admissionPCM(frames: 4_800, frequency: 220), when: admissionWhen(host, frame: 0, rate: 48_000))
        try await withTimeout(seconds: 2) { await first.entered.waitUntilCount(1) }
        let finished = LockedCounter(), observation = Task { await capture.drain(); finished.increment() }
        try await withTimeout(seconds: 2) { await observed.waitUntilCount(1) }
        for index in 1..<10 {
            capture._enqueueForTesting(try admissionPCM(frames: 4_800, frequency: 440), when: admissionWhen(host, frame: Int64(index * 4_800), rate: 48_000))
        }
        try await withTimeout(seconds: 2) { await capture.drainConversion() }
        #expect(writer.statisticsSnapshot.receivedFrames == 48_000 && finished.count == 0)
        first.release()
        try await withTimeout(seconds: 2) { await later.entered.waitUntilCount(1); await observation.value }
        #expect(finished.count == 1 && writer.statisticsSnapshot.acceptedFrames == 4_800)
        #expect(writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.writer.rawValue].jobs == 9)
        later.release(); shared.clearAllCallbacks(); await capture.drain()
        _ = await writer.finish()
        let decoded = try #require(try await admissionDecode(writer.url).first)
        #expect(admissionTone(decoded, frequency: 220, start: 0.025, end: 0.075) > 0.08)
        #expect(admissionTone(decoded, frequency: 440, start: 0.925, end: 0.975) > 0.08)
        #expect(writer.statisticsSnapshot.acceptedFrames == 48_000 && writer.statisticsSnapshot.failures.isEmpty)
        #expect(first.timeouts.count == 0 && later.timeouts.count == 0)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @MainActor
    @Test(arguments: ["startWriting", "startSession", "append"])
    func nativeHoldCannotBlockActualSystemDetachment(phase: String) async throws {
        let root = try makeTempDirectory("system-admission"); defer { try? FileManager.default.removeItem(at: root) }
        let system = SystemAudioCaptureManager(streamFactory: { _, _, _ in FakeCaptureStream() })
        try await system.start(filter: SCContentFilter())
        let origin = CMClockGetTime(CMClockGetHostTimeClock())
        let old = PerSourceAudioManager(outputDirectory: root, timePrefix: "old")
        old.bindSystemAudioBudget(system.mediaBudget); old.setSegmentStartTime(origin)
        _ = try old.startSystemAudio()
        let writer = try #require(old._sourceWriterForTesting("system")), hold = AdmissionNativeHold()
        if phase == "startWriting" { writer._nativeStartWritingHookForTesting = { hold.enter() } }
        if phase == "startSession" { writer._nativeStartSessionHookForTesting = { hold.enter() } }
        if phase == "append" { writer._nativeAppendHookForTesting = { hold.enter() } }
        defer { hold.release() }
        system.setCallback { old.appendSystemAudio($0) }
        let output = try #require(system._streamOutputForTesting)
        let deliveryClock = ContinuousClock(), deliveryStart = deliveryClock.now
        output.deliverAudio(try admissionSample(admissionPCM(frames: 4_800, frequency: 220), time: origin))
        #expect(deliveryStart.duration(to: deliveryClock.now) < .milliseconds(100))
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1) }
        for index in 1..<10 {
            let pcm = try admissionPCM(frames: 4_800, frequency: 220)
            let sample = try admissionSample(pcm, time: CMTimeAdd(origin, CMTime(value: Int64(index * 4_800), timescale: 48_000)))
            output.deliverAudio(sample)
            // Destroy the producer's content after delivery. Queued ownership
            // must preserve the marker rather than retain mutable storage.
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            #expect(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: CMBlockBufferGetDataLength(block)) == noErr)
        }
        let clock = ContinuousClock(), start = clock.now
        system.clearCallback()
        let next = PerSourceAudioManager(outputDirectory: root, timePrefix: "new")
        next.bindSystemAudioBudget(system.mediaBudget); next.setSegmentStartTime(origin)
        _ = try next.startSystemAudio()
        system.setCallback { next.appendSystemAudio($0) }
        let pending = writer.statisticsSnapshot
        #expect(start.duration(to: clock.now) < .milliseconds(100))
        #expect(pending.receivedFrames == 48_000 && pending.acceptedFrames == 0 && pending.droppedFrames == 0)
        #expect(system.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.writer.rawValue].jobs == 10)
        output.deliverAudio(try admissionSample(admissionPCM(frames: 4_800, frequency: 440), time: origin))
        // A same-source later writer finishes while the earlier one remains held.
        let newer = try await withTimeout(seconds: 2) { await next.finishAll() }
        let newTrack = try #require(newer.first)
        let newPCM = try #require(try await admissionDecode(newTrack.url).first)
        #expect(admissionTone(newPCM, frequency: 440, start: 0.025, end: 0.075) > 0.08)
        #expect(!writer.nativeWriterIsQuiescent && writer.statisticsSnapshot.acceptedFrames == 0)
        system.clearCallback(); hold.release()
        let older = try await withTimeout(seconds: 2) { await old.finishAll() }
        let oldTrack = try #require(older.first)
        let decoded = try #require(try await admissionDecode(oldTrack.url).first)
        #expect(decoded.count == 48_000)
        for index in 0..<10 {
            #expect(admissionTone(decoded, frequency: 220, start: Double(index) / 10 + 0.025,
                end: Double(index) / 10 + 0.075) > 0.08)
            #expect(admissionTone(decoded, frequency: 440, start: Double(index) / 10 + 0.025,
                end: Double(index) / 10 + 0.075) < 0.01)
        }
        let final = writer.statisticsSnapshot
        #expect(final.receivedFrames == 48_000 && final.acceptedFrames == 48_000 && final.droppedFrames == 0)
        #expect(final.failures.isEmpty && final.statisticsComplete == true)
        #expect(hold.timeouts.count == 0)
        admissionBudgetIsEmpty(system.mediaBudget)
        await system.stop()
    }

    @Test func subsecondSilenceObservationWaitsForNativeAcceptanceWithoutEOS() async throws {
        let root = try makeTempDirectory("quiet-admission"); defer { try? FileManager.default.removeItem(at: root) }
        let device = admissionDevice("quiet"), capture = ExternalMicCapture(device: admissionDevice("quiet"), gain: 1)
        let shared = MicrophoneCaptureManager(); shared._installForTesting(capture)
        shared.updateSelection([device])
        let origin = mach_absolute_time(), writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("quiet.m4a"),
            trackType: .microphone(name: "quiet", deviceUID: device.uid), segmentStartTime: admissionHostTime(origin),
            mediaBudget: shared.mediaBudget(for: device.uid))
        shared.setQueuedCallback(for: device.uid, callback: { writer.enqueuePCMBuffer($0, presentationTime: $1) },
            onError: { writer.reportCaptureFailure($0) })
        let hold = AdmissionNativeHold(); writer._nativeAppendHookForTesting = { hold.enter() }; defer { hold.release() }
        capture._enqueueForTesting(try admissionPCM(frames: 4_800, frequency: 0), when: admissionWhen(origin, frame: 0, rate: 48_000))
        let finished = LockedCounter()
        let drain = Task { await capture.drain(); finished.increment() }
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1) }
        #expect(finished.count == 0 && writer.statisticsSnapshot.acceptedFrames == 0)
        #expect(writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.writer.rawValue].jobs == 1)
        hold.release(); await drain.value
        #expect(writer.statisticsSnapshot.acceptedFrames == 4_800)
        #expect(capture._conversionStatusForTesting == nil) // same-rate input never needs converter EOS
        capture._enqueueForTesting(try admissionPCM(frames: 4_800, frequency: 660), when: admissionWhen(origin, frame: 4_800, rate: 48_000))
        await capture.drain(); shared.clearAllCallbacks()
        _ = await writer.finish()
        let decoded = try #require(try await admissionDecode(writer.url).first)
        #expect(decoded.count == 9_600)
        #expect(admissionRMS(decoded, start: 0.025, end: 0.075) < 0.002)
        #expect(admissionTone(decoded, frequency: 660, start: 0.125, end: 0.175) > 0.08)
        #expect(writer.statisticsSnapshot.receivedFrames == 9_600 && writer.statisticsSnapshot.acceptedFrames == 9_600)
        #expect(writer.statisticsSnapshot.failures.isEmpty && hold.timeouts.count == 0)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test func tinyWriterJobsAreBoundedAndRejectionEvidenceCannotQueueUnboundedReports() async throws {
        let root = try makeTempDirectory("tiny-writer-admission"); defer { try? FileManager.default.removeItem(at: root) }
        let reports = LockedArray<AudioWriterStatistics>([])
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("tiny.m4a"), trackType: .systemAudio,
            segmentStartTime: .zero, onStatistics: { reports.append($0) })
        let hold = AdmissionNativeHold(), reportHold = AdmissionNativeHold()
        writer._nativeStartWritingHookForTesting = { hold.enter() }
        writer._reportAdmissionHookForTesting = { reportHold.enter() }
        defer { hold.release(); reportHold.release() }
        let pcm = try admissionPCM(frames: 1, frequency: 0)
        #expect(writer.enqueuePCMBuffer(pcm, presentationTime: .zero) != nil)
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1); await reportHold.entered.waitUntilCount(1) }
        for index in 1..<1_000 {
            let receipt = writer.enqueuePCMBuffer(pcm, presentationTime: CMTime(value: Int64(index), timescale: 48_000))
            #expect((receipt != nil) == (index < 64))
        }
        let evidence = writer.statisticsSnapshot
        #expect(evidence.receivedFrames == 1_000 && evidence.acceptedFrames == 0 && evidence.droppedFrames == 936)
        #expect(evidence.failures.contains { $0.stage == "admission_queue" })
        #expect(evidence.failures.first { $0.stage == "admission_terminal" }?.count == 935)
        #expect(reportHold.entered.count == 1)
        let usage = writer.mediaBudget.snapshot
        #expect(usage.stages[AudioMediaBudget.Stage.writer.rawValue].jobs == 64)
        #expect(usage.stages[AudioMediaBudget.Stage.writer.rawValue].bytes == 64 * 4)
        admissionBudgetIsBounded(writer.mediaBudget)
        let complete = LockedCounter(), finishing = Task { _ = await writer.finish(); complete.increment() }
        #expect(complete.count == 0)
        hold.release(); await finishing.value
        #expect(writer.statisticsSnapshot.acceptedFrames == 64 && writer.statisticsSnapshot.droppedFrames == 936)
        #expect(writer.statisticsSnapshot.generatedFrames == 0)
        #expect(writer.statisticsSnapshot.failures.contains { $0.stage == "admission_queue" })
        reportHold.release()
        try await withTimeout(seconds: 2) {
            while reports.all.count < 2 { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(reportHold.entered.count <= 2)
        #expect(hold.timeouts.count == 0 && reportHold.timeouts.count == 0)
        admissionBudgetIsEmpty(writer.mediaBudget)
        #expect(try await admissionDecode(writer.url).first?.isEmpty == false)
    }

    @Test func nativeMicHoldKeepsConsentAndPhysicalStopPromptAndSiblingIndependent() async throws {
        let root = try makeTempDirectory("mic-native-admission"); defer { try? FileManager.default.removeItem(at: root) }
        let a = admissionDevice("a"), b = admissionDevice("b"), ea = AdmissionEngine(), eb = AdmissionEngine()
        let ca = ExternalMicCapture(device: a, gain: 1, engineFactory: { ea }, resolveDeviceID: { _ in 1 })
        let cb = ExternalMicCapture(device: b, gain: 1, engineFactory: { eb }, resolveDeviceID: { _ in 2 })
        let shared = MicrophoneCaptureManager(gain: 1, captureFactory: { device, _, _ in device.uid == "a" ? ca : cb })
        shared.updateSelection([a, b])
        let host = mach_absolute_time(), manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "old", captureManager: shared)
        manager.setSegmentStartTime(admissionHostTime(host)); _ = try manager.addMicrophone(a); _ = try manager.addMicrophone(b)
        let writer = try #require(manager._sourceWriterForTesting("a")), sibling = try #require(manager._sourceWriterForTesting("b")), hold = AdmissionNativeHold()
        writer._nativeStartWritingHookForTesting = { hold.enter() }; defer { hold.release() }
        ea.emit(try admissionPCM(frames: 4_800, frequency: 220), when: admissionWhen(host, frame: 0, rate: 48_000))
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1) }
        ea.emit(try admissionPCM(frames: 4_800, frequency: 440), when: admissionWhen(host, frame: 4_800, rate: 48_000))
        eb.emit(try admissionPCM(frames: 9_600, frequency: 660), when: admissionWhen(host, frame: 0, rate: 48_000))
        await ca.drainConversion(); await cb.drain()
        #expect(writer.statisticsSnapshot.receivedFrames == 9_600 && writer.statisticsSnapshot.acceptedFrames == 0)
        #expect(sibling.statisticsSnapshot.acceptedFrames == 9_600)
        let clock = ContinuousClock(), start = clock.now
        shared.updateSelection([b])
        manager.deselectMicrophone(deviceUID: "a")
        #expect(start.duration(to: clock.now) < .milliseconds(100))
        #expect(ea.teardown == ["stop", "remove"])
        // Retired engine PCM, even after re-enable, cannot regain its old epoch.
        ea.emit(try admissionPCM(frames: 4_800, frequency: 880), when: admissionWhen(host, frame: 9_600, rate: 48_000))
        shared.updateSelection([a, b])
        ea.emit(try admissionPCM(frames: 4_800, frequency: 880), when: admissionWhen(host, frame: 14_400, rate: 48_000))
        await ca.drainConversion()
        #expect(writer.statisticsSnapshot.receivedFrames == 9_600 && writer.statisticsSnapshot.failures.isEmpty)
        hold.release(); let inputs = await manager.finishAll()
        let old = try #require(inputs.first { $0.timingInfo.trackType.sourceID == "a" })
        let healthy = try #require(inputs.first { $0.timingInfo.trackType.sourceID == "b" })
        let oldPCM = try #require(try await admissionDecode(old.url).first)
        let healthyPCM = try #require(try await admissionDecode(healthy.url).first)
        #expect(abs(oldPCM.count - 9_600) <= 1_024)
        #expect(admissionTone(oldPCM, frequency: 220, start: 0.025, end: 0.075) > 0.08)
        #expect(admissionTone(oldPCM, frequency: 440, start: 0.125, end: 0.175) > 0.08)
        #expect(admissionTone(healthyPCM, frequency: 660, start: 0.125, end: 0.175) > 0.08)
        #expect(writer.statisticsSnapshot.receivedFrames == 9_600 && writer.statisticsSnapshot.acceptedFrames == 9_600)
        #expect(writer.statisticsSnapshot.failures.isEmpty && sibling.statisticsSnapshot.failures.isEmpty && hold.timeouts.count == 0)
        shared.stopAll(); admissionBudgetIsEmpty(writer.mediaBudget); admissionBudgetIsEmpty(sibling.mediaBudget)
    }

    @Test func rawJobSaturationIsPromptStickyAcrossRevocationAndCaptureReplacement() async throws {
        let root = try makeTempDirectory("raw-admission"); defer { try? FileManager.default.removeItem(at: root) }
        let device = admissionDevice("raw"), shared = MicrophoneCaptureManager(), capture = ExternalMicCapture(device: admissionDevice("raw"), gain: 1)
        shared._installForTesting(capture); shared.updateSelection([device])
        let host = mach_absolute_time(), reports = LockedArray<AudioWriterStatistics>([])
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("old.m4a"), trackType: .microphone(name: "raw", deviceUID: device.uid),
            segmentStartTime: admissionHostTime(host), mediaBudget: shared.mediaBudget(for: device.uid), onStatistics: { reports.append($0) })
        shared.setQueuedCallback(for: device.uid, callback: { writer.enqueuePCMBuffer($0, presentationTime: $1) }, onError: { writer.reportCaptureFailure($0) })
        capture._enqueueForTesting(try admissionPCM(frames: 4_800, frequency: 220), when: admissionWhen(host, frame: 0, rate: 48_000))
        await capture.drain()
        try await withTimeout(seconds: 2) { while reports.all.isEmpty { try await Task.sleep(for: .milliseconds(1)) } }
        let reportHold = AdmissionNativeHold(); writer._reportAdmissionHookForTesting = { reportHold.enter() }; defer { reportHold.release() }
        capture._suspendProcessingForTesting()
        let tiny = try admissionPCM(frames: 1, frequency: 0)
        for index in 0..<1_000 {
            capture._enqueueForTesting(tiny, when: admissionWhen(host, frame: Int64(4_800 + index), rate: 48_000))
        }
        try await withTimeout(seconds: 2) { await reportHold.entered.waitUntilCount(1) }
        let snapshot = writer.statisticsSnapshot
        #expect(snapshot.receivedFrames == 4_800 && snapshot.acceptedFrames == 4_800 && snapshot.droppedFrames == 0)
        #expect(snapshot.statisticsComplete == false)
        #expect(snapshot.failures.first { $0.stage == "admission_capture" }?.count == 936)
        #expect(writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.raw.rawValue].jobs == 64)
        #expect(reportHold.entered.count == 1)
        admissionBudgetIsBounded(writer.mediaBudget)
        let clock = ContinuousClock(), start = clock.now
        shared.updateSelection([])
        _ = capture.detachForBoundary()
        shared.updateSelection([device])
        #expect(start.duration(to: clock.now) < .milliseconds(100))
        let replacement = ExternalMicCapture(device: device, gain: 1); shared._installForTesting(replacement)
        #expect(replacement.mediaBudget === writer.mediaBudget)
        let next = try SingleTrackAudioWriter(url: root.appendingPathComponent("new.m4a"), trackType: .microphone(name: "raw", deviceUID: device.uid),
            segmentStartTime: admissionHostTime(host), mediaBudget: shared.mediaBudget(for: device.uid))
        shared.setQueuedCallback(for: device.uid, callback: { next.enqueuePCMBuffer($0, presentationTime: $1) }, onError: { next.reportCaptureFailure($0) })
        replacement._enqueueForTesting(try admissionPCM(frames: 4_800, frequency: 660), when: admissionWhen(host, frame: 0, rate: 48_000))
        // The old source has all64 raw slots. A replacement cannot evade that
        // source-wide limit; it incurs its own rejection rather than inheriting
        // the old936 failures. A new destination becomes healthy after release.
        #expect(next.statisticsSnapshot.receivedFrames == 0 && next.statisticsSnapshot.acceptedFrames == 0)
        #expect(next.statisticsSnapshot.failures.first { $0.stage == "admission_capture" }?.count == 1)
        _ = await next.finish()
        #expect(writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.raw.rawValue].jobs == 64)
        capture._resumeProcessingForTesting(); await capture.drainConversion(); _ = await writer.finish()
        let final = writer.statisticsSnapshot
        #expect(final.receivedFrames == 4_800 && final.acceptedFrames == 4_800 && final.droppedFrames == 0)
        #expect(final.statisticsComplete == false && final.failures.first { $0.stage == "admission_capture" }?.count == 936)
        #expect(final.generatedFrames == 0)
        let healthy = try SingleTrackAudioWriter(url: root.appendingPathComponent("healthy.m4a"), trackType: .microphone(name: "raw", deviceUID: device.uid),
            segmentStartTime: admissionHostTime(host), mediaBudget: shared.mediaBudget(for: device.uid))
        shared.setQueuedCallback(for: device.uid, callback: { healthy.enqueuePCMBuffer($0, presentationTime: $1) }, onError: { healthy.reportCaptureFailure($0) })
        replacement._enqueueForTesting(try admissionPCM(frames: 4_800, frequency: 660), when: admissionWhen(host, frame: 0, rate: 48_000))
        await replacement.drain(); _ = replacement.detachForBoundary(); await replacement.drainConversion(); _ = await healthy.finish()
        #expect(healthy.statisticsSnapshot.receivedFrames == 4_800 && healthy.statisticsSnapshot.acceptedFrames == 4_800 && healthy.statisticsSnapshot.failures.isEmpty)
        reportHold.release()
        let oldPCM = try #require(try await admissionDecode(writer.url).first), newPCM = try #require(try await admissionDecode(healthy.url).first)
        #expect(admissionTone(oldPCM, frequency: 220, start: 0.025, end: 0.075) > 0.08)
        #expect(admissionTone(newPCM, frequency: 660, start: 0.025, end: 0.075) > 0.08)
        #expect(reportHold.timeouts.count == 0)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test(arguments: ["copy", "oversized"])
    func rawRejectionReservesBeforeCopyAndKeepsCountsHonest(cause: String) async throws {
        let root = try makeTempDirectory("raw-copy-admission"); defer { try? FileManager.default.removeItem(at: root) }
        let device = admissionDevice(cause), capture = ExternalMicCapture(device: admissionDevice(cause), gain: 1), shared = MicrophoneCaptureManager()
        shared._installForTesting(capture); shared.updateSelection([device])
        let host = mach_absolute_time(), writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"),
            trackType: .microphone(name: cause, deviceUID: cause), segmentStartTime: admissionHostTime(host), mediaBudget: shared.mediaBudget(for: cause))
        shared.setQueuedCallback(for: cause, callback: { writer.enqueuePCMBuffer($0, presentationTime: $1) }, onError: { writer.reportCaptureFailure($0) })
        capture._enqueueForTesting(try admissionPCM(frames: 4_800, frequency: 220), when: admissionWhen(host, frame: 0, rate: 48_000)); await capture.drain()
        let copies = LockedCounter(); capture._copyAdmissionForTesting = { _ in copies.increment(); return false }
        let rejected = try admissionPCM(frames: cause == "oversized" ? 96_000 : 4_800, frequency: 440)
        capture._enqueueForTesting(rejected, when: admissionWhen(host, frame: 4_800, rate: 48_000))
        #expect(copies.count == (cause == "copy" ? 1 : 0))
        #expect(writer.statisticsSnapshot.receivedFrames == 4_800 && writer.statisticsSnapshot.acceptedFrames == 4_800 && writer.statisticsSnapshot.droppedFrames == 0)
        #expect(writer.statisticsSnapshot.failures.contains { $0.stage == "admission_capture" })
        shared.clearAllCallbacks(); await capture.drainConversion(); _ = await writer.finish()
        #expect(writer.statisticsSnapshot.statisticsComplete == false)
        let decoded = try #require(try await admissionDecode(writer.url).first)
        #expect(decoded.count == 4_800 && admissionTone(decoded, frequency: 220, start: 0.025, end: 0.075) > 0.08)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test func rawAndInFlightWriterPCMRemainChargedTogether() async throws {
        let root = try makeTempDirectory("aggregate-admission"); defer { try? FileManager.default.removeItem(at: root) }
        let device = admissionDevice("aggregate"), shared = MicrophoneCaptureManager(), capture = ExternalMicCapture(device: admissionDevice("aggregate"), gain: 1)
        shared._installForTesting(capture); shared.updateSelection([device])
        let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "aggregate", captureManager: shared, startMicrophoneCapture: { _ in })
        let host = mach_absolute_time(); manager.setSegmentStartTime(admissionHostTime(host)); _ = try manager.addMicrophone(device)
        let writer = try #require(manager._sourceWriterForTesting(device.uid)), hold = AdmissionNativeHold()
        writer._nativeStartWritingHookForTesting = { hold.enter() }; defer { hold.release() }
        let firstPCM = try admissionPCM(frames: 4_800, frequency: 220), laterPCM = try admissionPCM(frames: 4_800, frequency: 440)
        for index in 0..<10 { capture._enqueueForTesting(firstPCM, when: admissionWhen(host, frame: Int64(index * 4_800), rate: 48_000)) }
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1); await capture.drainConversion() }
        capture._suspendProcessingForTesting()
        for index in 10..<20 { capture._enqueueForTesting(laterPCM, when: admissionWhen(host, frame: Int64(index * 4_800), rate: 48_000)) }
        let usage = writer.mediaBudget.snapshot
        #expect(usage.stages[AudioMediaBudget.Stage.raw.rawValue].bytes == 48_000 * 4)
        #expect(usage.stages[AudioMediaBudget.Stage.writer.rawValue].bytes == 48_000 * 4)
        #expect(usage.stages[AudioMediaBudget.Stage.raw.rawValue].jobs == 10 && usage.stages[AudioMediaBudget.Stage.writer.rawValue].jobs == 10)
        #expect(usage.stages[AudioMediaBudget.Stage.temporary.rawValue].peakBytes > 0)
        admissionBudgetIsBounded(writer.mediaBudget)
        capture._resumeProcessingForTesting(); _ = manager.prepareToFinishCapture(); await capture.drainConversion()
        #expect(writer.statisticsSnapshot.receivedFrames == 96_000 && writer.statisticsSnapshot.acceptedFrames == 0)
        hold.release(); let inputs = await manager.finishAll(), input = try #require(inputs.first)
        let decoded = try #require(try await admissionDecode(input.url).first)
        #expect(decoded.count == 96_000)
        #expect(admissionTone(decoded, frequency: 220, start: 0.925, end: 0.975) > 0.08)
        #expect(admissionTone(decoded, frequency: 440, start: 1.925, end: 1.975) > 0.08)
        #expect(writer.statisticsSnapshot.acceptedFrames == 96_000 && writer.statisticsSnapshot.failures.isEmpty && hold.timeouts.count == 0)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test(arguments: [false, true])
    func writerCapacityRejectsByDurationAndBytesBeforeCopy(byteLimit: Bool) async throws {
        let root = try makeTempDirectory("writer-capacity"); defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"), trackType: .systemAudio, segmentStartTime: .zero)
        let hold = AdmissionNativeHold(), copies = LockedCounter()
        writer._nativeStartWritingHookForTesting = { hold.enter() }; writer._copyAdmissionForTesting = { _ in copies.increment(); return true }
        defer { hold.release() }
        let frames = byteLimit ? 4_800 : 48_000, channels: AVAudioChannelCount = byteLimit ? 16 : 1
        let pcm = try admissionPCM(frames: frames, frequency: 220, channels: channels), admitted = byteLimit ? 13 : 4
        for index in 0..<admitted {
            #expect(writer.enqueueAudio(try admissionSample(pcm, time: CMTime(value: Int64(index * frames), timescale: 48_000))) != nil)
        }
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1) }
        #expect(writer.enqueueAudio(try admissionSample(pcm, time: CMTime(value: Int64(admitted * frames), timescale: 48_000))) == nil)
        #expect(copies.count == admitted)
        let usage = writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.writer.rawValue]
        #expect(usage.jobs == admitted && usage.bytes == admitted * frames * Int(channels) * 4)
        #expect(byteLimit ? usage.bytes > 3 * 1_024 * 1_024 : usage.equivalentFrames == 192_000)
        let pending = writer.statisticsSnapshot
        #expect(pending.receivedFrames == (admitted + 1) * frames && pending.acceptedFrames == 0 && pending.droppedFrames == frames)
        #expect(pending.failures.contains { $0.stage == "admission_queue" })
        admissionBudgetIsBounded(writer.mediaBudget)
        hold.release(); _ = await writer.finish()
        let final = writer.statisticsSnapshot
        #expect(final.receivedFrames == (admitted + 1) * frames && final.acceptedFrames + final.droppedFrames == final.receivedFrames)
        #expect(final.failures.contains { $0.stage == "admission_queue" } && final.generatedFrames == 0)
        if !byteLimit {
            #expect(final.acceptedFrames == 192_000 && final.droppedFrames == 48_000)
            let decoded = try #require(try await admissionDecode(writer.url).first)
            #expect(decoded.count == 192_000 && admissionTone(decoded, frequency: 220, start: 3.925, end: 3.975) > 0.08)
        }
        #expect(hold.timeouts.count == 0); admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test(arguments: [false, true])
    func rawCapacityRejectsByDurationAndBytesWithPromptEvidence(byteLimit: Bool) async throws {
        let root = try makeTempDirectory("raw-capacity"); defer { try? FileManager.default.removeItem(at: root) }
        let device = admissionDevice("capacity"), shared = MicrophoneCaptureManager(), capture = ExternalMicCapture(device: admissionDevice("capacity"), gain: 1)
        shared._installForTesting(capture); shared.updateSelection([device])
        let host = mach_absolute_time(), writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"), trackType: .microphone(name: device.name, deviceUID: device.uid),
            segmentStartTime: admissionHostTime(host), mediaBudget: shared.mediaBudget(for: device.uid))
        shared.setQueuedCallback(for: device.uid, callback: { writer.enqueuePCMBuffer($0, presentationTime: $1) }, onError: { writer.reportCaptureFailure($0) })
        let copies = LockedCounter(); capture._copyAdmissionForTesting = { _ in copies.increment(); return true }
        let frames = byteLimit ? 4_800 : 48_000, channels: AVAudioChannelCount = byteLimit ? 16 : 1, admitted = byteLimit ? 13 : 4
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pcm = try admissionPCM(frames: frames, frequency: 220, channels: channels)
        capture._suspendProcessingForTesting()
        for index in 0...admitted {
            capture._enqueueForTesting(pcm, targetFormat: target, when: admissionWhen(host, frame: Int64(index * frames), rate: 48_000))
        }
        #expect(copies.count == admitted)
        let usage = writer.mediaBudget.snapshot.stages[AudioMediaBudget.Stage.raw.rawValue]
        #expect(usage.jobs == admitted && usage.bytes == admitted * frames * Int(channels) * 4)
        #expect(byteLimit ? usage.bytes > 3 * 1_024 * 1_024 : usage.equivalentFrames == 192_000)
        #expect(writer.statisticsSnapshot.failures.first { $0.stage == "admission_capture" }?.count == 1)
        #expect(writer.statisticsSnapshot.receivedFrames == 0 && writer.statisticsSnapshot.droppedFrames == 0)
        admissionBudgetIsBounded(writer.mediaBudget)
        _ = capture.detachForBoundary(); capture._resumeProcessingForTesting(); await capture.drainConversion(); _ = await writer.finish()
        #expect(writer.statisticsSnapshot.receivedFrames == admitted * frames && writer.statisticsSnapshot.droppedFrames == admitted * frames)
        #expect(writer.statisticsSnapshot.acceptedFrames == 0 && writer.statisticsSnapshot.statisticsComplete == false)
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @Test func twoRotationsKeepConvertedTailInOldWriterAndNewSegmentsIndependent() async throws {
        let root = try makeTempDirectory("admission-rotations"); defer { try? FileManager.default.removeItem(at: root) }
        let device = admissionDevice("rotating", rate: 44_100), shared = MicrophoneCaptureManager(), capture = ExternalMicCapture(device: admissionDevice("rotating", rate: 44_100), gain: 1)
        shared._installForTesting(capture); shared.updateSelection([device])
        let base = mach_absolute_time(), target = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)), hold = AdmissionNativeHold()
        defer { hold.release() }
        let oldCompletion = LockedCounter()
        var writers: [SingleTrackAudioWriter] = [], oldFinish: Task<[AudioRemixerInput], Never>?, outputs: [AudioRemixerInput] = []
        for segment in 0..<3 {
            let origin = base + AVAudioTime.hostTime(forSeconds: Double(segment)), rate = segment == 2 ? 96_000.0 : 44_100.0
            capture.gainMultiplier = segment == 0 ? 1 : 2
            let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "s\(segment)", captureManager: shared, startMicrophoneCapture: { _ in })
            manager.setSegmentStartTime(admissionHostTime(origin)); _ = try manager.addMicrophone(device)
            let writer = try #require(manager._sourceWriterForTesting(device.uid)); writers.append(writer)
            if segment == 0 {
                let lastFrames = LockedValue<Int>()
                writer._appendAdmissionForTesting = { frames in lastFrames.set(frames); return true }
                writer._nativeAppendHookForTesting = { if (lastFrames.current ?? Int.max) < 1_000 { hold.enter() } }
            }
            capture._suspendProcessingForTesting()
            let frames = Int(rate / 10)
            for index in 0..<10 {
                let pcm = try admissionPCM(frames: frames, frequency: index == 9 ? 660 : 220, rate: rate)
                capture._enqueueForTesting(pcm, targetFormat: target, when: admissionWhen(origin, frame: Int64(index * frames), rate: rate))
            }
            _ = manager.prepareToFinishCapture(); capture._resumeProcessingForTesting(); await capture.drainConversion()
            #expect(writer.statisticsSnapshot.receivedFrames == 48_000)
            if segment == 0 {
                try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1) }
                #expect(writer.statisticsSnapshot.acceptedFrames < 48_000)
                oldFinish = Task { let result = await manager.finishAll(); oldCompletion.increment(); return result }
            } else {
                let finished = try await withTimeout(seconds: 2) { await manager.finishAll() }
                outputs += finished
                #expect(oldCompletion.count == 0 && !writers[0].nativeWriterIsQuiescent)
                #expect(writer.statisticsSnapshot.acceptedFrames == 48_000 && writer.statisticsSnapshot.failures.isEmpty)
            }
            admissionBudgetIsBounded(writer.mediaBudget)
        }
        hold.release(); if let oldFinish { outputs += await oldFinish.value }
        #expect(oldCompletion.count == 1 && outputs.count == 3)
        for input in outputs {
            let decoded = try #require(try await admissionDecode(input.url).first)
            #expect(decoded.count == 48_000)
            #expect(admissionTone(decoded, frequency: 660, start: 0.925, end: 0.975) > 0.08)
            let amplitude = admissionTone(decoded, frequency: 220, start: 0.425, end: 0.475)
            if input.url.lastPathComponent.hasPrefix("s0_") { #expect(amplitude > 0.15 && amplitude < 0.25) }
            else { #expect(amplitude > 0.35 && amplitude < 0.45) }
        }
        for writer in writers {
            #expect(writer.statisticsSnapshot.receivedFrames == 48_000 && writer.statisticsSnapshot.acceptedFrames == 48_000 && writer.statisticsSnapshot.droppedFrames == 0)
            #expect(writer.statisticsSnapshot.failures.isEmpty && writer.statisticsSnapshot.statisticsComplete == true)
        }
        #expect(hold.timeouts.count == 0); admissionBudgetIsEmpty(writers[0].mediaBudget)
    }

    @Test func admissionCopyFailurePreservesPrefixThroughRealRemix() async throws {
        let root = try makeTempDirectory("admission-prefix"); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recorder = try AudioCaptureRecorder(directory: dir, timePrefix: "120000", expected: [("system", "system")])
        try recorder.admitSource("system", kind: "system")
        let writer = try SingleTrackAudioWriter(url: dir.appendingPathComponent("120000_audio_system.m4a"), trackType: .systemAudio,
            segmentStartTime: .zero, onStatistics: { recorder.statistics("system", $0) })
        writer.enqueueAudio(try admissionSample(admissionPCM(frames: 4_800, frequency: 220), time: .zero))
        await writer.makeObservationFence().wait()
        writer._copyAdmissionForTesting = { _ in false }
        writer.enqueueAudio(try admissionSample(admissionPCM(frames: 4_800, frequency: 660), time: CMTime(value: 4_800, timescale: 48_000)))
        writer.enqueueAudio(try admissionSample(admissionPCM(frames: 4_800, frequency: 880), time: CMTime(value: 9_600, timescale: 48_000)))
        let info = await writer.finish(captureCutoff: CMTime(value: 19_200, timescale: 48_000)), stats = writer.statisticsSnapshot
        #expect(stats.receivedFrames == 14_400 && stats.acceptedFrames == 4_800 && stats.droppedFrames == 9_600)
        #expect(stats.generatedFrames == 0 && stats.failures.contains { $0.stage == "admission_copy" })
        let original = try Data(contentsOf: writer.url)
        let prefix = try #require(try await admissionDecode(writer.url).first)
        #expect(prefix.count == 4_800 && admissionTone(prefix, frequency: 220, start: 0.025, end: 0.075) > 0.15)
        try recorder.seal()
        let queue = RemixQueue()
        await queue.enqueue(.init(segmentDirectory: dir, timePrefix: "120000", capturedDurationSeconds: 4,
            audioInputs: [.init(url: writer.url, timingInfo: info)], silenceMusic: false, micMetadataJSON: nil,
            audioDiagnostics: recorder, audioOwnership: AudioNativeOwnership { writer.nativeWriterIsQuiescent }))
        await queue.waitForCompletion()
        let final = root.appendingPathComponent("120000_4")
        #expect(try Data(contentsOf: final.appendingPathComponent("120000_4_audio_system.m4a")) == original)
        let mixed = try #require(try await admissionDecode(final.appendingPathComponent("120000_4_audio.m4a")).first)
        #expect(mixed.count == 4_800 && admissionTone(mixed, frequency: 220, start: 0.025, end: 0.075) > 0.15)
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: final.appendingPathComponent("120000_4_meta.json"))) as? [String: Any]
        #expect((meta?["audio_capture"] as? [String: Any])?["state"] as? String == "partial")
        admissionBudgetIsEmpty(writer.mediaBudget)
    }

    @MainActor
    @Test func actualSegmentTimeoutQuarantinesReadablePrefixDuringHeldAppend() async throws {
        let root = try makeTempDirectory("admission-quarantine"); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("120000.incomplete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = PerSourceAudioManager(outputDirectory: dir, timePrefix: "120000")
        let system = SystemAudioCaptureManager(streamFactory: { _, _, _ in FakeCaptureStream() })
        let segment = SegmentWriter(outputDirectory: dir, timePrefix: "120000", audioFinishTimeoutSeconds: 0.02,
            screenshotCapturerFactory: { _, _, _, _, _, _ in FakeScreenshotCapturer() }, audioManagerFactory: { _, _, _, _ in manager })
        try await segment.start(sources: .screen, displayInfos: [DisplayInfo(displayID: 42, width: 100, height: 100,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100))], audioFilter: SCContentFilter(), systemAudioCaptureManager: system)
        let writer = try #require(manager._sourceWriterForTesting("system")), output = try #require(system._streamOutputForTesting)
        let origin = writer._segmentStartTimeForTesting
        for index in 0..<20 {
            output.deliverAudio(try admissionSample(admissionPCM(frames: 4_800, frequency: 220),
                time: CMTimeAdd(origin, CMTime(value: Int64(index * 4_800), timescale: 48_000))))
        }
        await writer.makeObservationFence().wait()
        #expect(writer.statisticsSnapshot.acceptedFrames == 96_000)
        let prefixURL = root.appendingPathComponent("prefix.m4a")
        try Data(contentsOf: writer.url).write(to: prefixURL)
        let prefix = try #require(try await admissionDecode(prefixURL).first)
        #expect(prefix.count > 4_800 && admissionTone(prefix, frequency: 220, start: 0.025, end: 0.075) > 0.08)
        let hold = AdmissionNativeHold(), completed = LockedCounter()
        writer._nativeAppendHookForTesting = { hold.enter() }; writer.onComplete = { completed.increment() }; defer { hold.release() }
        output.deliverAudio(try admissionSample(admissionPCM(frames: 4_800, frequency: 660),
            time: CMTimeAdd(origin, CMTime(value: 96_000, timescale: 48_000))))
        try await withTimeout(seconds: 2) { await hold.entered.waitUntilCount(1) }
        let clock = ContinuousClock(), start = clock.now
        let result = try #require(await segment.finishCapture())
        #expect(start.duration(to: clock.now) < .milliseconds(100))
        #expect(result.audioInputs.isEmpty && writer.statisticsSnapshot.receivedFrames == 100_800)
        #expect(writer.statisticsSnapshot.acceptedFrames == 96_000 && !writer.nativeWriterIsQuiescent)
        let probes = LockedCounter(), remixes = LockedCounter(), queue = RemixQueue(
            durationLoader: { _ in probes.increment(); return CMTime(seconds: 2, preferredTimescale: 600) },
            nativeQuiescenceTimeoutSeconds: 0.01, remixerFactory: { _ in remixes.increment(); return FakeRemixer(.success) })
        await queue.enqueue(.init(segmentDirectory: result.segmentDirectory, timePrefix: result.timePrefix,
            capturedDurationSeconds: result.capturedDurationSeconds, audioInputs: result.audioInputs, silenceMusic: false,
            micMetadataJSON: result.micMetadataJSON, audioDiagnostics: result.audioDiagnostics, audioOwnership: result.audioOwnership))
        await queue.waitForCompletion()
        #expect(probes.count == 0 && remixes.count == 0)
        let failed = root.appendingPathComponent("120000.failed"), metadata = failed.appendingPathComponent("120000_meta.json")
        let frozen = try Data(contentsOf: metadata)
        #expect(FileManager.default.fileExists(atPath: failed.appendingPathComponent("120000_audio_system.m4a").path))
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: failed.path)
        let scanner = IncompleteSegmentRecovery(capturesDirectory: root, finalizer: queue)
        #expect(await scanner.recoverAll() == 0)
        hold.release()
        try await withTimeout(seconds: 2) { await completed.waitUntilCount(1) }
        #expect(try Data(contentsOf: metadata) == frozen)
        #expect(!FileManager.default.fileExists(atPath: dir.path) && hold.timeouts.count == 0)
        admissionBudgetIsEmpty(writer.mediaBudget)
        await system.stop()
    }
}

private final class AdmissionEngine: MicrophoneCaptureEngine, @unchecked Sendable {
    let configurationObject: AnyObject = NSObject()
    private let lock = NSLock()
    private var callback: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var trace: [String] = []
    var teardown: [String] { lock.withLock { trace } }
    func start(deviceID: AudioDeviceID, deviceName: String, onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        lock.withLock { callback = onPCM }
    }
    func stop() { lock.withLock { trace.append("stop") } }
    func removeTap() throws { lock.withLock { trace.append("remove") } }
    func emit(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) { lock.withLock { callback }?(buffer, when) }
}

private final class AdmissionNativeHold: @unchecked Sendable {
    let entered = LockedCounter(), timeouts = LockedCounter()
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    func enter() {
        entered.increment()
        if lock.withLock({ released }) { return }
        if releaseGate.wait(timeout: .now() + 10) == .timedOut { timeouts.increment() }
    }
    func release() { lock.withLock { released = true }; releaseGate.signal() }
}

private func admissionDevice(_ uid: String, rate: Double = 48_000) -> AudioInputDevice {
    AudioInputDevice(id: 1, name: uid, uid: uid, manufacturer: nil, sampleRate: rate, transportType: .usb)
}
private func admissionHostTime(_ host: UInt64) -> CMTime {
    CMClockMakeHostTimeFromSystemUnits(host)
}
private func admissionWhen(_ host: UInt64, frame: Int64, rate: Double) -> AVAudioTime {
    AVAudioTime(hostTime: host + AVAudioTime.hostTime(forSeconds: Double(frame) / rate), sampleTime: frame, atRate: rate)
}
private func admissionPCM(frames: Int, frequency: Double, rate: Double = 48_000, channels: AVAudioChannelCount = 1) throws -> AVAudioPCMBuffer {
    let format: AVAudioFormat
    if channels <= 2 { format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)) }
    else {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    pcm.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(channels) {
        for frame in 0..<frames { pcm.floatChannelData![channel][frame] = Float(0.2 * sin(2 * .pi * frequency * Double(frame) / rate)) }
    }
    return pcm
}
private func admissionSample(_ pcm: AVAudioPCMBuffer, time: CMTime) throws -> CMSampleBuffer {
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
private func admissionDecode(_ url: URL) async throws -> [[Float]] {
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
private func admissionRMS(_ samples: [Float], start: Double, end: Double) -> Double {
    let lower = Int(start * 48_000), upper = Int(end * 48_000)
    #expect(lower >= 0 && upper <= samples.count && upper > lower)
    guard lower >= 0, upper <= samples.count, upper > lower else { return .infinity }
    return sqrt(samples[lower..<upper].reduce(0) { $0 + Double($1 * $1) } / Double(upper - lower))
}
private func admissionTone(_ samples: [Float], frequency: Double, start: Double, end: Double) -> Double {
    let lower = Int(start * 48_000), upper = Int(end * 48_000)
    #expect(lower >= 0 && upper <= samples.count && upper > lower)
    guard lower >= 0, upper <= samples.count, upper > lower else { return 0 }
    var sine = 0.0, cosine = 0.0
    for index in lower..<upper {
        let phase = 2 * Double.pi * frequency * Double(index) / 48_000
        sine += Double(samples[index]) * sin(phase); cosine += Double(samples[index]) * cos(phase)
    }
    return 2 * hypot(sine, cosine) / Double(upper - lower)
}
private func admissionBudgetIsBounded(_ budget: AudioMediaBudget) {
    let snapshot = budget.snapshot
    #expect(snapshot.peakTotalBytes <= 12 * 1_024 * 1_024)
    for stage in AudioMediaBudget.Stage.allCases {
        let usage = snapshot.stages[stage.rawValue]
        #expect(usage.bytes >= 0 && usage.bytes <= AudioMediaBudget.bytesPerStage)
        #expect(usage.equivalentFrames >= 0 && usage.equivalentFrames <= AudioMediaBudget.framesPerStage)
        #expect(usage.jobs >= 0 && usage.jobs <= (stage == .temporary ? 8 : 64))
        #expect(usage.peakBytes <= AudioMediaBudget.bytesPerStage && usage.peakJobs <= (stage == .temporary ? 8 : 64))
    }
}
private func admissionBudgetIsEmpty(_ budget: AudioMediaBudget) {
    admissionBudgetIsBounded(budget)
    for usage in budget.snapshot.stages { #expect(usage.bytes == 0 && usage.equivalentFrames == 0 && usage.jobs == 0) }
}
