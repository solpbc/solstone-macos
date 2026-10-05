// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import AVFAudio
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import SolstoneCore
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("Microphone recovery")
struct MicrophoneRecoveryTests {
    private func device(_ id: AudioDeviceID = 10, uid: String = "u", name: String = "mic") -> AudioInputDevice {
        AudioInputDevice(id: id, name: name, uid: uid, manufacturer: nil, sampleRate: 48_000, transportType: .usb)
    }
    private func pcm(_ value: Float = 0.2) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)); buffer.frameLength = 4800
        for index in 0..<4800 { buffer.floatChannelData![0][index] = value }
        return buffer
    }
    private func capture(_ lab: MicEngineLab, _ resolved: LockedValue<AudioDeviceID>, device: AudioInputDevice? = nil) -> ExternalMicCapture {
        ExternalMicCapture(device: device ?? self.device(), gain: 1, engineFactory: { lab.make() },
            resolveDeviceID: { _ in resolved.current }, recoveryDelay: { _ in })
    }

    @Test func freshIdentityCoalescesBurstAndRejectsRetiredPCM() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), old = LockedCounter(), current = LockedCounter(), errors = LockedCounter()
        capture.setCallbacks(audio: { _, _ in old.increment() }, error: { _ in errors.increment() })
        try capture.start()
        let first = lab.engines[0]
        capture._suspendProcessingForTesting()
        first.emit(try pcm()) // admitted before retirement, must reach old writer
        id.set(20)
        for _ in 0..<20 { first.notify() }
        capture.setCallbacks(audio: { _, _ in current.increment() }, error: { _ in errors.increment() })
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(lab.engines.count == 2)
        #expect(lab.engines[0].boundIDs == [10] && lab.engines[1].boundIDs == [20])
        #expect(capture.currentDeviceID == 20 && capture.isCapturing)
        first.notify(); first.emit(try pcm())
        lab.engines[1].emit(try pcm()); await capture.drain()
        #expect(lab.engines.count == 2 && old.count == 1 && current.count == 1 && errors.count == 0)
        #expect(first.teardown == ["stop", "remove"])
        capture.stop()
    }

    @Test func exhaustedBatchCannotRenewAndDetachedErrorsSurviveDrain() async throws {
        let lab = MicEngineLab(failingIndices: [1, 2, 3], selfNotify: true), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), errors = LockedCounter()
        capture.setCallbacks(audio: { _, _ in }, error: { _ in errors.increment() })
        // First engine must not emit a startup notification in this case.
        lab.engines[0].notifyDuringStart = false
        try capture.start()
        capture._suspendProcessingForTesting()
        lab.engines[0].notify()
        capture.setCallbacks(audio: nil, error: nil)
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(lab.engines.count == 4 && errors.count == 3 && !capture.isCapturing)
        #expect(lab.engines.dropFirst().allSatisfy { $0.boundIDs == [10] })
        #expect(Set(lab.engines.map { ObjectIdentifier($0.configurationObject) }).count == 4)
        for engine in lab.engines { for _ in 0..<20 { engine.notify() } }
        await capture.drain()
        #expect(lab.engines.count == 4 && errors.count == 3)
        capture.stop()
    }

    @Test(arguments: [false, true])
    func initialFailureCannotMultiplyItsAttemptBudget(fails: Bool) async throws {
        let lab = MicEngineLab(failingIndices: fails ? [0] : [], selfNotify: true), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), errors = LockedCounter(), received = LockedCounter()
        capture.setCallbacks(audio: { _, _ in received.increment() }, error: { _ in errors.increment() })
        if fails { #expect(throws: FakeCaptureError.self) { try capture.start() } }
        else { try capture.start() }
        // The successful twin's replacement does not emit another notification.
        await capture.drain()
        #expect(lab.engines.count == (fails ? 1 : 2))
        #expect(capture.isCapturing != fails && errors.count == (fails ? 1 : 0))
        lab.engines[0].emit(try pcm()); await capture.drain()
        #expect(received.count == 0)
        capture.stop()
    }

    @Test func missingUIDNeverPinsObsoleteID() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>()
        let capture = capture(lab, id), errors = LockedCounter()
        capture.setCallbacks(audio: { _, _ in }, error: { _ in errors.increment() })
        #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) { try capture.start() }
        await capture.drain()
        #expect(lab.engines[0].boundIDs.isEmpty && errors.count == 1 && !capture.isCapturing)
        capture.stop()
    }

    @Test func stopFencesLateSuccessfulNativeStart() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), entered = LockedCounter(), received = LockedCounter(), errors = LockedCounter()
        let release = DispatchSemaphore(value: 0)
        lab.engines[0].startHook = { entered.increment(); if release.wait(timeout: .now() + 2) != .success { throw FakeCaptureError.startFailed } }
        capture.setCallbacks(audio: { _, _ in received.increment() }, error: { _ in errors.increment() })
        let start = Task.detached { try capture.start() }
        try await withTimeout(seconds: 1) { await entered.waitUntilCount(1) }
        let stop = Task.detached { capture.stop() }
        try await withTimeout(seconds: 1) {
            while capture._captureRequestedForTesting { try await Task.sleep(for: .milliseconds(1)) }
        }
        lab.engines[0].emit(try pcm()); release.signal()
        do { try await start.value; Issue.record("Cancelled start must fail") } catch is CancellationError {}
        await stop.value; await capture.drain()
        #expect(!capture.isCapturing && received.count == 0 && errors.count == 0)
        #expect(lab.engines[0].teardown == ["stop", "remove", "stop", "remove"])
    }

    @Test func redundantStartDoesNotCancelAdmittedConfigurationRecovery() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), admitted = LockedCounter()
        try capture.start()
        let request = capture._requestedEpochForTesting
        capture._suspendProcessingForTesting()
        id.set(20); lab.engines[0].notify()
        capture._startAdmissionHookForTesting = { admitted.increment() }
        let start = Task.detached { try capture.start() }
        try await withTimeout(seconds: 1) { await admitted.waitUntilCount(1) }
        #expect(capture._requestedEpochForTesting == request)
        capture._resumeProcessingForTesting(); try await start.value; await capture.drain()
        #expect(capture.isCapturing && lab.engines.count == 2 && capture.currentDeviceID == 20)
        capture.stop()
    }

    @Test func oldExhaustionCannotParkANewerExplicitStart() async throws {
        let lab = MicEngineLab(failingIndices: [1, 2, 3]), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), errors = LockedCounter(), parked = LockedCounter()
        let release = DispatchSemaphore(value: 0)
        capture.setCallbacks(audio: { _, _ in }, error: { _ in
            errors.increment()
            if errors.count == 3 {
                parked.increment()
                if release.wait(timeout: .now() + 2) != .success { Issue.record("Recovery error gate timed out") }
            }
        })
        try capture.start(); lab.engines[0].notify()
        try await withTimeout(seconds: 1) { await parked.waitUntilCount(1) }
        let oldRequest = capture._requestedEpochForTesting
        let start = Task.detached { try capture.start() }
        try await withTimeout(seconds: 1) {
            while capture._requestedEpochForTesting == oldRequest { try await Task.sleep(for: .milliseconds(1)) }
        }
        release.signal(); try await start.value; await capture.drain()
        #expect(capture.isCapturing && lab.engines.count == 5)
        lab.engines[4].notify(); await capture.drain()
        #expect(capture.isCapturing && lab.engines.count == 6 && errors.count == 3)
        capture.stop()
    }

    @Test func sharedManagerExternalRetryKeepsFourFreshAttempts() throws {
        let lab = MicEngineLab(failingIndices: [0, 1, 2, 3], selfNotify: true), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose,
                engineFactory: { lab.make() }, resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        #expect(throws: FakeCaptureError.self) { try shared.startCapture(for: device()) }
        #expect(lab.engines.count == 4 && lab.engines.allSatisfy { $0.boundIDs == [10] })
        #expect(!shared.hasCapture(for: "u"))
    }

    @Test @MainActor func monitorRefreshAndProductionEventRetainRecoveredWriter() async throws {
        let monitor = AudioDeviceMonitor(startListening: false)
        var events: [(added: [AudioInputDevice], removed: [AudioInputDevice])] = []
        monitor.onDeviceChange = { added, removed in
            #expect(monitor.availableDevices.map(\.id) == added.map(\.id))
            events.append((added, removed))
        }
        monitor.applyDevices([device()]); monitor.applyDevices([device(name: "renamed")]); monitor.applyDevices([device(20)])
        #expect(events.count == 2 && events[1].added.map(\.id) == [20] && events[1].removed.map(\.id) == [10])
        let root = try makeTempDirectory("mic-recovery-retained"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(gain: 1, captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose,
                engineFactory: { lab.make() }, resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        var available = [device(), device(30, uid: "healthy"), device(40, uid: "excluded")]
        let writerBox = LockedValue<PerSourceAudioManager>()
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000",
            audioManagerFactory: { directory, prefix, capture, verbose in
                let audio = PerSourceAudioManager(outputDirectory: directory, timePrefix: prefix, captureManager: capture!, verbose: verbose)
                writerBox.set(audio); return audio
            })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { available }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        manager.updateMicrophoneSelection(disabled: ["excluded"], enabled: [])
        _ = try await writer.start(sources: .microphone, mics: [available[0], available[1]], micCaptureManager: shared)
        manager.seedRecordingForTesting(currentSegment: writer, sources: .microphone)
        let audio = try #require(writerBox.current), original = try #require(audio._sourceWriterForTesting("u"))
        let first = try #require(shared.getCapture(for: "u")), healthy = try #require(shared.getCapture(for: "healthy"))
        lab.engines[0].emit(try pcm(0.2)); await first.drain()
        // Force a genuinely failed installed capture, then traverse the real default-input event.
        first.stop(); id.set(20); available[0] = device(20)
        manager.handleDefaultMicChange(currentID: 20)
        let rebound = try #require(shared.getCapture(for: "u"))
        #expect(rebound !== first && rebound.currentDeviceID == 20 && rebound.isCapturing)
        #expect(shared.getCapture(for: "healthy") === healthy && !shared.hasCapture(for: "excluded"))
        #expect(audio._sourceWriterForTesting("u") === original)
        lab.engines.last!.emit(try pcm(0.4)); await rebound.drain()
        let before = lab.engines.count
        await manager.handleDeviceChange(added: [device(20)], removed: [device(10)])
        #expect(lab.engines.count == before && shared.getCapture(for: "u") === rebound)
        #expect(audio._sourceWriterForTesting("u") === original)
        available.removeAll { $0.uid == "u" }
        await manager.handleDeviceChange(added: [], removed: [device(20)])
        #expect(!shared.hasCapture(for: "u") && !writer.hasMicrophone(deviceUID: "u"))
        let result = try #require(await writer.finishCapture())
        let source = try #require(result.audioInputs.first { $0.timingInfo.trackType.sourceID == "u" })
        let asset = AVURLAsset(url: source.url), reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32])
        reader.add(output); #expect(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var pointer: UnsafeMutablePointer<Int8>?, length = 0
            #expect(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr)
            if let pointer { samples += Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self), count: length / 4)) }
        }
        #expect(reader.status == .completed && samples.count == 9600)
        #expect(samples.prefix(4000).reduce(0, +) / 4000 > 0.15)
        #expect(samples.suffix(4000).reduce(0, +) / 4000 > 0.3)
        let meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("120000_meta.json"))) as? [String: Any])
        let rows = try #require((meta["audio_capture"] as? [String: Any])?["sources"] as? [[String: Any]])
        let failures = try #require(rows.first { $0["source_id"] as? String == "u" }?["failures"] as? [[String: Any]])
        #expect(failures.filter { $0["stage"] as? String == "disconnect" }.count == 1)
        shared.stopAll()
    }
}

