// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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
        #expect(!coordinator.capturePaused)
        #expect(coordinator.captureError == nil)
        #expect(bannerMessages.isEmpty)

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

    private func makeCoordinator(
        isTerminating: @escaping CaptureCoordinator.IsTerminatingProvider = { false },
        configProvider: @escaping CaptureCoordinator.MicUIDConfigProvider = {
            (disabled: Set<String>(), enabled: Set<String>())
        },
        bannerSink: @escaping CaptureCoordinator.BannerSink = { _ in },
        startOperation: CaptureCoordinator.StartOperation? = nil
    ) throws -> (CaptureCoordinator, URL) {
        let root = try makeTempDirectory("capture-coordinator")
        let captureManager = CaptureManager(storageManager: StorageManager(baseDirectory: root))
        let coordinator = CaptureCoordinator(
            captureManager: captureManager,
            pauseManager: PauseManager(),
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: isTerminating,
            configProvider: configProvider,
            bannerSink: bannerSink,
            startOperation: startOperation
        )
        return (coordinator, root)
    }
}

@MainActor
private final class StartOperationHarness: CaptureLifecycleDelegate {
    var lifecycleCurrentState: CaptureManager.State = .idle

    private let executor: CaptureExecutor
    private let startGate: OneShotContinuationGate?
    private let startCounter = LockedCounter()

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

    func lifecycleStopCapture(reason: StopReason) async {
        lifecycleCurrentState = .idle
    }

    func lifecycleRotateSegment(
        reason: RotateReason,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async -> RotationResult {
        .committed
    }

    func lifecyclePauseCapture(trigger: String, stopAudio: Bool) async -> URL? {
        lifecycleCurrentState = .paused
        return nil
    }

    func lifecyclePrepareResume(trigger: String) async throws {}

    func lifecycleCommitResume(trigger: String) {
        lifecycleCurrentState = .recording
    }

    func lifecycleAbortPreparedResume(trigger: String) async {
        lifecycleCurrentState = .paused
    }

    func lifecycleTransitionToError(message: String, error: Error, trigger: String) {
        lifecycleCurrentState = .error(message)
    }

    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool) {}
}
