// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
@testable import solstone

@MainActor
@Suite("CaptureCoordinator")
struct CaptureCoordinatorTests {
    @Test func stateChangeProjectsSynchronously() throws {
        let (coordinator, root) = try makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        var bannerMessages: [String?] = []
        coordinator.handleCaptureStateChange(.recording)

        #expect(coordinator.isRecording)
        #expect(!coordinator.isPaused)
        #expect(!coordinator.isUserPaused)
        #expect(coordinator.captureError == nil)
        #expect(bannerMessages.isEmpty)

        coordinator.handleCaptureStateChange(.paused(reasons: [.user]))
        #expect(coordinator.isRecording)
        #expect(coordinator.isPaused)
        #expect(coordinator.isUserPaused)

        coordinator.handleCaptureStateChange(.paused(reasons: [.lock]))
        #expect(coordinator.isRecording)
        #expect(coordinator.isPaused)
        #expect(!coordinator.isUserPaused)

        let (sinkCoordinator, sinkRoot) = try makeCoordinator(bannerSink: { bannerMessages.append($0) })
        defer { try? FileManager.default.removeItem(at: sinkRoot) }

        sinkCoordinator.handleCaptureStateChange(.recording)

        #expect(sinkCoordinator.isRecording)
        #expect(bannerMessages == [nil])
    }

    @Test func concurrentStartsEnterStartOperationOnce() async throws {
        let harness = StartOperationHarness(gateStarts: true)
        let (coordinator, root) = try makeCoordinator(startOperation: harness.operation)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = Task { @MainActor in
            await coordinator.startRecording()
        }
        await harness.waitForStartCount(1)
        #expect(harness.startCount == 1)

        let second = Task { @MainActor in
            await coordinator.startRecording()
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                harness.queuedIntentSnapshot == [IntentSnapshot(kind: .start(.user), stopAudio: false)]
            }
        }

