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
                resolveDeviceID: { _ in id.current })
        })
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
    func timedOutNativePrepareCannotAdmitAfterNewOwnerRequestOrHold(held: Bool) async throws {
        let root = try makeTempDirectory("mic-escaped-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab()
        let (shared, manager) = managerLab(root, lab)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        let paused = lab.engines.count
        let gate = MicResumePreparationGate()
        manager.beforeResumeNativeStartForTesting = { await gate.wait() }
        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {}, transitionTimeoutSeconds: 0.05)
        let result = await executor.enqueue(.resume(reason: .user))
        guard case .vetoed = result else { Issue.record("Held prepare must time out"); gate.release(); return }
        #expect(lab.engines.count == paused)
        if held {
            manager.lifecycleManager.ownerPauseIsHeld = { true }
        } else {
            _ = await executor.enqueue(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
            #expect(manager.state.isRecording && lab.engines.count == paused + 1)
        }
        let newer = manager.currentSegmentForTesting?.outputDirectory
        let before = lab.engines.count
        gate.release()
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { gate.returned } }
        await Task.yield()
        #expect(lab.engines.count == before && manager.currentSegmentForTesting?.outputDirectory == newer)
        #expect((shared.getCapture(for: "u")?.isCapturing == true) == !held)
        manager.lifecycleManager.ownerPauseIsHeld = { false }
        _ = await executor.enqueue(.stop(reason: .user)); shared.stopAll()
    }

    @Test(arguments: [false, true]) @MainActor
    func coordinatorResumeRestartsAMicrophoneWaitingOnBackoff(heldIdle: Bool) async throws {
        let root = try makeTempDirectory("mic-coordinator-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), clock = LockedValue<TimeInterval>(); clock.set(1000)
        let (shared, manager) = managerLab(root, lab, clock: clock)
        let pause = PauseManager()
        let coordinator = CaptureCoordinator(captureManager: manager, pauseManager: pause,
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false), isTerminating: { false },
            configProvider: { (sources: .microphone, disabled: [], enabled: []) }, bannerSink: { _ in },
            permissionPollScheduler: PermissionPollTestScheduler().scheduler)
        coordinator.microphoneAuthorizationCause = .authorized
        coordinator.microphoneAuthorizationReader = { .authorized }
        coordinator.activate()
        await coordinator.startRecording(reason: .user)
        try await knockDown(lab, shared, manager)
        pause.pause(for: .indefinite)
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { manager.state.isPaused } }
        if heldIdle { _ = await manager.enqueueTransition(.stop(reason: .quit)) }
        let before = lab.engines.count
        await coordinator.toggleRecording()
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { manager.state.isRecording } }
        #expect(lab.engines.count == before + 1 && shared.getCapture(for: "u")?.isCapturing == true)
        #expect(!pause.isPaused)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    /// Stops the mic through a configuration change and fails its first restart,
    /// so it waits on the recovery backoff with the clock held still.
    @MainActor private func knockDown(_ lab: MicEngineLab, _ shared: MicrophoneCaptureManager, _ manager: CaptureManager) async throws {
        let capture = try #require(shared.getCapture(for: "u"))
        manager.audioRecovery.reset(["u"]) // start from a first failure
        let failing = LockedValue<Bool>(); failing.set(true)
        lab.startGate = { if failing.current == true { throw FakeCaptureError.startFailed } }
        let before = lab.engines.count
        lab.engines.last!.notify(); await capture.drain()
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { lab.engines.count == before + 1 } }
        failing.set(false)
        manager.handleLivenessTick()
        #expect(lab.engines.count == before + 1 && shared.getCapture(for: "u")?.isCapturing != true)
        #expect(manager.audioRecovery.secondsUntilAttempt("u") > 0)
    }

    @Test(arguments: [ResumeReason.user, ResumeReason.pauseDeadline]) @MainActor
    func everyResumeRetriesAMicrophoneImmediately(reason: ResumeReason) async throws {
        let root = try makeTempDirectory("mic-resume-rearm")
        defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), clock = LockedValue<TimeInterval>(); clock.set(1000)
        let (shared, manager) = managerLab(root, lab, clock: clock)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        try await knockDown(lab, shared, manager)
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        let result = await manager.enqueueTransition(.resume(reason: reason))
        guard case .committed = result else { Issue.record("Resume must commit"); return }
        #expect(shared.getCapture(for: "u")?.isCapturing == true && manager.audioRecovery.secondsUntilAttempt("u") == 0)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func ownerSelectionAndArrivingDevicesSkipTheBackoff() async throws {
        let root = try makeTempDirectory("mic-owner-rearm"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), clock = LockedValue<TimeInterval>(); clock.set(1000)
        let (shared, manager) = managerLab(root, lab, clock: clock)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        try await knockDown(lab, shared, manager)
        // The device reappearing is an immediate try.
        await manager.handleDeviceChange(added: [device()], removed: [])
        #expect(shared.getCapture(for: "u")?.isCapturing == true)
        try await knockDown(lab, shared, manager)
        // So is the owner turning it off and on again.
        manager.updateMicrophoneSelection(disabled: ["u"], enabled: [])
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        #expect(shared.getCapture(for: "u")?.isCapturing == true)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func ownerStartFromPauseKeepsAnEngineThatStayedRunning() async throws {
        let root = try makeTempDirectory("mic-paused-reuse"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab()
        let (shared, manager) = managerLab(root, lab)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        let capture = try #require(shared.getCapture(for: "u"))
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: false))
        #expect(capture.isCapturing && lab.engines.count == 1)
        let outcome = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = outcome else { Issue.record("Owner start from pause must commit"); return }
        #expect(shared.getCapture(for: "u") === capture && lab.engines.count == 1 && capture.isCapturing)
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
            resolveDeviceID: { _ in resolved.current })
    }

    /// Counts how often a capture asked to be started again.
    private func recoveryRequests(_ capture: ExternalMicCapture) -> LockedCounter {
        let counter = LockedCounter(); capture.onRecoveryNeeded = { counter.increment() }; return counter
    }
    @MainActor private func recovery(_ clock: LockedValue<TimeInterval>, wakes: WakeLog? = nil) -> AudioRecoveryManager {
        AudioRecoveryManager(now: { clock.current! }, scheduleWake: { delay, fire in
            wakes?.record(delay, fire); return FakePauseExpiryTimer {}
        })
    }
    @MainActor private func managerLab(_ root: URL, _ lab: MicEngineLab, clock: LockedValue<TimeInterval>? = nil,
                                       devices: [AudioInputDevice]? = nil) -> (MicrophoneCaptureManager, CaptureManager) {
        let id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { uid in devices?.first { $0.uid == uid }?.id ?? id.current },
                monotonicNow: { clock?.current ?? ProcessInfo.processInfo.systemUptime })
        })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { devices ?? [self.device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        if let clock { manager.useAudioRecoveryForTesting(recovery(clock)) }
        return (shared, manager)
    }

    @Test(arguments: ["healthy", "stopped", "readback", "unreadable", "format", "resolved", "missing"])
    func configurationChangeStopsAndReportsButNeverRestartsItself(change: String) async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = ExternalMicCapture(device: device(), engineFactory: { lab.make() },
            resolveDeviceID: { _ in change == "missing" && lab.engines.count > 0 && !lab.engines[0].boundIDs.isEmpty ? nil : id.current })
        let requests = recoveryRequests(capture)
        try capture.start()
        let first = lab.engines[0]
        first.configure(isRunning: change != "stopped", readback: change == "unreadable" ? nil : (change == "readback" ? 20 : 10),
            formatUnchanged: change != "format")
        if change == "resolved" { id.set(20) }
        first.notify(); await capture.drain()
        if change == "healthy" {
            #expect(lab.engines.count == 1 && capture.isCapturing && first.teardown.isEmpty && requests.count == 0)
            capture.stop(); return
        }
        #expect(lab.engines.count == 1 && !capture.isCapturing && requests.count == 1)
        #expect(first.teardown == ["stop", "remove"])
        // The owner of the capture starts it again, on the current binding.
        if change == "missing" {
            #expect(throws: ExternalMicCapture.ExternalMicCaptureError.self) { try capture.start() }
        } else {
            try capture.start()
            #expect(lab.engines.count == 2 && capture.isCapturing)
            #expect(lab.engines.last?.boundIDs == [change == "resolved" ? 20 : 10])
        }
        capture.stop()
    }

    @Test func configurationChangesNeverExhaustACapture() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), errors = LockedArray<String>([]), requests = recoveryRequests(capture)
        capture.setCallbacks(audio: { _, _ in }, error: { errors.append(($0 as NSError).domain) })
        try capture.start()
        for round in 1...12 {
            lab.engines.last!.notify(); await capture.drain()
            #expect(!capture.isCapturing && requests.count == round)
            try capture.start()
            #expect(capture.isCapturing && lab.engines.count == round + 1)
        }
        #expect(errors.all.isEmpty)
        capture.stop()
    }

    @Test func admittedPCMFromARetiredEngineStillDrains() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let clock = LockedValue<Double>(); clock.set(0)
        let capture = ExternalMicCapture(device: device(), gain: 1, engineFactory: { lab.make() },
            resolveDeviceID: { _ in id.current }, monotonicNow: { clock.current! })
        let received = LockedCounter(), errors = LockedCounter(), requests = recoveryRequests(capture)
        capture.setCallbacks(audio: { _, _ in received.increment() }, error: { _ in errors.increment() })
        try capture.start()
        let retired = lab.engines[0], quiet = try pcm(0), base = mach_absolute_time()
        capture._suspendProcessingForTesting(); retired.notify()
        for index in 0...30 {
            clock.set(Double(index) * 0.4)
            retired.emit(quiet, when: AVAudioTime(hostTime: base + AVAudioTime.hostTime(forSeconds: Double(index) * 0.4),
                sampleTime: Int64(index * 4800), atRate: 48_000))
        }
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(received.count == 31 && requests.count == 1 && !capture.isCapturing && lab.engines.count == 1)
        retired.emit(quiet); retired.notify(); await capture.drain()
        #expect(received.count == 31 && requests.count == 1 && errors.count == 0)
        capture.stop()
    }

    @Test func detachedDestinationDrainsToItsOwnWriter() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let clock = LockedValue<Double>(); clock.set(0)
        let capture = ExternalMicCapture(device: device(), gain: 1, engineFactory: { lab.make() },
            resolveDeviceID: { _ in id.current }, monotonicNow: { clock.current! })
        let old = LockedCounter(), current = LockedCounter(), requests = recoveryRequests(capture)
        capture.setCallbacks(audio: { _, _ in old.increment() }, error: { _ in })
        try capture.start()
        let quiet = try pcm(0), base = mach_absolute_time()
        capture._suspendProcessingForTesting()
        for index in 0...30 {
            clock.set(Double(index) * 0.4)
            lab.engines.last!.emit(quiet, when: AVAudioTime(hostTime: base + AVAudioTime.hostTime(forSeconds: Double(index) * 0.4),
                sampleTime: Int64(index * 4800), atRate: 48_000))
        }
        capture.setCallbacks(audio: nil, error: nil)
        capture.setCallbacks(audio: { _, _ in current.increment() }, error: { _ in })
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(old.count == 31 && current.count == 0)
        lab.engines.last!.notify(); await capture.drain()
        #expect(!capture.isCapturing && requests.count == 1)
        capture.stop()
    }

    @Test func burstOfChangesAsksForOneRestartAndRetiredPCMIsRejected() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), old = LockedCounter(), current = LockedCounter(), errors = LockedCounter()
        let requests = recoveryRequests(capture)
        capture.setCallbacks(audio: { _, _ in old.increment() }, error: { _ in errors.increment() })
        try capture.start()
        let first = lab.engines[0]
        capture._suspendProcessingForTesting()
        first.emit(try pcm()) // admitted before retirement, must reach old writer
        id.set(20)
        for _ in 0..<20 { first.notify() }
        capture.setCallbacks(audio: { _, _ in current.increment() }, error: { _ in errors.increment() })
        capture._resumeProcessingForTesting(); await capture.drain()
        #expect(requests.count == 1 && lab.engines.count == 1 && !capture.isCapturing)
        try capture.start()
        #expect(lab.engines.count == 2 && lab.engines[0].boundIDs == [10] && lab.engines[1].boundIDs == [20])
        #expect(capture.currentDeviceID == 20 && capture.isCapturing)
        first.notify(); first.emit(try pcm())
        lab.engines[1].emit(try pcm()); await capture.drain()
        #expect(lab.engines.count == 2 && old.count == 1 && current.count == 1 && errors.count == 0 && requests.count == 1)
        #expect(first.teardown.prefix(2) == ["stop", "remove"])
        capture.stop()
    }

    @Test(arguments: [false, true])
    func startupFailureOrChangeLeavesTheRestartToItsOwner(fails: Bool) async throws {
        let lab = MicEngineLab(failingIndices: fails ? [0] : [], selfNotify: true), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), errors = LockedCounter(), received = LockedCounter(), requests = recoveryRequests(capture)
        capture.setCallbacks(audio: { _, _ in received.increment() }, error: { _ in errors.increment() })
        if fails { #expect(throws: FakeCaptureError.self) { try capture.start() } }
        else { try capture.start() }
        await capture.drain()
        // One engine either way: a capture never multiplies its own attempts.
        #expect(lab.engines.count == 1 && !capture.isCapturing)
        #expect(errors.count == (fails ? 1 : 0) && requests.count == (fails ? 0 : 1))
        lab.engines[0].emit(try pcm()); await capture.drain()
        #expect(received.count == 0)
        capture.stop()
    }

    @Test func redundantStartDoesNotCancelAdmittedConfigurationRecovery() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), admitted = LockedCounter(), requests = recoveryRequests(capture)
        try capture.start()
        let request = capture._requestedEpochForTesting
        capture._suspendProcessingForTesting()
        id.set(20); lab.engines[0].notify()
        capture._startAdmissionHookForTesting = { admitted.increment() }
        let start = Task.detached { try capture.start() }
        try await withTimeout(seconds: 1) { await admitted.waitUntilCount(1) }
        #expect(capture._requestedEpochForTesting == request)
        capture._resumeProcessingForTesting()
        do { try await start.value } catch is CancellationError {}
        await capture.drain()
        // The admitted recovery still retires the old binding and asks once.
        #expect(requests.count == 1 && !capture.isCapturing && lab.engines[0].teardown.prefix(2) == ["stop", "remove"])
        capture._startAdmissionHookForTesting = nil
        try capture.start()
        #expect(capture.isCapturing && capture.currentDeviceID == 20)
        capture.stop()
    }

    @Test func staleRecoveryCannotTearDownANewerStart() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let capture = capture(lab, id), requests = recoveryRequests(capture)
        try capture.start()
        capture._suspendProcessingForTesting()
        lab.engines[0].notify()
        let request = capture._requestedEpochForTesting
        // The explicit stop is requested while the change is still queued behind it.
        let restart = Task.detached { capture.stop(); try capture.start() }
        try await withTimeout(seconds: 1) {
            while capture._requestedEpochForTesting == request { try await Task.sleep(for: .milliseconds(1)) }
        }
        capture._resumeProcessingForTesting(); try await restart.value; await capture.drain()
        #expect(capture.isCapturing && requests.count == 0 && lab.engines.count == 2)
        capture.stop()
    }

    @Test func managerStartIsOneAttemptOnAFreshEngine() throws {
        let lab = MicEngineLab(failingIndices: [0]), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose,
                engineFactory: { lab.make() }, resolveDeviceID: { _ in id.current })
        })
        #expect(throws: FakeCaptureError.self) { try shared.startCapture(for: device()) }
        #expect(lab.engines.count == 1 && !shared.hasCapture(for: "u"))
        try shared.startCapture(for: device())
        #expect(lab.engines.count == 2 && shared.getCapture(for: "u")?.isCapturing == true)
        shared.stopAll()
    }

    @Test func queuedRecoveryOnARunningCaptureEndsInOneFreshStart() async throws {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose,
                engineFactory: { lab.make() }, resolveDeviceID: { _ in id.current })
        })
        let asked = LockedArray<String>([])
        shared.onRecoveryNeeded = { asked.append($0) }
        try shared.startCapture(for: device()); let old = try #require(shared.getCapture(for: "u"))
        old._suspendProcessingForTesting(); lab.engines[0].notify()
        old._resumeProcessingForTesting(); await old.drain()
        #expect(asked.all == ["u"] && !old.isCapturing)
        try shared.startCapture(for: device())
        #expect(lab.engines.count == 2 && shared.getCapture(for: "u") !== old)
        #expect(shared.getCapture(for: "u")?.isCapturing == true)
        shared.stopAll()
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
                engineFactory: { lab.make() }, resolveDeviceID: { _ in id.current })
        })
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

    @MainActor private func livenessLab(_ root: URL, clock: LockedValue<TimeInterval>, wakes: WakeLog? = nil) async throws
        -> (MicEngineLab, MicrophoneCaptureManager, CaptureManager, SegmentWriter) {
        let lab = MicEngineLab(), id = LockedValue<AudioDeviceID>(); id.set(10)
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in id.current }, monotonicNow: { clock.current! })
        })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { [self.device()] }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        manager.useAudioRecoveryForTesting(recovery(clock, wakes: wakes))
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000")
        _ = try await writer.start(sources: .microphone, mics: [device()], micCaptureManager: shared)
        manager.seedRecordingForTesting(currentSegment: writer, sources: .microphone)
        return (lab, shared, manager, writer)
    }

    @Test @MainActor func stoppedMicrophoneComesBackOnBackoffWithoutOwnerAction() async throws {
        let root = try makeTempDirectory("mic-recovery-backoff"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedValue<TimeInterval>(); clock.set(1000)
        let wakes = WakeLog()
        let (lab, shared, manager, writer) = try await livenessLab(root, clock: clock, wakes: wakes)
        // A configuration change is restarted at once, on a fresh engine, into the same segment.
        lab.engines[0].notify(); await shared.getCapture(for: "u")!.drain()
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { shared.getCapture(for: "u")?.isCapturing == true } }
        #expect(lab.engines.count == 2 && writer.hasMicrophone(deviceUID: "u"))
        // A device that keeps failing is retried on a growing backoff, driven by wake-ups alone.
        clock.set(clock.current! + 1)
        let failing = LockedValue<Bool>(); failing.set(true)
        lab.startGate = { if failing.current == true { throw FakeCaptureError.startFailed } }
        lab.engines[1].notify(); await shared.getCapture(for: "u")!.drain()
        try await waitUntil(timeout: .seconds(3)) { await MainActor.run { lab.engines.count == 3 } }
        var expected = 3
        for delay in AudioRecoveryManager.microphoneDelays.dropFirst().prefix(4) {
            let wait = manager.audioRecovery.secondsUntilAttempt("u")
            #expect(wait > 0)
            clock.set(clock.current! + wait - 0.01); manager.handleLivenessTick()
            #expect(lab.engines.count == expected)
            clock.set(clock.current! + 0.01); wakes.fireLatest()
            expected += 1
            #expect(lab.engines.count == expected)
            _ = delay
        }
        failing.set(false)
        clock.set(clock.current! + manager.audioRecovery.secondsUntilAttempt("u")); wakes.fireLatest()
        #expect(shared.getCapture(for: "u")?.isCapturing == true && writer.hasMicrophone(deviceUID: "u"))
        // A long healthy run forgives the backoff.
        let capture = try #require(shared.getCapture(for: "u"))
        for _ in 0..<8 {
            clock.set(clock.current! + 5); lab.engines.last!.emit(try pcm()); await capture.drain()
            manager.handleLivenessTick()
        }
        // The next failure starts the backoff over from its shortest wait.
        manager.audioRecovery.noteAttempt("u", kind: .microphone)
        #expect(abs(manager.audioRecovery.secondsUntilAttempt("u") - AudioRecoveryManager.microphoneDelays[0]) < 0.001)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func aLaterAttemptStillWakesAfterAnEarlierOneAndStaleWakesDoNothing() {
        let clock = LockedValue<TimeInterval>(); clock.set(0)
        let wakes = WakeLog(), recovery = recovery(clock, wakes: wakes)
        var woke = 0; recovery.onWake = { woke += 1 }
        recovery.noteAttempt("system", kind: .system)
        recovery.noteAttempt("m", kind: .microphone)
        #expect(wakes.delays.map { ($0 * 1000).rounded() / 1000 } == [60, 0.2])
        clock.set(0.2); wakes.fireLatest()
        // The system attempt due later is re-armed, not dropped.
        #expect(woke == 1 && wakes.delays.count == 3 && abs(wakes.delays[2] - 59.8) < 0.001)
        // The replaced 60 s timer firing late must not wake or clear the live one.
        wakes.fireOldest()
        #expect(woke == 1)
        recovery.cancelWake(); clock.set(60); wakes.fireLatest()
        #expect(woke == 1)
    }

    @Test @MainActor func aRecoveryReportWhilePausedRestartsNothingUntilResume() async throws {
        let root = try makeTempDirectory("mic-recovery-paused"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), clock = LockedValue<TimeInterval>(); clock.set(1000)
        let (shared, manager) = managerLab(root, lab, clock: clock)
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: false))
        let capture = try #require(shared.getCapture(for: "u"))
        lab.engines[0].notify(); await capture.drain()
        try await Task.sleep(for: .milliseconds(50)); manager.handleLivenessTick()
        #expect(lab.engines.count == 1 && !capture.isCapturing)
        _ = await manager.enqueueTransition(.resume(reason: .user))
        #expect(shared.getCapture(for: "u")?.isCapturing == true)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func aMicrophoneOnlySessionBeginsWhenItsMicFailsAndRecoveryBringsItIn() async throws {
        let root = try makeTempDirectory("mic-only-start-failure"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), clock = LockedValue<TimeInterval>(); clock.set(1000)
        let failing = LockedValue<Bool>(); failing.set(true)
        lab.startGate = { if failing.current == true { throw FakeCaptureError.startFailed } }
        let (shared, manager) = managerLab(root, lab, clock: clock)
        let result = await manager.enqueueTransition(.start(reason: .user, sources: .microphone, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = result else { Issue.record("A failing selected mic must not fail the session"); return }
        manager.handleLivenessTick()
        #expect(manager.state.isRecording && shared.getCapture(for: "u")?.isCapturing != true)
        #expect(manager.currentAudioHealthNote == "mic isn't coming through right now. the solstone app is trying again on its own.")
        failing.set(false)
        clock.set(clock.current! + manager.audioRecovery.secondsUntilAttempt("u") + 0.01); manager.handleLivenessTick()
        #expect(shared.getCapture(for: "u")?.isCapturing == true)
        #expect(manager.currentSegmentForTesting?.hasMicrophone(deviceUID: "u") == true)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func recoveryBackoffGrowsCapsAndIsForgivenByHealth() {
        let clock = LockedValue<TimeInterval>(); clock.set(0)
        let wakes = WakeLog(), recovery = recovery(clock, wakes: wakes)
        #expect(recovery.canAttempt("m"))
        var waits: [TimeInterval] = []
        for _ in 0..<10 {
            #expect(recovery.canAttempt("m"))
            recovery.noteAttempt("m", kind: .microphone)
            let wait = recovery.secondsUntilAttempt("m"); waits.append(wait)
            #expect(!recovery.canAttempt("m"))
            clock.set(clock.current! + wait)
        }
        let rounded = { (values: [TimeInterval]) in values.map { ($0 * 1000).rounded() / 1000 } }
        #expect(rounded(waits) == [0.2, 0.5, 1, 2, 5, 15, 30, 60, 60, 60])
        #expect(rounded(wakes.delays) == rounded(waits))
        // Health must be continuous for the full window; an unhealthy moment restarts it.
        recovery.noteHealthy("m"); clock.set(clock.current! + 29); recovery.noteUnhealthy("m")
        recovery.noteHealthy("m"); clock.set(clock.current! + 29); recovery.noteHealthy("m")
        recovery.noteAttempt("m", kind: .microphone)
        #expect(recovery.secondsUntilAttempt("m") == 60)
        recovery.noteHealthy("m"); clock.set(clock.current! + 30); recovery.noteHealthy("m")
        recovery.noteAttempt("m", kind: .microphone)
        #expect(abs(recovery.secondsUntilAttempt("m") - 0.2) < 0.001)
        // System rebuilds wait longer; an owner action clears only what it names.
        recovery.noteAttempt("system", kind: .system)
        #expect(recovery.secondsUntilAttempt("system") == 60)
        recovery.reset(["m"])
        #expect(recovery.canAttempt("m") && !recovery.canAttempt("system"))
        recovery.reset()
        #expect(recovery.canAttempt("system"))
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

    @Test @MainActor func everySelectedMicrophoneIsTakenInWithNoCap() async throws {
        let root = try makeTempDirectory("mic-no-cap"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), devices = (0..<6).map { device(AudioDeviceID(10 + $0), uid: "m\($0)", name: "mic \($0)") }
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { uid in devices.first { $0.uid == uid }?.id })
        })
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
                resolveDeviceID: { _ in 30 })
        })
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

    @Test func audioIssueNamesSourcesAndSaysWhetherTheyAreBack() {
        #expect(UICopy.audioIssue(recovering: [], recovered: []) == nil)
        #expect(UICopy.audioIssue(recovering: ["system audio"], recovered: ["mic"])
            == "system audio isn't coming through right now. the solstone app is trying again on its own.")
        #expect(UICopy.audioIssue(recovering: ["a", "b", "c"], recovered: [])
            == "a, b and c aren't coming through right now. the solstone app is trying again on its own.")
        #expect(UICopy.audioIssue(recovering: [], recovered: ["mic", "mic"])
            == "mic dropped out earlier and is back. part of this segment may be missing.")
    }

    @Test @MainActor func warningNamesARecoveringMicrophoneThenSaysItIsBack() async throws {
        let root = try makeTempDirectory("mic-health-warning"); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedValue<TimeInterval>(); clock.set(1000)
        let (lab, shared, manager, _) = try await livenessLab(root, clock: clock)
        manager.refreshAudioHealth()
        #expect(manager.currentAudioHealthNote == nil)
        try await knockDown(lab, shared, manager)
        #expect(manager.currentAudioHealthNote == "mic isn't coming through right now. the solstone app is trying again on its own.")
        clock.set(clock.current! + manager.audioRecovery.secondsUntilAttempt("u")); manager.handleLivenessTick()
        #expect(shared.getCapture(for: "u")?.isCapturing == true)
        // Writer evidence reaches the segment record asynchronously; a later check sees it.
        let back = "mic dropped out earlier and is back. part of this segment may be missing."
        try await withTimeout(seconds: 5) { @MainActor in
            while manager.currentAudioHealthNote != back { manager.refreshAudioHealth(); try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(manager.currentAudioHealthNote == back)
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        #expect(manager.currentAudioHealthNote == nil)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }

    @Test @MainActor func unpluggingAMicrophoneRaisesNoWarning() async throws {
        let root = try makeTempDirectory("mic-health-unplug"); defer { try? FileManager.default.removeItem(at: root) }
        let lab = MicEngineLab(), available = LockedValue<[AudioInputDevice]>(); available.set([device()])
        let shared = MicrophoneCaptureManager(captureFactory: { device, gain, verbose in
            ExternalMicCapture(device: device, gain: gain, verbose: verbose, engineFactory: { lab.make() },
                resolveDeviceID: { _ in 10 })
        })
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer(),
            microphoneDevices: { available.current! }, streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler, microphoneCaptureManager: shared)
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000")
        manager.updateMicrophoneSelection(disabled: [], enabled: [])
        _ = try await writer.start(sources: .microphone, mics: [device()], micCaptureManager: shared)
        manager.seedRecordingForTesting(currentSegment: writer, sources: .microphone)
        available.set([])
        await manager.handleDeviceChange(added: [], removed: [device()])
        manager.handleLivenessTick()
        #expect(manager.currentAudioHealthNote == nil)
        _ = await manager.enqueueTransition(.stop(reason: .user)); shared.stopAll()
    }
}

@MainActor
private final class WakeLog {
    private(set) var delays: [TimeInterval] = []
    private var pending: [@MainActor () -> Void] = []
    func record(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) { delays.append(delay); pending.append(fire) }
    func fireLatest() { pending.popLast()?() }
    func fireOldest() { if !pending.isEmpty { pending.removeFirst()() } }
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
