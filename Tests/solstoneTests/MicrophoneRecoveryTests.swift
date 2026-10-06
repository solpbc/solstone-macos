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
    @Test @MainActor func queuedStartCannotOverrideNewerOwnerPause() async throws {
        let root = try makeTempDirectory("mic-queued-pause-admission")
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        let pause = PauseManager(), gate = MicResumePreparationGate()
        manager.lifecycleManager.ownerPauseIsHeld = { pause.isPaused }
        manager.beforeResumeNativeStartForTesting = { await gate.wait() }
        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        let resume = Task { @MainActor in await executor.enqueue(.resume(reason: .user)) }
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { gate.entered } }
        let start = Task { @MainActor in await executor.enqueue(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: [])) }
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { executor.queuedIntentCountForTesting == 1 } }
        let before = lab.engines.count
        pause.pause(for: .indefinite)
        gate.release()
        _ = await resume.value
        let result = await start.value
        guard case .vetoed = result else { Issue.record("Queued start must honor the current pause"); return }
        #expect(pause.isPaused && lab.engines.count == before && !manager.state.isRecording)
        manager.lifecycleManager.ownerPauseIsHeld = { false }
        _ = await executor.enqueue(.stop(reason: .user)); shared.stopAll()
    }

    @Test(arguments: [false, true]) @MainActor
    func uncommittedResumeRollsBackWhileOtherPauseDoesNotAuthorize(otherPause: Bool) async throws {
        let root = try makeTempDirectory("mic-resume-veto")
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await capture.drain() }
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        if otherPause { _ = await manager.enqueueTransition(.pause(reason: .lock, stopAudio: true)) }
        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { true }, unlockResumeDelay: {})
        _ = await executor.enqueue(.resume(reason: .user))
        #expect(lab.engines.count == (otherPause ? 7 : 8) && manager.state.isPaused)
        #expect(throws: NSError.self) { try shared.startCapture(for: device()) }
        _ = await executor.enqueue(.stop(reason: .user)); shared.stopAll()
    }

    @Test(arguments: [false, true]) @MainActor
    func timedOutNativePrepareCannotAdmitAfterNewOwnerRequestOrHold(held: Bool) async throws {
        let root = try makeTempDirectory("mic-escaped-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await capture.drain() }
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        let gate = MicResumePreparationGate()
        manager.beforeResumeNativeStartForTesting = { await gate.wait() }
        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {}, transitionTimeoutSeconds: 0.05)
        let result = await executor.enqueue(.resume(reason: .user))
        guard case .vetoed = result else { Issue.record("Held prepare must time out"); gate.release(); return }
        #expect(lab.engines.count == 7)
        #expect(throws: NSError.self) { try shared.startCapture(for: device()) }
        if held {
            manager.lifecycleManager.ownerPauseIsHeld = { true }
        } else {
            _ = await executor.enqueue(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
            #expect(manager.state.isRecording && lab.engines.count == 8)
        }
        let newer = manager.currentSegmentForTesting?.outputDirectory
        let before = lab.engines.count
        gate.release()
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { gate.returned } }
        await Task.yield()
        #expect(lab.engines.count == before && manager.currentSegmentForTesting?.outputDirectory == newer)
        if held {
            #expect(throws: NSError.self) { try shared.startCapture(for: device()) }
        } else {
            let current = try #require(shared.getCapture(for: "u"))
            #expect(current.isCapturing)
            for _ in 0..<6 { lab.engines.last!.notify(); await current.drain() }
            #expect(lab.engines.count == before + 6 && current.isCapturing)
        }
        manager.lifecycleManager.ownerPauseIsHeld = { false }
        _ = await executor.enqueue(.stop(reason: .user)); shared.stopAll()
    }

    @Test(arguments: [false, true]) @MainActor
    func actualCoordinatorExplicitResumeRenewsExhaustedSelectedMic(heldIdle: Bool) async throws {
        let root = try makeTempDirectory("mic-coordinator-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        let pause = PauseManager()
        let coordinator = CaptureCoordinator(captureManager: manager, pauseManager: pause,
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false), isTerminating: { false },
            configProvider: { (sources: .microphone, disabled: [], enabled: []) }, bannerSink: { _ in },
            permissionPollScheduler: PermissionPollTestScheduler().scheduler)
        coordinator.microphoneAuthorizationCause = .authorized
        coordinator.microphoneAuthorizationReader = { .authorized }
        coordinator.activate()
        await coordinator.startRecording(reason: .user)
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await capture.drain() }
        #expect(lab.engines.count == 7 && !capture.isCapturing)
        pause.pause(for: .indefinite)
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { manager.state.isPaused } }
        if heldIdle { _ = await manager.enqueueTransition(.stop(reason: .quit)) }
        #expect(pause.isPaused && lab.engines.count == 7)
        await coordinator.toggleRecording()
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { manager.state.isRecording } }
        #expect(lab.engines.count == 8 && shared.getCapture(for: "u")?.isCapturing == true)
        #expect(!pause.isPaused)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func deadlineResumeDoesNotRenewExhaustedMicrophone() async throws {
        let root = try makeTempDirectory("mic-deadline-no-renew")
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await capture.drain() }
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        let result = await manager.enqueueTransition(.resume(reason: .pauseDeadline))
        if case .committed = result { Issue.record("Deadline may not reopen the exhausted microphone") }
        #expect(lab.engines.count == 7)
        #expect(throws: NSError.self) { try shared.startCapture(for: device()) }
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

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

    @Test(arguments: ["healthy", "stopped", "readback", "unreadable", "format", "resolved", "missing"])
    func configurationRecoveryUsesAllCurrentNativeDimensions(change: String) async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = ExternalMicCapture(device: device(), engineFactory: { lab.make() },
            resolveDeviceID: { _ in change == "missing" && lab.engines.count > 0 && !lab.engines[0].boundIDs.isEmpty ? nil : id.current },
            recoveryDelay: { _ in })
        try capture.start()
        let first = lab.engines[0]
        first.configure(isRunning: change != "stopped", readback: change == "unreadable" ? nil : (change == "readback" ? 20 : 10),
            formatUnchanged: change != "format")
        if change == "resolved" { id.set(20) }
        first.notify(); await capture.drain()
        if change == "healthy" {
            #expect(lab.engines.count == 1 && capture.isCapturing && first.teardown.isEmpty)
        } else if change == "missing" {
            #expect(lab.engines.count == 4 && !capture.isCapturing)
            #expect(lab.engines.dropFirst().allSatisfy { $0.boundIDs.isEmpty })
        } else {
            #expect(lab.engines.count == 2 && capture.isCapturing)
            #expect(lab.engines.last?.boundIDs == [change == "resolved" ? 20 : 10])
            #expect(first.teardown == ["stop", "remove"])
        }
        capture.stop()
    }

    @Test func repeatedSuccessfulStartsExhaustOneRequestAndExplicitStopStartRenews() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), errors = LockedArray<String>([])
        capture.setCallbacks(audio: { _, _ in }, error: { errors.append(($0 as NSError).domain) })
        try capture.start()
        for _ in 0..<6 { lab.engines.last!.notify(); await capture.drain() }
        #expect(lab.engines.count == 7 && capture.isCapturing && errors.all.isEmpty)
        capture._suspendProcessingForTesting(); lab.engines.last!.notify()
        capture.setCallbacks(audio: nil, error: nil)
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(lab.engines.count == 7 && !capture.isCapturing && errors.all == ["SolstoneAudioInstability"])
        for engine in lab.engines { engine.notify() }
        #expect(throws: NSError.self) { try capture.start() }
        await capture.drain()
        #expect(lab.engines.count == 7 && errors.all.count == 1)
        capture.stop(); try capture.start()
        #expect(lab.engines.count == 8 && capture.isCapturing)
        capture.stop()
    }

    @Test func finalFailedReplacementAlsoEmitsOneTerminalDiagnostic() async throws {
        let lab = MicEngineLab(failingIndices: [1, 2, 4, 5, 6]), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), errors = LockedArray<String>([])
        capture.setCallbacks(audio: { _, _ in }, error: { errors.append(($0 as NSError).domain) })
        try capture.start(); lab.engines[0].notify(); await capture.drain()
        #expect(lab.engines.count == 4 && capture.isCapturing && errors.all.count == 2)
        lab.engines[3].notify(); await capture.drain()
        #expect(lab.engines.count == 7 && !capture.isCapturing && errors.all.count == 6)
        #expect(errors.all.filter { $0 == "SolstoneAudioInstability" }.count == 1)
        for engine in lab.engines { engine.notify() }; await capture.drain()
        #expect(lab.engines.count == 7 && errors.all.count == 6)
        capture.stop()
    }

    @Test(arguments: ["quiet", "sparse", "media-gap", "invalid-time", "rejected-copy", "rejected-conversion", "rejected-destination"])
    func onlyContinuingQualifiedPCMCanRenewReplacementAllowance(mode: String) async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let clock = LockedValue<Double>(); clock.set(0)
        let capture = ExternalMicCapture(device: device(), gain: 1, engineFactory: { lab.make() },
            resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in }, monotonicNow: { clock.current! })
        let received = LockedCounter(), errors = LockedCounter()
        capture.setCallbacks(audio: { _, _ in received.increment() }, error: { _ in errors.increment() })
        if mode == "rejected-destination" {
            capture.setQueuedCallbacks(audio: { _, _ in nil }, error: { _ in errors.increment() }, rawError: nil, admissionGate: nil)
        }
        try capture.start()
        for _ in 0..<6 { lab.engines.last!.notify(); await capture.drain() }
        let quiet = try pcm(0), base = mach_absolute_time()
        for index in 0...110 {
            let arrival = Double(index) * (mode == "sparse" ? 2 : 0.1)
            clock.set(arrival)
            let sample = Int64(index * (mode == "media-gap" ? 9600 : 4800))
            let when = mode == "invalid-time" ? AVAudioTime(sampleTime: sample, atRate: 48_000) :
                AVAudioTime(hostTime: base + AVAudioTime.hostTime(forSeconds: arrival), sampleTime: sample, atRate: 48_000)
            if mode == "rejected-copy" { capture._copyAdmissionForTesting = { _ in false } }
            if mode == "rejected-conversion" { capture._conversionAdmissionForTesting = { false } }
            lab.engines.last!.emit(quiet, when: when); await capture.drain()
        }
        lab.engines.last!.notify(); await capture.drain()
        #expect(lab.engines.count == (mode == "quiet" ? 8 : 7))
        #expect(capture.isCapturing == (mode == "quiet"))
        if mode == "quiet" { #expect(received.count == 111 && errors.count == 0) }
        capture.stop()
    }

    @Test func admittedRetiredPCMDrainsWithoutRenewingCurrentGeneration() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let clock = LockedValue<Double>(); clock.set(0)
        let capture = ExternalMicCapture(device: device(), gain: 1, engineFactory: { lab.make() },
            resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in }, monotonicNow: { clock.current! })
        let received = LockedCounter(), errors = LockedCounter()
        capture.setCallbacks(audio: { _, _ in received.increment() }, error: { _ in errors.increment() })
        try capture.start()
        for _ in 0..<5 { lab.engines.last!.notify(); await capture.drain() }
        let retired = lab.engines.last!, quiet = try pcm(0), base = mach_absolute_time()
        capture._suspendProcessingForTesting(); retired.notify()
        // 31 jobs / 148800 frames stay within both unchanged raw limits while
        // the qualified arrival interval spans more than ten seconds.
        for index in 0...30 {
            clock.set(Double(index) * 0.4)
            retired.emit(quiet, when: AVAudioTime(hostTime: base + AVAudioTime.hostTime(forSeconds: Double(index) * 0.4),
                sampleTime: Int64(index * 4800), atRate: 48_000))
        }
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(lab.engines.count == 7 && received.count == 31)
        retired.emit(quiet); retired.notify(); await capture.drain()
        lab.engines.last!.notify(); await capture.drain()
        #expect(lab.engines.count == 7 && !capture.isCapturing && errors.count == 1 && received.count == 31)
        capture.stop()
    }

    @Test func detachedDestinationDrainsWithoutRenewingItsReplacement() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let clock = LockedValue<Double>(); clock.set(0)
        let capture = ExternalMicCapture(device: device(), gain: 1, engineFactory: { lab.make() },
            resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in }, monotonicNow: { clock.current! })
        let old = LockedCounter(), current = LockedCounter(), errors = LockedCounter()
        capture.setCallbacks(audio: { _, _ in old.increment() }, error: { _ in errors.increment() })
        try capture.start()
        for _ in 0..<6 { lab.engines.last!.notify(); await capture.drain() }
        let quiet = try pcm(0), base = mach_absolute_time()
        capture._suspendProcessingForTesting()
        for index in 0...30 {
            clock.set(Double(index) * 0.4)
            lab.engines.last!.emit(quiet, when: AVAudioTime(hostTime: base + AVAudioTime.hostTime(forSeconds: Double(index) * 0.4),
                sampleTime: Int64(index * 4800), atRate: 48_000))
        }
        capture.setCallbacks(audio: nil, error: nil)
        capture.setCallbacks(audio: { _, _ in current.increment() }, error: { _ in errors.increment() })
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(old.count == 31 && current.count == 0)
        lab.engines.last!.notify(); await capture.drain()
        #expect(lab.engines.count == 7 && !capture.isCapturing && errors.count == 1)
        capture.stop()
    }

    @Test @MainActor func realManagerEventsAndNextSegmentCannotReopenParkedUIDButOwnerSelectionCan() async throws {
        let root = try makeTempDirectory("mic-parked-selection"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000")
        _ = try await writer.start(sources: .microphone, mics: [device()], micCaptureManager: shared)
        manager.seedRecordingForTesting(currentSegment: writer, sources: .microphone)
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await capture.drain() }
        #expect(lab.engines.count == 7 && !capture.isCapturing)
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        manager.handleDefaultMicChange(currentID: 10)
        await manager.handleDeviceChange(added: [device()], removed: [])
        shared.stopAll()
        for _ in 0..<3 { #expect(throws: NSError.self) { try shared.startCapture(for: device()) } }
        let nextDirectory = root.appendingPathComponent("next")
        try FileManager.default.createDirectory(at: nextDirectory, withIntermediateDirectories: true)
        let next = SegmentWriter(outputDirectory: nextDirectory, timePrefix: "120500")
        do { _ = try await next.start(sources: .microphone, mics: [device()], micCaptureManager: shared); Issue.record("Parked UID cannot start next segment") } catch {}
        #expect(lab.engines.count == 7)
        _ = await next.finishCapture()
        manager.updateMicrophoneSelection(disabled: ["u"], enabled: [])
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        #expect(lab.engines.count == 8 && shared.getCapture(for: "u")?.isCapturing == true)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func onlyExecutingOwnerStartCanReopenParkedMicrophoneOnlySession() async throws {
        let root = try makeTempDirectory("mic-parked-start"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        try shared.startCapture(for: device()); let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await capture.drain() }
        shared.stopAll()
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        let automatic = await manager.enqueueTransition(.start(reason: .autoStart, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        if case .committed = automatic { Issue.record("Automatic start must preserve exhausted request") }
        #expect(lab.engines.count == 7)
        let locked = LockedValue<Bool>(); locked.set(true)
        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { locked.current! }, unlockResumeDelay: {})
        _ = await executor.enqueue(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(throws: NSError.self) { try shared.startCapture(for: device()) }
        // Existing lifecycle behavior prepares then vetoes the segment; that
        // cancelled request must not leave its renewed allowance behind.
        #expect(lab.engines.count == 8)
        locked.set(false)
        let owner = await executor.enqueue(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = owner else { Issue.record("Owner start must renew before native segment starts"); return }
        #expect(lab.engines.count == 9 && manager.state.isRecording)
        _ = await executor.enqueue(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        let current = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await current.drain() }
        #expect(lab.engines.count == 15 && !current.isCapturing)
        #expect(throws: NSError.self) { try shared.startCapture(for: device()) }
        _ = await executor.enqueue(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func ownerStartFromPauseRenewsAnEngineThatStayedRunning() async throws {
        let root = try makeTempDirectory("mic-paused-renewal"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<4 { lab.engines.last!.notify(); await capture.drain() }
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: false))
        #expect(capture.isCapturing && lab.engines.count == 5)
        let outcome = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = outcome else { Issue.record("Owner start from pause must commit"); return }
        #expect(shared.getCapture(for: "u") === capture && lab.engines.count == 5)
        for _ in 0..<6 { lab.engines.last!.notify(); await capture.drain() }
        #expect(lab.engines.count == 11 && capture.isCapturing)
        lab.engines.last!.notify(); await capture.drain()
        #expect(lab.engines.count == 11 && !capture.isCapturing)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test func ownerRenewalFencesAlreadyQueuedRecoveryBeforeManagerReuse() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        try shared.startCapture(for: device()); let old = try #require(shared.getCapture(for: "u"))
        old._suspendProcessingForTesting(); lab.engines[0].notify()
        shared.authorizeMicrophoneRequest()
        #expect(!old.isCapturing)
        let start = Task.detached { try shared.startCapture(for: device()) }
        old._resumeProcessingForTesting(); try await start.value; await old.drain()
        #expect(lab.engines.count == 2 && shared.getCapture(for: "u") !== old)
        #expect(shared.getCapture(for: "u")?.isCapturing == true)
        shared.stopAll()
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

    @Test func sharedManagerExternalRetryUsesFreshEnginesAndLeavesPacingToLiveness() throws {
        let lab = MicEngineLab(failingIndices: [0, 1, 2, 3], selfNotify: true), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose,
                engineFactory: { lab.make() }, resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        #expect(throws: FakeCaptureError.self) { try shared.startCapture(for: device()) }
        #expect(lab.engines.count == 2 && lab.engines.allSatisfy { $0.boundIDs == [10] })
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
        let firstHost = mach_absolute_time()
        lab.engines[0].emit(try pcm(0.2), when: AVAudioTime(hostTime: firstHost)); await first.drain()
        // Force a genuinely failed installed capture, then traverse the real default-input event.
        first.stop(); id.set(20); available[0] = device(20)
        manager.handleDefaultMicChange(currentID: 20)
        let rebound = try #require(shared.getCapture(for: "u"))
        #expect(rebound !== first && rebound.currentDeviceID == 20 && rebound.isCapturing)
        #expect(shared.getCapture(for: "healthy") === healthy && !shared.hasCapture(for: "excluded"))
        #expect(audio._sourceWriterForTesting("u") === original)
        lab.engines.last!.emit(try pcm(0.4), when: AVAudioTime(hostTime: firstHost + AVAudioTime.hostTime(forSeconds: 0.25))); await rebound.drain()
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
        let firstOffset = Int((CMClockMakeHostTimeFromSystemUnits(firstHost).seconds - original._segmentStartTimeForTesting.seconds) * 48_000)
        #expect(reader.status == .completed && abs(samples.count - (firstOffset + 16_800)) <= 2)
        #expect(original.statisticsSnapshot.acceptedFrames == 9600 && original.statisticsSnapshot.droppedFrames == 0)
        if firstOffset >= 0, firstOffset + 4000 <= samples.count {
            #expect(samples[firstOffset..<(firstOffset + 4000)].reduce(0, +) / 4000 > 0.15)
        }
        #expect(samples.suffix(4000).reduce(0, +) / 4000 > 0.3)
        let meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("120000_meta.json"))) as? [String: Any])
        let rows = try #require((meta["audio_capture"] as? [String: Any])?["sources"] as? [[String: Any]])
        let failures = try #require(rows.first { $0["source_id"] as? String == "u" }?["failures"] as? [[String: Any]])
        #expect(failures.filter { $0["stage"] as? String == "disconnect" }.count == 1)
        shared.stopAll()
    }

    @MainActor private func livenessLab(_ root: URL, clock: LockedValue<TimeInterval>) async throws
        -> (MicEngineLab, MicrophoneCaptureManager, CaptureManager, SegmentWriter) {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, recoveryDelay: { _ in }, monotonicNow: { clock.current! })
        }, retryDelay: { _ in }, allowanceClock: { clock.current! })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [self.device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000")
        _ = try await writer.start(sources: .microphone, mics: [device()], micCaptureManager: shared)
        manager.seedRecordingForTesting(currentSegment: writer, sources: .microphone)
        return (lab, shared, manager, writer)
    }

    @Test @MainActor func parkedMicrophoneReturnsOnLivenessAfterCooldownWithoutOwnerAction() async throws {
        let root = try makeTempDirectory("mic-liveness-cooldown"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedValue<TimeInterval>(); clock.set(1000)
        let (lab, shared, manager, _) = try await livenessLab(root, clock: clock)
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await capture.drain() }
        #expect(lab.engines.count == 7 && !capture.isCapturing)
        manager.handleLivenessTick()
        #expect(lab.engines.count == 7)
        clock.set(1014); manager.handleLivenessTick()
        #expect(lab.engines.count == 7)
        clock.set(1016); manager.handleLivenessTick()
        #expect(lab.engines.count == 8 && shared.getCapture(for: "u")?.isCapturing == true)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func stalledMicrophoneIsRecordedAndRebuiltIntoItsSegment() async throws {
        let root = try makeTempDirectory("mic-liveness-stall"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedValue<TimeInterval>(); clock.set(1000)
        let (lab, shared, manager, writer) = try await livenessLab(root, clock: clock)
        let first = try #require(shared.getCapture(for: "u"))
        lab.engines[0].emit(try pcm()); await first.drain()
        clock.set(1004); manager.handleLivenessTick()
        #expect(lab.engines.count == 1 && first.isCapturing)
        clock.set(1006); manager.handleLivenessTick()
        #expect(lab.engines.count == 2 && shared.getCapture(for: "u")?.isCapturing == true && writer.hasMicrophone(deviceUID: "u"))
        let rebuilt = try #require(shared.getCapture(for: "u"))
        lab.engines[1].emit(try pcm()); await rebuilt.drain()
        clock.set(1009); manager.handleLivenessTick()
        #expect(lab.engines.count == 2)
        _ = await writer.finishCapture()
        let meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("120000_meta.json"))) as? [String: Any])
        let rows = try #require((meta["audio_capture"] as? [String: Any])?["sources"] as? [[String: Any]])
        let failures = try #require(rows.first { $0["source_id"] as? String == "u" }?["failures"] as? [[String: Any]])
        #expect(failures.contains { $0["stage"] as? String == "stall" })
        #expect(!failures.contains { $0["stage"] as? String == "disconnect" })
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test func allowanceCoolsDownWithBackoffAndStablePCMResetsIt() {
        let clock = LockedValue<TimeInterval>(); clock.set(0)
        let allowance = MicrophoneRecoveryAllowance(now: { clock.current! })
        for _ in 0...MicrophoneRecoveryAllowance.replacementLimit { #expect(allowance.admitAttempt()) }
        #expect(!allowance.admitAttempt() && allowance.isCoolingDown)
        allowance.park(); clock.set(14.9)
        #expect(!allowance.canAttempt)
        clock.set(15)
        #expect(allowance.admitAttempt() && !allowance.admitAttempt())
        clock.set(15 + 29.9); #expect(!allowance.canAttempt)
        clock.set(15 + 30); #expect(allowance.admitAttempt() && !allowance.admitAttempt())
        clock.set(45 + 60); #expect(allowance.admitAttempt() && !allowance.admitAttempt())
        clock.set(105 + 60); #expect(allowance.admitAttempt())
        // Ten stable seconds restore the replacement burst but not the backoff level.
        for second in stride(from: 166.0, through: 177.0, by: 1.0) { allowance.acceptPCM(arrival: second, continuous: true) }
        for _ in 0..<MicrophoneRecoveryAllowance.replacementLimit { #expect(allowance.admitAttempt()) }
        #expect(!allowance.admitAttempt())
        clock.set(165 + 15); allowance.park(); #expect(!allowance.canAttempt)
        clock.set(165 + 60); #expect(allowance.admitAttempt())
        // A long stable run forgives the backoff level too.
        for second in stride(from: 226.0, through: 350.0, by: 1.0) { allowance.acceptPCM(arrival: second, continuous: true) }
        clock.set(350)
        for _ in 0..<MicrophoneRecoveryAllowance.replacementLimit { #expect(allowance.admitAttempt()) }
        #expect(!allowance.admitAttempt())
        clock.set(350 + 15); #expect(allowance.canAttempt)
    }

    @Test @MainActor func failedAttemptAfterCooldownIsRetriedAtTheNextCooldown() async throws {
        let root = try makeTempDirectory("mic-liveness-failed-retry"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedValue<TimeInterval>(); clock.set(1000)
        let (lab, shared, manager, writer) = try await livenessLab(root, clock: clock)
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<7 { lab.engines.last!.notify(); await capture.drain() }
        #expect(lab.engines.count == 7 && !capture.isCapturing)
        let unavailable = LockedValue<Bool>(); unavailable.set(true)
        lab.startGate = { if unavailable.current == true { throw FakeCaptureError.startFailed } }
        clock.set(1016); manager.handleLivenessTick()
        #expect(lab.engines.count == 8 && shared.getCapture(for: "u")?.isCapturing != true)
        #expect(writer.hasMicrophone(deviceUID: "u") || shared.getCapture(for: "u") == nil)
        unavailable.set(false)
        clock.set(1016 + 29); manager.handleLivenessTick()
        #expect(lab.engines.count == 8)
        clock.set(1016 + 31); manager.handleLivenessTick()
        #expect(lab.engines.count == 9 && shared.getCapture(for: "u")?.isCapturing == true)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func everySelectedMicrophoneIsTakenInWithNoCap() async throws {
        let root = try makeTempDirectory("mic-no-cap"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), devices = (0..<6).map { device(AudioDeviceID(10 + $0), uid: "m\($0)", name: "mic \($0)") }
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { uid in devices.first { $0.uid == uid }?.id }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { devices }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(Set(devices.map(\.uid)).allSatisfy { shared.getCapture(for: $0)?.isCapturing == true })
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func bluetoothMicrophoneFollowsAnotherAppsUse() async throws {
        let root = try makeTempDirectory("mic-bluetooth-follow"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab()
        let headset = AudioInputDevice(id: 30, name: "headset", uid: "bt", manufacturer: nil, sampleRate: 24_000, transportType: .bluetooth)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in 30 }, recoveryDelay: { _ in })
        }, retryDelay: { _ in })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [self.device(), headset] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        let inUse = LockedValue<Set<String>>(); inUse.set([])
        manager.inputInUseElsewhere = { inUse.current! }
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(shared.getCapture(for: "bt") == nil && shared.getCapture(for: "u")?.isCapturing == true)
        inUse.set(["bt"]); manager.handleLivenessTick()
        #expect(shared.getCapture(for: "bt")?.isCapturing == true)
        inUse.set([]); manager.handleLivenessTick()
        #expect(shared.getCapture(for: "bt") == nil && shared.getCapture(for: "u")?.isCapturing == true)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }
}

@MainActor
private final class MicResumePreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var returned = false
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        returned = true
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class MicEngineLab: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MicEngineDouble] = []
    let failingIndices: Set<Int>, selfNotify: Bool
    var startGate: (@Sendable () throws -> Void)? {
        get { lock.withLock { gate } }
        set { lock.withLock { gate = newValue } }
    }
    private var gate: (@Sendable () throws -> Void)?
    var engines: [MicEngineDouble] { lock.withLock { stored } }
    init(failingIndices: Set<Int> = [], selfNotify: Bool = false) { self.failingIndices = failingIndices; self.selfNotify = selfNotify }
    func make() -> MicEngineDouble {
        lock.withLock {
            let index = stored.count
            let engine = MicEngineDouble(fails: failingIndices.contains(index), notifyDuringStart: selfNotify && (index == 0 || failingIndices.contains(index)))
            engine.startHook = gate
            stored.append(engine); return engine
        }
    }
}