        #expect(harness.startCount == 1)
        harness.releaseStart()
        await first.value
        await second.value
    }

    @Test func startLatchReleasesAfterSuccessAndThrow() async throws {
        let successHarness = StartOperationHarness()
        let (successCoordinator, successRoot) = try makeCoordinator(startOperation: successHarness.operation)
        defer { try? FileManager.default.removeItem(at: successRoot) }

        await successCoordinator.startRecording()
        successHarness.lifecycleCurrentState = .idle
        await successCoordinator.startRecording()

        #expect(successHarness.startCount == 2)

        var throwCount = 0
        var bannerMessages: [String?] = []
        let (throwCoordinator, throwRoot) = try makeCoordinator(
            bannerSink: { bannerMessages.append($0) },
            startOperation: { _, _ in
                throwCount += 1
                if throwCount == 1 {
                    return .threw(TransitionFailure(message: "failed", isPermissionError: false))
                }
                return .committed
            }
        )
        defer { try? FileManager.default.removeItem(at: throwRoot) }

        await throwCoordinator.startRecording()
        await throwCoordinator.startRecording()

        #expect(throwCount == 2)
        #expect(throwCoordinator.captureError == UICopy.ERROR_START_OBSERVING)
        #expect(bannerMessages == [UICopy.ERROR_START_OBSERVING])
    }

    @Test func startPermissionFailureMapsToDeniedWithoutBanner() async throws {
        var bannerMessages: [String?] = []
        let (coordinator, root) = try makeCoordinator(
            bannerSink: { bannerMessages.append($0) },
            startOperation: { _, _ in
                .threw(TransitionFailure(message: "permission denied", isPermissionError: true))
            }
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.startRecording()

        #expect(!coordinator.screenRecordingGranted)
        #expect(coordinator.captureError == nil)
        #expect(bannerMessages.isEmpty)
    }

    @Test func microphoneGrantedDerivesFromAuthorizationCause() throws {
        let source = try readWireUpSource("Sources/solstone/CaptureCoordinator.swift")
        #expect(!source.contains("public internal(set) var microphoneGranted = false"))

        let (coordinator, root) = try makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(MicrophoneAuthorizationCause, Bool)] = [
            (.authorized, true),
            (.notDetermined, false),
            (.denied, false),
            (.restricted, false),
            (.unknown, false),
        ]

        for (cause, granted) in cases {
            coordinator.microphoneAuthorizationCause = cause
            #expect(coordinator.microphoneGranted == granted)
        }
    }

    @Test func refreshMicrophoneAuthorizationUsesReaderWithoutStartingOrPolling() throws {
        let (coordinator, root) = try makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.screenRecordingGranted = true
        coordinator.microphoneAuthorizationReader = { .authorized }
        let wasPolling = coordinator.isPermissionPollingActiveForTesting

        coordinator.refreshMicrophoneAuthorization()

        #expect(coordinator.microphoneGranted)
        #expect(!coordinator.isRecording)
        #expect(coordinator.isPermissionPollingActiveForTesting == wasPolling)
    }

    @Test func refreshMicrophoneAuthorizationWorksWhileRecordingWithoutPolling() throws {
        let (coordinator, root) = try makeCoordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationCause = .denied
        coordinator.handleCaptureStateChange(.recording)
        #expect(coordinator.isRecording)
        #expect(!coordinator.isPermissionPollingActiveForTesting)
        coordinator.microphoneAuthorizationReader = { .authorized }

        coordinator.refreshMicrophoneAuthorization()

        #expect(coordinator.microphoneAuthorizationCause == .authorized)
        #expect(coordinator.microphoneGranted)
        #expect(!coordinator.isPermissionPollingActiveForTesting)
    }

    @Test func permissionReturnWhileInErrorStartsThroughInjectedOperation() async throws {
        let harness = StartOperationHarness()
        let (coordinator, root) = try makeCoordinator(startOperation: harness.operation)
        defer { try? FileManager.default.removeItem(at: root) }

        harness.lifecycleCurrentState = .error("permission denied")
        coordinator.handleCaptureStateChange(.error("permission denied"))
        coordinator.screenRecordingGranted = true
        coordinator.microphoneAuthorizationCause = .authorized

        await coordinator.startRecording(reason: .autoStart)

        #expect(harness.startCount == 1)
        #expect(harness.resetForRestartCount == 1)
        #expect(harness.lifecycleCurrentState.isRecording)
        #expect(coordinator.screenRecordingGranted)
    }

    @Test func captureStateIngestionControlsPermissionPollingAndBanner() throws {
        var bannerMessages: [String?] = []
        let (coordinator, root) = try makeCoordinator(bannerSink: { bannerMessages.append($0) })
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!coordinator.isPermissionPollingActiveForTesting)

        coordinator.handleCaptureStateChange(.idle)
        #expect(coordinator.isPermissionPollingActiveForTesting)
        #expect(bannerMessages.isEmpty)

        coordinator.handleCaptureStateChange(.recording)
        #expect(!coordinator.isPermissionPollingActiveForTesting)
        #expect(bannerMessages == [nil])

        coordinator.handleCaptureStateChange(.error("boom"))
        #expect(coordinator.isPermissionPollingActiveForTesting)
        #expect(bannerMessages == [nil, "boom"])
        #expect(coordinator.captureError == "boom")

        coordinator.handleCaptureStateChange(.recording)
        #expect(!coordinator.isPermissionPollingActiveForTesting)
    }

    @Test func startWhileUserPausedClearsPausePolicyWithoutResumeCallback() async throws {
        let pauseManager = PauseManager()
        pauseManager.pause(for: .minutes(15))
        let (coordinator, root) = try makeCoordinator(
            pauseManager: pauseManager,
            startOperation: { _, _ in .committed }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var resumeCallbackCount = 0
        pauseManager.onResume = {
            resumeCallbackCount += 1
        }
        coordinator.handleCaptureStateChange(.paused(reasons: [.user]))

        await coordinator.startRecording()

        #expect(!pauseManager.pauseState.isPaused)
        #expect(pauseManager.pauseState.expirationDate == nil)
        #expect(resumeCallbackCount == 0)
    }

    @Test func stopWhileUserPausedClearsPausePolicyWithoutResumeCallback() async throws {
        let pauseManager = PauseManager()
        pauseManager.pause(for: .minutes(15))
        let (coordinator, root) = try makeCoordinator(pauseManager: pauseManager)
        defer { try? FileManager.default.removeItem(at: root) }
        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111116.incomplete", isDirectory: true))
        coordinator.captureManager.seedRecordingForTesting(currentSegment: segment)
        _ = await coordinator.captureManager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        var resumeCallbackCount = 0
        pauseManager.onResume = {
            resumeCallbackCount += 1
        }
        coordinator.handleCaptureStateChange(.paused(reasons: [.user]))

        let outcome = await coordinator.stopRecording(reason: .user)

        guard case .committed = outcome else {
            Issue.record("expected stop from user pause to commit")
            return
        }
        #expect(!pauseManager.pauseState.isPaused)
        #expect(pauseManager.pauseState.expirationDate == nil)
        #expect(resumeCallbackCount == 0)
    }

    @Test func toggleRecordingWhileUserPausedResumesWithoutStarting() async throws {
        let pauseManager = PauseManager()
        pauseManager.pause(for: .indefinite)
        let startCount = LockedCounter()
        let (coordinator, root) = try makeCoordinator(
            pauseManager: pauseManager,
            startOperation: { _, _ in
                startCount.increment()
                return .committed
            }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let resumeCallbackCount = LockedCounter()
        pauseManager.onResume = {
            resumeCallbackCount.increment()
        }
        coordinator.handleCaptureStateChange(.paused(reasons: [.user]))

        await coordinator.toggleRecording()

        try await withTimeout(seconds: 2) {
            await resumeCallbackCount.waitUntilCount(1)
        }
        #expect(startCount.count == 0)
        #expect(!pauseManager.pauseState.isPaused)
    }

    @Test func autoStartPollDefersToScheduledRecoveryAndFiresWhenUnscheduled() async throws {
        let deferredStartCount = LockedCounter()
        let (deferredCoordinator, deferredRoot) = try makeCoordinator(
            startOperation: { _, _ in
                deferredStartCount.increment()
                return .committed
            },
            screenPermissionProvider: grantedScreenPermissionProvider()
        )
        defer { try? FileManager.default.removeItem(at: deferredRoot) }
        deferredCoordinator.captureManager.lifecycleTransitionToError(
            message: "transient",
            error: CaptureManager.CaptureError.noDisplaysAvailable,
            trigger: "test"
        )

        #expect(deferredCoordinator.captureManager.isRecoveryScheduled)
        deferredCoordinator.microphoneAuthorizationReader = { .authorized }

        await deferredCoordinator.checkPermissionsAndAutoStart()

        #expect(deferredStartCount.count == 0)
        #expect(deferredCoordinator.initialPermissionCheckComplete)

        let firedStartCount = LockedCounter()
        let (firedCoordinator, firedRoot) = try makeCoordinator(
            startOperation: { _, _ in
                firedStartCount.increment()
                return .committed
            },
            screenPermissionProvider: grantedScreenPermissionProvider()
        )
        defer { try? FileManager.default.removeItem(at: firedRoot) }

        #expect(!firedCoordinator.captureManager.isRecoveryScheduled)
        firedCoordinator.microphoneAuthorizationReader = { .authorized }

        await firedCoordinator.checkPermissionsAndAutoStart()

        #expect(firedStartCount.count == 1)
        #expect(firedCoordinator.initialPermissionCheckComplete)
    }

    @Test func livePermissionCheckReadsMicrophoneCauseBeforeScreenRecordingBranch() throws {
        let source = try readWireUpSource("Sources/solstone/CaptureCoordinator.swift")
        let functionStart = try #require(source.range(of: "internal func checkPermissionsAndAutoStart("))
        let functionEnd = try #require(
            source[functionStart.upperBound...].range(of: "\n    internal var isPermissionPollingActiveForTesting")
        )
        let body = source[functionStart.lowerBound..<functionEnd.lowerBound]
        let microphoneRead = try #require(body.range(of: "let microphoneCause = microphoneAuthorizationReader()"))
        let screenBranch = try #require(body.range(of: "if screenPermissionProvider.hasPrompted()"))

        #expect(microphoneRead.lowerBound < screenBranch.lowerBound)
    }

    private func makeCoordinator(
        pauseManager: PauseManager = PauseManager(),
        isTerminating: @escaping CaptureCoordinator.IsTerminatingProvider = { false },
        configProvider: @escaping CaptureCoordinator.MicUIDConfigProvider = {
            (disabled: Set<String>(), enabled: Set<String>())
        },
        bannerSink: @escaping CaptureCoordinator.BannerSink = { _ in },
        startOperation: CaptureCoordinator.StartOperation? = nil,
        screenPermissionProvider: ScreenRecordingPermissionProvider = .live
    ) throws -> (CaptureCoordinator, URL) {
        let root = try makeTempDirectory("capture-coordinator")
        let captureManager = CaptureManager(storageManager: StorageManager(baseDirectory: root))
        let coordinator = CaptureCoordinator(
            captureManager: captureManager,
            pauseManager: pauseManager,
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: isTerminating,
            configProvider: configProvider,
            bannerSink: bannerSink,
            startOperation: startOperation,
            screenPermissionProvider: screenPermissionProvider
        )
        return (coordinator, root)
    }

    private func grantedScreenPermissionProvider() -> ScreenRecordingPermissionProvider {
        ScreenRecordingPermissionProvider(
            hasPrompted: { true },
            preflight: { true },
            checkScreenRecording: { true },
            resetPromptedFlag: {}
        )
    }
}

