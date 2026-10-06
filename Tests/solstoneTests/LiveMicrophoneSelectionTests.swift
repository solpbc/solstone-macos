// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import SolstoneCore
import Testing
@preconcurrency import ScreenCaptureKit
@testable import solstone

@Suite("Live microphone selection")
@MainActor
struct LiveMicrophoneSelectionTests {
    private func device(_ uid: String, optIn: Bool = false) -> AudioInputDevice {
        AudioInputDevice(id: 0, name: uid, uid: uid, manufacturer: nil, sampleRate: 48_000,
            transportType: optIn ? .aggregate : .usb)
    }
    private func sourceRows(_ root: URL) throws -> [[String: Any]] {
        let meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("120000_meta.json"))) as? [String: Any])
        return try #require((meta["audio_capture"] as? [String: Any])?["sources"] as? [[String: Any]])
    }

    @Test func liveChangesAndHotplugUseCurrentPolicyForEveryDevice() async throws {
        let root = try makeTempDirectory("live-selection"); defer { try? FileManager.default.removeItem(at: root) }
        let a = device("a"), b = device("b", optIn: true)
        var available = [a, b]
        let segments = LockedArray<ConsentSegment>([])
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = ConsentSegment(directory); segments.append(segment); return segment
            }, finalizer: FakeFinalizer(), microphoneDevices: { available })
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        let segment = try #require(segments.all.last)
        #expect(segment.activeMicrophoneUIDs() == ["a"])
        manager.updateMicrophoneSelection(disabled: ["a"], enabled: ["b"])
        #expect(segment.activeMicrophoneUIDs() == ["b"] && manager.activeSources == .microphone)
        manager.updateMicrophoneSelection(disabled: ["a"], enabled: [])
        #expect(segment.activeMicrophoneUIDs().isEmpty && manager.activeSources.isEmpty)
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        #expect(segment.activeMicrophoneUIDs() == ["a"])
        #expect(segment.disconnected.isEmpty)

        available = [a, device("c"), device("d"), device("e"), device("f"), device("g")]
        manager.updateMicrophoneSelection(disabled: ["a"], enabled: [])
        await manager.handleDeviceChange(added: [a, device("g")], removed: [])
        #expect(Set(segment.activeMicrophoneUIDs()) == ["c", "d", "e", "f", "g"])
        available.removeAll { $0.uid == "c" }
        await manager.handleDeviceChange(added: [], removed: [device("c")])
        #expect(Set(segment.activeMicrophoneUIDs()) == ["d", "e", "f", "g"])
        #expect(segment.disconnected == ["c"])
        _ = await manager.enqueueTransition(.stop(reason: .user))
        let count = segments.all.count
        manager.updateMicrophoneSelection(disabled: [], enabled: ["b"])
        #expect(segments.all.count == count)
    }

    @Test(arguments: [CaptureSources.microphone, .all])
    func initiallyExcludedMicrophonesKeepIntentAcrossRotationAndPause(sources: CaptureSources) async throws {
        let root = try makeTempDirectory("empty-selection"); defer { try? FileManager.default.removeItem(at: root) }
        let a = device("a"), segments = LockedArray<ConsentSegment>([])
        let time = LockedValue<Date>(); time.set(Date(timeIntervalSince1970: 1_700_000_000))
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = ConsentSegment(directory); segments.append(segment); return segment
            }, finalizer: FakeFinalizer(), now: { time.current! }, allowsEmptyDisplayConfigurationForTesting: true,
            microphoneDevices: { [a] })
        let outcome = await manager.enqueueTransition(.start(reason: .user, sources: sources, disabledMicUIDs: ["a"], enabledMicUIDs: []))
        guard case .committed = outcome else { Issue.record("Intentional empty selection must commit"); return }
        #expect(manager.currentAudioCaptureIssue == nil)
        #expect(segments.all.last?.activeMicrophoneUIDs().isEmpty == true)
        time.set(Date(timeIntervalSince1970: 1_700_000_060))
        _ = await manager.enqueueTransition(.rotate(reason: .boundary))
        #expect(manager.state.isRecording && manager.currentAudioCaptureIssue == nil)
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        let count = segments.all.count
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        #expect(segments.all.count == count)
        time.set(Date(timeIntervalSince1970: 1_700_000_120))
        _ = await manager.enqueueTransition(.resume(reason: .user))
        #expect(segments.all.last?.activeMicrophoneUIDs() == ["a"])
        #expect(manager.activeSources.contains(.microphone))
        manager.updateMicrophoneSelection(disabled: ["a"], enabled: [])
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        #expect(segments.all.last?.activeMicrophoneUIDs() == ["a"])
        _ = await manager.enqueueTransition(.stop(reason: .user))
    }

    @Test(arguments: [false, true])
    func newerSelectionWinsDuringStartupAndRotation(rotating: Bool) async throws {
        let root = try makeTempDirectory("selection-await"); defer { try? FileManager.default.removeItem(at: root) }
        let a = device("a"), b = device("b", optIn: true), segments = LockedArray<ConsentSegment>([])
        let opened = OneShotContinuationGate(), entered = LatchedEvent(), time = LockedValue<Date>()
        time.set(Date(timeIntervalSince1970: 1_700_000_000))
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let shouldGate = segments.all.count == (rotating ? 1 : 0)
                let segment = ConsentSegment(directory, gate: shouldGate ? opened : nil, entered: shouldGate ? entered : nil)
                segments.append(segment); return segment
            }, finalizer: FakeFinalizer(), now: { time.current! }, microphoneDevices: { [a, b] })
        if rotating {
            _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
            time.set(Date(timeIntervalSince1970: 1_700_000_060))
        }
        let operation = Task { @MainActor in
            if rotating { return await manager.enqueueTransition(.rotate(reason: .boundary)) }
            return await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        }
        try await withTimeout(seconds: 1) { await entered.wait() }
        manager.updateMicrophoneSelection(disabled: ["a"], enabled: ["b"])
        opened.release(); _ = await operation.value
        #expect(segments.all.last?.activeMicrophoneUIDs() == ["b"])
        #expect(segments.all.last?.startedUIDs == ["b"])
        #expect(manager.currentAudioCaptureIssue == nil)
        _ = await manager.enqueueTransition(.stop(reason: .user))
    }

    @Test func olderQueuedIntentCannotOverwriteAlreadyUpdatedPolicy() async throws {
        let root = try makeTempDirectory("selection-old-intent"); defer { try? FileManager.default.removeItem(at: root) }
        let a = device("a"), b = device("b", optIn: true), box = LockedValue<ConsentSegment>()
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in let segment = ConsentSegment(directory); box.set(segment); return segment },
            finalizer: FakeFinalizer(), microphoneDevices: { [a, b] })
        manager.updateMicrophoneSelection(disabled: ["a"], enabled: ["b"])
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(box.current?.startedUIDs == ["b"])
        _ = await manager.enqueueTransition(.stop(reason: .user))
    }

    @Test(arguments: [false, true])
    func realSegmentStartupDistinguishesRevocationFromFailure(revoked: Bool) async throws {
        let root = try makeTempDirectory("selection-real-start"); defer { try? FileManager.default.removeItem(at: root) }
        let a = device("a"), capture = MicrophoneCaptureManager(), opened = OneShotContinuationGate(), entered = LatchedEvent()
        capture.updateSelection([a])
        let audio = FakeAudioManager(behavior: .throwOnMicrophoneStart)
        let screen = ConsentScreenshot(opened: opened, entered: entered)
        let system = SystemAudioCaptureManager(streamFactory: { _, _, _ in FakeCaptureStream() })
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000",
            screenshotCapturerFactory: { _, _, _, _, _, _ in screen }, audioManagerFactory: { _, _, _, _ in audio })
        let warnings = LockedCounter()
        writer.onCaptureIssue = { _ in warnings.increment() }
        let operation = Task { @MainActor in
            try await writer.start(sources: .all,
                displayInfos: [DisplayInfo(displayID: 1, width: 10, height: 10, bounds: .zero)],
                audioFilter: SCContentFilter(), mics: [a], micCaptureManager: capture, systemAudioCaptureManager: system)
        }
        try await withTimeout(seconds: 1) { await entered.wait() }
        if revoked { capture.updateSelection([]) }
        opened.release()
        #expect(try await operation.value == .screen)
        if !revoked { try await withTimeout(seconds: 1) { await warnings.waitUntilCount(1) } }
        _ = await writer.finishCapture()
        await Task.yield()
        let microphone = try #require(try sourceRows(root).first { $0["source_id"] as? String == "a" })
        let failures = try #require(microphone["failures"] as? [[String: Any]])
        #expect(audio.addMicrophoneCount.count == (revoked ? 0 : 1))
        #expect(failures.isEmpty == revoked)
        #expect((warnings.count == 0) == revoked)
    }

    @Test func realMicOnlyEmptySelectionIsQuietWhetherChosenOrNothingIsConnected() async throws {
        let root = try makeTempDirectory("selection-real-empty"); defer { try? FileManager.default.removeItem(at: root) }
        let shared = MicrophoneCaptureManager(); shared.updateSelection([])
        let audio = FakeAudioManager(), writer = SegmentWriter(outputDirectory: root, timePrefix: "120000",
            audioManagerFactory: { _, _, _, _ in audio })
        #expect(try await writer.start(sources: .microphone, micCaptureManager: shared).isEmpty)
        #expect(audio.addMicrophoneCount.count == 0)
        _ = await writer.finishCapture()
        #expect(try sourceRows(root).flatMap { $0["failures"] as? [[String: Any]] ?? [] }.isEmpty)
    }

    @Test func revocationRejectsOldDestinationsAndPreservesAnotherMicAndRotation() async throws {
        let a = device("a"), b = device("b"), manager = MicrophoneCaptureManager()
        let ca = ExternalMicCapture(device: a), cb = ExternalMicCapture(device: b)
        manager._installForTesting(ca); manager._installForTesting(cb)
        manager.updateSelection([a, b])
        let oldA = LockedCounter(), newA = LockedCounter(), oldB = LockedCounter(), newB = LockedCounter(), errors = LockedCounter()
        manager.setCallback(for: "a", callback: { _, _ in oldA.increment() }, onError: { _ in errors.increment() })
        manager.setCallback(for: "b", callback: { _, _ in oldB.increment() })
        let lateError = ca.onCaptureError
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)); buffer.frameLength = 16
        memset(try #require(buffer.floatChannelData)[0], 0, 16 * 4)
        ca._suspendProcessingForTesting(); cb._suspendProcessingForTesting()
        ca._enqueueForTesting(buffer); cb._enqueueForTesting(buffer)
        manager.updateSelection([b])
        do { try manager.startCapture(for: a); Issue.record("Revoked device must reject before hardware start") } catch {}
        manager.updateSelection([a, b])
        manager.setCallback(for: "a", callback: { _, _ in newA.increment() })
        lateError?(FakeCaptureError.startFailed)
        ca._resumeProcessingForTesting(); cb._resumeProcessingForTesting()
        await ca.drain(); await cb.drain()
        #expect(oldA.count == 0 && newA.count == 0 && oldB.count == 1 && errors.count == 0)
        #expect(manager.getCapture(for: "b") === cb)
        ca._enqueueForTesting(buffer); await ca.drain()
        #expect(newA.count == 1)
        cb._suspendProcessingForTesting(); cb._enqueueForTesting(buffer)
        manager.clearAllCallbacks()
        manager.setCallback(for: "b", callback: { _, _ in newB.increment() })
        cb._resumeProcessingForTesting(); await cb.drain()
        #expect(oldB.count == 2 && newB.count == 0)
        manager.stopAll()
    }

    @Test func revokedResamplerTailCannotReturnThroughReenabledUID() async throws {
        let a = device("a"), manager = MicrophoneCaptureManager()
        let capture = ExternalMicCapture(device: a, gain: 1)
        manager._installForTesting(capture); manager.updateSelection([a])
        let oldFrames = LockedArray<Int>([]), newFrames = LockedArray<Int>([]), errors = LockedCounter()
        manager.setCallback(for: "a", callback: { buffer, _ in oldFrames.append(Int(buffer.frameLength)) }, onError: { _ in errors.increment() })
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4410)); pcm.frameLength = 4410
        for frame in 0..<4410 { pcm.floatChannelData![0][frame] = 0.2 }
        capture._suspendProcessingForTesting(); capture._enqueueForTesting(pcm, targetFormat: target)
        capture._resumeProcessingForTesting(); await capture.drain()
        let prefix = oldFrames.all.reduce(0, +)
        #expect(prefix > 0 && prefix < 4800)
        capture._suspendProcessingForTesting(); capture._enqueueForTesting(pcm, targetFormat: target)
        capture.detachForBoundary()
        manager.updateSelection([])
        manager.updateSelection([a])
        manager.setCallback(for: "a", callback: { buffer, _ in newFrames.append(Int(buffer.frameLength)) })
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(oldFrames.all.reduce(0, +) == prefix && newFrames.all.isEmpty && errors.count == 0)
        manager.stopAll()
    }

    @Test func deliberateDetachRetainsWriterAndEarlierSamplesWithoutFailure() async throws {
        let root = try makeTempDirectory("selection-retained"); defer { try? FileManager.default.removeItem(at: root) }
        let a = device("a"), shared = MicrophoneCaptureManager()
        shared.updateSelection([a])
        let recorder = try AudioCaptureRecorder(directory: root, timePrefix: "120000", expected: [("a", "microphone")])
        let audio = PerSourceAudioManager(outputDirectory: root, timePrefix: "120000", captureManager: shared, startMicrophoneCapture: { _ in })
        audio.bindDiagnostics(recorder)
        _ = try audio.addMicrophone(a)
        let original = try #require(audio._sourceWriterForTesting("a"))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)); buffer.frameLength = 960
        for index in 0..<960 { buffer.floatChannelData![0][index] = 0.3 }
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        original.appendPCMBuffer(buffer, presentationTime: start)
        shared.updateSelection([]); audio.deselectMicrophone(deviceUID: "a")
        shared.updateSelection([a]); _ = try audio.addMicrophone(a)
        #expect(audio._sourceWriterForTesting("a") === original)
        original.appendPCMBuffer(buffer, presentationTime: CMTimeAdd(start, CMTime(value: 960, timescale: 48_000)))
        let inputs = await audio.finishAll(); try recorder.seal()
        #expect(inputs.count == 1)
        #expect((try sourceRows(root).first?["received_frames"] as? Int) == 1920)
        #expect((try sourceRows(root).first?["failures"] as? [[String: Any]])?.isEmpty == true)
    }
}

