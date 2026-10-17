// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MacTestSupport
import os
import Testing
import SolstoneCore
import UpdateKit
@testable import solstone

@MainActor
private final class ClockBox: @unchecked Sendable {
    nonisolated(unsafe) var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: ScreenCaptureProbeResult

    init(_ result: ScreenCaptureProbeResult) {
        self.result = result
    }
}

private final class BoolBox: @unchecked Sendable {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

@MainActor
private final class TestHarness {
    let clock: ClockBox
    let tempDir: URL
    let bytesStore: InMemoryDiagnosticEvidenceBytesStore
    let store: DiagnosticEvidenceStore
    let recorder: DiagnosticEvidenceRecorder
    let scheduler: PermissionPollTestScheduler
    let logSink: RecordingClassifiedLogSink
    let coordinator: CaptureCoordinator

    init(
        initialTime: Date = Date(timeIntervalSince1970: 1_700_000_000),
        screenPermissionProvider: ScreenRecordingPermissionProvider,
        configuredSources: CaptureSources = .screen,
        startOperation: CaptureCoordinator.StartOperation? = nil
    ) throws {
        let clock = ClockBox(initialTime)
        let tempDir = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-grant-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bytesStore = InMemoryDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytesStore, now: { clock.now })
        let recorder = DiagnosticEvidenceRecorder(store: store, now: { clock.now })
        let scheduler = PermissionPollTestScheduler()
        let logSink = RecordingClassifiedLogSink()

        let coordinator = CaptureCoordinator(
            captureManager: CaptureManager(storageManager: StorageManager(baseDirectory: tempDir)),
            pauseManager: PauseManager(),
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: { false },
            configProvider: { (sources: configuredSources, disabled: [], enabled: []) },
            bannerSink: { _ in },
            setAsideSink: { _ in },
            startOperation: startOperation,
            recorder: recorder,
            screenPermissionProvider: screenPermissionProvider,
            permissionPollScheduler: scheduler.scheduler,
            logAdapter: DiagnosticEvidenceLoggingAdapter(),
            classifiedLog: logSink,
            now: { clock.now },
            screenProbeFastWindow: 120,
            screenProbeSlowInterval: 15
        )

        self.clock = clock
        self.tempDir = tempDir
        self.bytesStore = bytesStore
        self.store = store
        self.recorder = recorder
        self.scheduler = scheduler
        self.logSink = logSink
        self.coordinator = coordinator
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

@Suite("Screen recording grant probe")
@MainActor
struct ScreenRecordingGrantProbeTests {
    @Test func grantWhilePreflightFalseSetsNeedsRestartAndDoesNotPublishGranted() async throws {
        let harness = try TestHarness(
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: { .granted }
            )
        )
        defer { harness.cleanup() }

        let initialSources = harness.coordinator.permittedSources
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()

        #expect(harness.coordinator.screenRecordingNeedsRestart)
        #expect(!harness.coordinator.screenRecordingGranted)
        #expect(!harness.coordinator.isRecording)
        #expect(harness.coordinator.permittedSources == initialSources)
        let readResult = await harness.recorder.read()
        guard case .available(let envelope) = readResult else {
            Issue.record("Expected available evidence envelope")
            return
        }
        #expect(!evidenceCodes(envelope.entries).contains(.screenRecordingGranted))
    }

    @Test func deniedOrTimeoutLeavesNeedsRestartFalse() async throws {
        let probeResult = ResultBox(.denied)
        let harness = try TestHarness(
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: { probeResult.result }
            )
        )
        defer { harness.cleanup() }

        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(!harness.coordinator.screenRecordingNeedsRestart)

        probeResult.result = .unavailable(.timeout)
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(!harness.coordinator.screenRecordingNeedsRestart)
    }

    @Test func publishNotGrantedAfterGrantLeavesNeedsRestartTrue() async throws {
        let harness = try TestHarness(
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: { .granted }
            )
        )
        defer { harness.cleanup() }

        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(harness.coordinator.screenRecordingNeedsRestart)