@MainActor
private final class StartOperationHarness: CaptureLifecycleDelegate {
    var lifecycleCurrentState: CaptureManager.State = .idle

    private let executor: CaptureExecutor
    private let startGate: OneShotContinuationGate?
    private let startCounter = LockedCounter()
    private let resetForRestartCounter = LockedCounter()

    init(gateStarts: Bool = false) {
        self.startGate = gateStarts ? OneShotContinuationGate() : nil
        self.executor = CaptureExecutor(
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )
        executor.delegate = self
    }

    var startCount: Int {
        startCounter.count
    }

    var resetForRestartCount: Int {
        resetForRestartCounter.count
    }

    var queuedIntentSnapshot: [IntentSnapshot] {
        executor.queuedIntentSnapshotForTesting
    }

    func waitForStartCount(_ target: Int) async {
        await startCounter.waitUntilCount(target)
    }

    func releaseStart() {
        startGate?.release()
    }

    func operation(reason: StartReason, config: CaptureCoordinator.MicUIDConfig) async -> TransitionOutcome {
        await executor.enqueue(
            .start(
                reason: reason,
                disabledMicUIDs: config.disabled,
                enabledMicUIDs: config.enabled
            )
        )
    }

    func lifecycleStartCapture(
        reason: StartReason,
        disabledMicUIDs: Set<String>,
        enabledMicUIDs: Set<String>,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async throws -> StartResult {
        startCounter.increment()
        await startGate?.wait()
        lifecycleCurrentState = .recording
        return .committed
    }

    func lifecycleResetForRestartFromError() async {
        resetForRestartCounter.increment()
    }

    func lifecycleStartFromErrorFailed(_ failure: TransitionFailure) {}

    func lifecycleStopCapture(reason: StopReason) async {
        lifecycleCurrentState = .idle
    }

    func lifecycleRotateSegment(
        reason: RotateReason,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async -> RotationResult {
        .committed
    }

    func lifecyclePauseCapture(reason: PauseReason, stopAudio: Bool) async -> URL? {
        lifecycleCurrentState = .paused(reasons: lifecycleCurrentState.pausedReasons.union([reason]))
        return nil
    }

    func lifecycleApplyResumeReason(_ reason: ResumeReason) -> ResumeResolution {
        let current = lifecycleCurrentState.pausedReasons
        let remaining = current.subtracting(reason.clearsPauseReasons)
        if remaining.isEmpty {
            return .readyToResume(restore: current)
        }
        lifecycleCurrentState = .paused(reasons: remaining)
        return .stayedPaused
    }

    func lifecyclePrepareResume(trigger: String) async throws {}

    func lifecycleCommitResume(trigger: String) {
        lifecycleCurrentState = .recording
    }

    func lifecycleAbortPreparedResume(restore: Set<PauseReason>?, trigger: String) async {
        let reasons = restore?.isEmpty == false ? restore! : Set<PauseReason>([.lock])
        lifecycleCurrentState = .paused(reasons: reasons)
    }

    func lifecycleTransitionToError(message: String, error: Error, trigger: String) {
        lifecycleCurrentState = .error(message)
    }

    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool) {}
}