private final class MicEngineLab: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MicEngineDouble] = []
    let failingIndices: Set<Int>, selfNotify: Bool
    var engines: [MicEngineDouble] { lock.withLock { stored } }
    init(failingIndices: Set<Int> = [], selfNotify: Bool = false) { self.failingIndices = failingIndices; self.selfNotify = selfNotify }
    func make() -> MicEngineDouble {
        lock.withLock {
            let index = stored.count
            let engine = MicEngineDouble(fails: failingIndices.contains(index), notifyDuringStart: selfNotify && (index == 0 || failingIndices.contains(index)))
            stored.append(engine); return engine
        }
    }
}

private final class MicEngineDouble: MicrophoneCaptureEngine, @unchecked Sendable {
    let configurationObject: AnyObject = NSObject()
    private let lock = NSLock()
    private var pcm: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var ids: [AudioDeviceID] = [], trace: [String] = []
    let fails: Bool
    var notifyDuringStart: Bool
    var startHook: (@Sendable () throws -> Void)?
    var boundIDs: [AudioDeviceID] { lock.withLock { ids } }
    var teardown: [String] { lock.withLock { trace } }
    init(fails: Bool, notifyDuringStart: Bool) { self.fails = fails; self.notifyDuringStart = notifyDuringStart }
    func start(deviceID: AudioDeviceID, deviceName: String, onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        lock.withLock { ids.append(deviceID); pcm = onPCM }
        if notifyDuringStart { for _ in 0..<10 { notify() } }
        try startHook?()
        if fails { throw FakeCaptureError.startFailed }
    }
    func stop() { lock.withLock { trace.append("stop") }; if notifyDuringStart { notify() } }
    func removeTap() throws { lock.withLock { trace.append("remove") } }
    func notify() { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: configurationObject) }
    func emit(_ buffer: AVAudioPCMBuffer) { lock.withLock { pcm }?(buffer, AVAudioTime(hostTime: mach_absolute_time())) }
}