        harness.coordinator.publishScreenRecordingPermission(.notGranted)
        #expect(harness.coordinator.screenRecordingNeedsRestart)
    }

    @Test func gating() async throws {
        var probeCount = 0
        let prompted = BoolBox(false)
        let preflight = BoolBox(false)
        let harness = try TestHarness(
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { prompted.value },
                preflight: { preflight.value },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: {
                    probeCount += 1
                    return .denied
                }
            )
        )
        defer { harness.cleanup() }

        // hasPrompted is false
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 0)

        // preflight is true
        prompted.value = true
        preflight.value = true
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 0)

        // screenRecordingNeedsRestart is true
        preflight.value = false
        harness.coordinator.screenRecordingNeedsRestart = true
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 0)
    }

    @Test func overlappingCallsCoalesce() async throws {
        var probeCount = 0
        let lock = NSLock()
        var continuation: CheckedContinuation<ScreenCaptureProbeResult, Never>?
        let harness = try TestHarness(
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: {
                    lock.withLock {
                        probeCount += 1
                    }
                    return await withCheckedContinuation { cont in
                        lock.withLock {
                            continuation = cont
                        }
                    }
                }
            )
        )
        defer { harness.cleanup() }

        let t1 = Task { @MainActor in
            await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        }

        while true {
            let (count, cont) = lock.withLock { (probeCount, continuation) }
            if count == 1 && cont != nil { break }
            await Task.yield()
        }

        let t2 = Task { @MainActor in
            await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        }
        let t3 = Task { @MainActor in
            await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        }

        await Task.yield()

        let (currentCount, cont) = lock.withLock { () -> (Int, CheckedContinuation<ScreenCaptureProbeResult, Never>?) in
            let c = (probeCount, continuation)
            continuation = nil
            return c
        }

        #expect(currentCount == 1)
        cont?.resume(returning: .denied)

        await t1.value
        await t2.value
        await t3.value

        let finalCount = lock.withLock { probeCount }
        #expect(finalCount == 1)
    }

    @Test func backoffTiming() async throws {
        var probeCount = 0
        let nextResult = ResultBox(.denied)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = try TestHarness(
            initialTime: baseTime,
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: {
                    probeCount += 1
                    return nextResult.result
                }
            )
        )
        defer { harness.cleanup() }

        // t=0: denial probes
        harness.clock.now = baseTime
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 1)

        // t=5s: probes again (inside 2-minute fast window and within 15s of last count)
        harness.clock.now = baseTime.addingTimeInterval(5)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 2)

        // t=120s: fast window expired (now < epoch + 120 is false).
        // Last counted was t=5s (115s ago >= 15s) -> probes
        harness.clock.now = baseTime.addingTimeInterval(120)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 3)

        // t=121s: fast window expired, and 1s < 15s since last count at t=120s -> does not probe
        harness.clock.now = baseTime.addingTimeInterval(121)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 3)

        // t=135s: 15s since t=120s -> probes
        harness.clock.now = baseTime.addingTimeInterval(135)
        nextResult.result = .granted
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 4)
        #expect(harness.coordinator.screenRecordingNeedsRestart)

        // Next call at t=136s: stopped via gate (screenRecordingNeedsRestart is true)
        harness.clock.now = baseTime.addingTimeInterval(136)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 4)
    }

    @Test func cancellation() async throws {
        var probeCount = 0
        let lock = NSLock()
        var continuation: CheckedContinuation<ScreenCaptureProbeResult, Never>?
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = try TestHarness(
            initialTime: baseTime,
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: {
                    lock.withLock {
                        probeCount += 1
                    }
                    return await withCheckedContinuation { cont in
                        lock.withLock {
                            continuation = cont
                        }
                    }
                }
            )
        )
        defer { harness.cleanup() }

        // At t=180s, start a probe and cancel it before completion
        harness.clock.now = baseTime.addingTimeInterval(180)
        let task = Task { @MainActor in
            await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        }
        while true {
            let cont = lock.withLock { continuation }
            if cont != nil { break }
            await Task.yield()
        }
        #expect(probeCount == 1)

        task.cancel()
        let cont1 = lock.withLock { () -> CheckedContinuation<ScreenCaptureProbeResult, Never>? in
            let c = continuation
            continuation = nil
            return c
        }
        cont1?.resume(returning: .unavailable(.cancelled))
        await task.value

        #expect(!harness.coordinator.screenRecordingNeedsRestart)
        #expect(harness.logSink.emissions.isEmpty)

        // At t=181s: call still probes (cancel did not count or advance lastCounted)
        harness.clock.now = baseTime.addingTimeInterval(181)
        let task2 = Task { @MainActor in
            await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        }
        while true {
            let cont = lock.withLock { continuation }
            if cont != nil { break }
            await Task.yield()
        }
        #expect(probeCount == 2)

        let cont2 = lock.withLock { () -> CheckedContinuation<ScreenCaptureProbeResult, Never>? in
            let c = continuation
            continuation = nil
            return c
        }
        cont2?.resume(returning: .denied)
        await task2.value

        #expect(!harness.coordinator.screenRecordingNeedsRestart)
        #expect(harness.logSink.emissions.count == 1)

        // At t=182s: does not probe.
        // Proves epoch is still t=0 (not t=180s), and lastCounted is t=181s (182 - 181 = 1 < 15s).
        harness.clock.now = baseTime.addingTimeInterval(182)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 2)
    }

    @Test func activationEpochReset() async throws {
        var probeCount = 0
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = try TestHarness(
            initialTime: baseTime,
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: {
                    probeCount += 1
                    return .denied
                }
            )
        )
        defer { harness.cleanup() }

        // Count at t=120s
        harness.clock.now = baseTime.addingTimeInterval(120)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 1)

        // Call at t=121s does not probe
        harness.clock.now = baseTime.addingTimeInterval(121)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 1)

        // noteApplicationDidBecomeActive() at t=121s resets epoch to t=121s
        harness.coordinator.noteApplicationDidBecomeActive()

        // Call at t=121s probes because now (121) < new epoch (121) + 120 (241)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(probeCount == 2)
    }

    @Test func logEmissions() async throws {
        let nextResult = ResultBox(.denied)
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = try TestHarness(
            initialTime: baseTime,
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {},
                probe: { nextResult.result }
            )
        )
        defer { harness.cleanup() }

        // 1. Denial
        harness.clock.now = baseTime
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(harness.logSink.emissions.count == 1)
        let firstEmission = harness.logSink.emissions[0]
        #expect(firstEmission.level == ClassifiedLogLevel.notice)
        #expect(firstEmission.classification == "screen-capture-probe")
        #expect(firstEmission.publicFields["result"] == "denied")
        #expect(firstEmission.publicFields["reason"] == nil)

        // 2. Denial again -> no new emission
        harness.clock.now = baseTime.addingTimeInterval(1)
        nextResult.result = .denied
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(harness.logSink.emissions.count == 1)

        // 3. .unavailable(.timeout) -> new emission because result changed
        harness.clock.now = baseTime.addingTimeInterval(2)
        nextResult.result = .unavailable(.timeout)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(harness.logSink.emissions.count == 2)
        let secondEmission = harness.logSink.emissions[1]
        #expect(secondEmission.level == ClassifiedLogLevel.notice)
        #expect(secondEmission.classification == "screen-capture-probe")
        #expect(secondEmission.publicFields["result"] == "unavailable")
        #expect(secondEmission.publicFields["reason"] == "timeout")

        // 4. .unavailable(.timeout) again -> no new emission (same result & reason)
        harness.clock.now = baseTime.addingTimeInterval(3)
        nextResult.result = .unavailable(.timeout)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(harness.logSink.emissions.count == 2)

        // 5. .unavailable(.signal) -> new emission because reason changed
        harness.clock.now = baseTime.addingTimeInterval(4)
        nextResult.result = .unavailable(.signal)
        await harness.coordinator.probeScreenRecordingGrantIfWaiting()
        #expect(harness.logSink.emissions.count == 3)
        let thirdEmission = harness.logSink.emissions[2]
        #expect(thirdEmission.level == ClassifiedLogLevel.notice)
        #expect(thirdEmission.classification == "screen-capture-probe")
        #expect(thirdEmission.publicFields["result"] == "unavailable")
        #expect(thirdEmission.publicFields["reason"] == "signal")
    }

    @Test func freshView() {
        let state = AppState.forSnapshot(
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {}
            )
        )
        let isolatedDefaults = IsolatedUserDefaults()
        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: isolatedDefaults.defaults
        ) { _, _ in nil }
        let view = SettingsView(appState: state, updateController: updateController, selectedTab: .permissions)
        #expect(view.screenRecordingPermissionAXState == .waiting)
    }

    @Test func negativeTwin() async throws {
        var probeCount = 0
        let harness = try TestHarness(
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { true },
                checkScreenRecording: { true },
                resetPromptedFlag: {},
                probe: {
                    probeCount += 1
                    return .denied
                }
            ),
            configuredSources: .screen,
            startOperation: { _, _, _ in .vetoed }
        )
        defer { harness.cleanup() }

        await harness.coordinator.checkPermissionsAndAutoStart()

        #expect(probeCount == 0)
        #expect(!harness.coordinator.screenRecordingNeedsRestart)
        #expect(harness.coordinator.screenRecordingGranted)

        let readResult = await harness.recorder.read()
        guard case .available(let envelope) = readResult else {
            Issue.record("Expected available evidence envelope")
            return
        }
        #expect(evidenceCodes(envelope.entries).contains(.screenRecordingGranted))
    }
}