@MainActor
private final class ConsentSegment: CaptureSegmentWriting {
    let outputDirectory: URL
    private let gate: OneShotContinuationGate?
    private let entered: LatchedEvent?
    private var devices: [String: AudioInputDevice] = [:]
    private(set) var startedUIDs: [String] = []
    private(set) var disconnected: [String] = []
    var onTerminalStop: (@MainActor () -> Void)?
    var onCaptureIssue: (@MainActor (String) -> Void)?
    init(_ directory: URL, gate: OneShotContinuationGate? = nil, entered: LatchedEvent? = nil) {
        outputDirectory = directory; self.gate = gate; self.entered = entered
    }
    func start(sources: CaptureSources, displayInfos: [DisplayInfo], filters: [CGDirectDisplayID: SCContentFilter],
               audioFilter: SCContentFilter?, mics: [AudioInputDevice], micCaptureManager: MicrophoneCaptureManager?,
               systemAudioCaptureManager: SystemAudioCaptureManager?) async throws -> CaptureSources {
        entered?.signal(); await gate?.wait()
        var active = sources.intersection(.screen)
        if sources.contains(.microphone) {
            let current = micCaptureManager?.microphonesForStartup(fallback: mics) ?? mics
            for device in current { try addMicrophone(device) }
            startedUIDs = current.map(\.uid)
            if !current.isEmpty { active.insert(.microphone) }
        }
        return active
    }
    func finishCapture() async -> SegmentCaptureResult? { nil }
    func updateContentFilter(_ filters: [CGDirectDisplayID: SCContentFilter]) async throws {}
    func addMicrophone(_ device: AudioInputDevice) throws { devices[device.uid] = device }
    func removeMicrophone(deviceUID: String) { disconnected.append(deviceUID); devices.removeValue(forKey: deviceUID) }
    func deselectMicrophone(deviceUID: String) { devices.removeValue(forKey: deviceUID) }
    func hasMicrophone(deviceUID: String) -> Bool { devices[deviceUID] != nil }
    func activeMicrophoneUIDs() -> [String] { devices.keys.sorted() }
}

@MainActor
private final class ConsentScreenshot: SegmentScreenshotCapturing {
    let opened: OneShotContinuationGate, entered: LatchedEvent
    var onTerminalStop: (@MainActor () -> Void)?
    init(opened: OneShotContinuationGate, entered: LatchedEvent) { self.opened = opened; self.entered = entered }
    func start() async throws { entered.signal(); await opened.wait() }
    func stop() async {}
    func updateContentFilter(_ filter: SCContentFilter) async {}
    func finishWithTimeout(seconds: Double) async -> Result<(URL, Int), Error>? {
        .success((URL(fileURLWithPath: "/tmp/selection-fake.mp4"), 1))
    }
}