private final class MicEngineDouble: MicrophoneCaptureEngine, @unchecked Sendable {
    let configurationObject: AnyObject = NSObject()
    private let lock = NSLock()
    private var pcm: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var ids: [AudioDeviceID] = [], trace: [String] = []
    private var configuration: (running: Bool, readback: AudioDeviceID?, unchanged: Bool)?
    let fails: Bool
    var notifyDuringStart: Bool
    var startHook: (@Sendable () throws -> Void)?
    var boundIDs: [AudioDeviceID] { lock.withLock { ids } }
    var teardown: [String] { lock.withLock { trace } }
    init(fails: Bool, notifyDuringStart: Bool) { self.fails = fails; self.notifyDuringStart = notifyDuringStart }
    func configure(isRunning: Bool, readback: AudioDeviceID?, formatUnchanged: Bool) {
        lock.withLock { configuration = (isRunning, readback, formatUnchanged) }
    }
    func requiresRecovery(resolvedDeviceID: AudioDeviceID?) -> Bool {
        lock.withLock {
            guard let configuration else { return true }
            return microphoneConfigurationRequiresRecovery(isRunning: configuration.running,
                admitted: ids.last, readback: configuration.readback, resolved: resolvedDeviceID,
                formatUnchanged: configuration.unchanged)
        }
    }
    func start(deviceID: AudioDeviceID, deviceName: String, onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        lock.withLock { ids.append(deviceID); pcm = onPCM }
        if notifyDuringStart { for _ in 0..<10 { notify() } }
        try startHook?()
        if fails { throw FakeCaptureError.startFailed }
    }
    func stop() { lock.withLock { trace.append("stop") }; if notifyDuringStart { notify() } }
    func removeTap() throws { lock.withLock { trace.append("remove") } }
    func notify() { NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: configurationObject) }
    func emit(_ buffer: AVAudioPCMBuffer, when: AVAudioTime? = nil) { lock.withLock { pcm }?(buffer, when ?? AVAudioTime(hostTime: mach_absolute_time())) }
}
