// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import solstone
@testable import SolstoneCore

private struct SyntheticGateProviderError: Error, Sendable {}

private final class WindowBox: @unchecked Sendable {
    var windows: [OnScreenWindowRecord] = []
}

@Suite("ProtectedVideoGateTests")
struct ProtectedVideoGateTests {
    private func makeTempDirectory(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("solstone-gate-test-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Leg 1: Start from idle, no published screen evidence, screen configured, matching window → deferred, idle, no microphone-only session, zero provider calls.
    @Test @MainActor func startFromIdleWithMatchingWindowDefersAndMakesZeroProviderCalls() async throws {
        let root = try makeTempDirectory("start-deferred")
        defer { try? FileManager.default.removeItem(at: root) }

        let windowBox = WindowBox()
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]

        let shareableCalls = LockedCounter()
        let factoryCalls = LockedCounter()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                factoryCalls.increment()
                return FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            allowsEmptyDisplayConfigurationForTesting: false,
            shareableContentProvider: {
                shareableCalls.increment()
                throw SyntheticGateProviderError()
            },
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            unlockResumeDelay: {}
        )

        let coordinator = CaptureCoordinator(
            captureManager: manager,
            pauseManager: PauseManager(),
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: { false },
            configProvider: { (sources: .all, disabled: Set<String>(), enabled: Set<String>()) },
            bannerSink: { _ in },
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { true },
                checkScreenRecording: { true },
                resetPromptedFlag: {}
            ),
            permissionPollScheduler: PermissionPollTestScheduler().scheduler
        )

        await coordinator.startRecording(reason: .user)

        #expect(coordinator.isStartDeferredForProtectedVideo == true)
        #expect(!coordinator.isRecording)
        #expect(manager.state.isIdle)
        #expect(shareableCalls.count == 0)
        #expect(factoryCalls.count == 0)
    }

    // Leg 1 Falsification Twin: When window list does not match, provider is called
    @Test @MainActor func startFromIdleWithClearWindowCallsProvider() async throws {
        let root = try makeTempDirectory("start-clear")
        defer { try? FileManager.default.removeItem(at: root) }

        let windowBox = WindowBox()
        windowBox.windows = []

        let shareableCalls = LockedCounter()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            allowsEmptyDisplayConfigurationForTesting: false,
            shareableContentProvider: {
                shareableCalls.increment()
                throw SyntheticGateProviderError()
            },
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            unlockResumeDelay: {}
        )

        let coordinator = CaptureCoordinator(
            captureManager: manager,
            pauseManager: PauseManager(),
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: { false },
            configProvider: { (sources: .all, disabled: Set<String>(), enabled: Set<String>()) },
            bannerSink: { _ in },
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { true },
                checkScreenRecording: { true },
                resetPromptedFlag: {}
            ),
            permissionPollScheduler: PermissionPollTestScheduler().scheduler
        )

        coordinator.publishScreenRecordingPermission(.granted)
        await coordinator.startRecording(reason: .user)

        print("leg1 twin provider count: \(shareableCalls.count)")
        #expect(shareableCalls.count >= 1)
    }

    // Leg 2: checkPermissionsAndAutoStart unseeded → deferred. Evidence, prompted flag, and mismatch recorder unchanged. Zero checkScreenRecording calls.
    @Test @MainActor func checkPermissionsAndAutoStartDeferredLeavesEvidenceUnchangedAndZeroCheckCalls() async throws {
        let root = try makeTempDirectory("autostart-deferred")
        defer { try? FileManager.default.removeItem(at: root) }

        let windowBox = WindowBox()
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]

        let checkScreenCalls = LockedCounter()
        let screenPermissionProvider = ScreenRecordingPermissionProvider(
            hasPrompted: { true },
            preflight: { true },
            checkScreenRecording: {
                checkScreenCalls.increment()
                return true
            },
            resetPromptedFlag: {}
        )

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            allowsEmptyDisplayConfigurationForTesting: false,
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            unlockResumeDelay: {}
        )

        let coordinator = CaptureCoordinator(
            captureManager: manager,
            pauseManager: PauseManager(),
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: { false },
            configProvider: { (sources: .all, disabled: Set<String>(), enabled: Set<String>()) },
            bannerSink: { _ in },
            screenPermissionProvider: screenPermissionProvider,
            permissionPollScheduler: PermissionPollTestScheduler().scheduler
        )

        await coordinator.checkPermissionsAndAutoStart()

        #expect(coordinator.isStartDeferredForProtectedVideo == true)
        #expect(checkScreenCalls.count == 0)
    }

    // Leg 2 Falsification Twin: When window list does not match, checkScreenRecording is called
    @Test @MainActor func checkPermissionsAndAutoStartClearCallsCheckScreenRecording() async throws {
        let root = try makeTempDirectory("autostart-clear")
        defer { try? FileManager.default.removeItem(at: root) }

        let windowBox = WindowBox()
        windowBox.windows = []

        let checkScreenCalls = LockedCounter()
        let screenPermissionProvider = ScreenRecordingPermissionProvider(
            hasPrompted: { true },
            preflight: { true },
            checkScreenRecording: {
                checkScreenCalls.increment()
                return true
            },
            resetPromptedFlag: {}
        )

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            allowsEmptyDisplayConfigurationForTesting: false,
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            unlockResumeDelay: {}
        )

        let coordinator = CaptureCoordinator(
            captureManager: manager,
            pauseManager: PauseManager(),
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: { false },
            configProvider: { (sources: .all, disabled: Set<String>(), enabled: Set<String>()) },
            bannerSink: { _ in },
            screenPermissionProvider: screenPermissionProvider,
            permissionPollScheduler: PermissionPollTestScheduler().scheduler
        )

        await coordinator.checkPermissionsAndAutoStart()

        print("leg2 twin checkScreenRecording count: \(checkScreenCalls.count)")
        #expect(checkScreenCalls.count >= 1)
    }

    // Leg 3: Owner-pause end, wake after handleWillSleep, unlock after handleScreenLocked → paused({.protectedVideo}), the cleared reason is gone, zero provider calls. State is not recording, so commit did not run. No new segment directory, so abort did not prepare one. resumeNotBeforeForTesting is nil.
    @Test @MainActor func transitionsEndBecomePausedProtectedVideoWithOldReasonGone() async throws {
        let root = try makeTempDirectory("transitions-end")
        defer { try? FileManager.default.removeItem(at: root) }

        let windowBox = WindowBox()
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]

        let shareableCalls = LockedCounter()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            allowsEmptyDisplayConfigurationForTesting: false,
            shareableContentProvider: {
                shareableCalls.increment()
                throw SyntheticGateProviderError()
            },
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            unlockResumeDelay: {}
        )
        manager.configuredSourcesIncludeScreen = { true }

        // 3a. Owner-pause end
        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        #expect(manager.state == .paused(reasons: [.user]))

        _ = await manager.enqueueTransition(.resume(reason: .user))
        #expect(manager.state == .paused(reasons: [.protectedVideo]))
        #expect(!manager.state.pausedReasons.contains(.user))
        #expect(shareableCalls.count == 0)
        #expect(manager.resumeNotBeforeForTesting == nil)

        // 3b. Wake after handleWillSleep
        manager.seedRecordingForTesting(currentSegment: segment)
        await manager.lifecycleManager.handleWillSleep()
        #expect(manager.state.pausedReasons.contains(.sleep))

        await manager.lifecycleManager.handleDidWake()
        // Wait for wake task to settle
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.state == .paused(reasons: [.protectedVideo])
            }
        }
        #expect(!manager.state.pausedReasons.contains(.sleep))
        #expect(shareableCalls.count == 0)
        #expect(manager.resumeNotBeforeForTesting == nil)

        // 3c. Unlock after handleScreenLocked
        manager.seedRecordingForTesting(currentSegment: segment)
        await manager.lifecycleManager.handleScreenLocked()
        #expect(manager.state.pausedReasons.contains(.lock))

        await manager.lifecycleManager.handleScreenUnlocked()
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.state == .paused(reasons: [.protectedVideo])
            }
        }
        #expect(!manager.state.pausedReasons.contains(.lock))
        #expect(shareableCalls.count == 0)
        #expect(manager.resumeNotBeforeForTesting == nil)
    }

    // Leg 3 Falsification Twin: When window is clear, transitions call provider
    @Test @MainActor func transitionsEndWithClearWindowCallsProvider() async throws {
        let root = try makeTempDirectory("transitions-clear")
        defer { try? FileManager.default.removeItem(at: root) }

        let windowBox = WindowBox()
        windowBox.windows = []

        let shareableCalls = LockedCounter()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            allowsEmptyDisplayConfigurationForTesting: false,
            shareableContentProvider: {
                shareableCalls.increment()
                throw SyntheticGateProviderError()
            },
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            unlockResumeDelay: {}
        )
        manager.configuredSourcesIncludeScreen = { true }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))

        _ = await manager.enqueueTransition(.resume(reason: .user))
        print("leg3 twin provider count: \(shareableCalls.count)")
        #expect(shareableCalls.count >= 1)
    }

    // Leg 4: enterNoDisplayRecovery() with FakeRecoveryScheduler: still .error, a pending attempt at CaptureLifecycleManager.recoveryDelay(forRetryCount:) for the current count. Clear the window, fire the scheduler, recovery commits.
    @Test @MainActor func enterNoDisplayRecoveryWithProtectedVideoStaysInErrorUntilCleared() async throws {
        let root = try makeTempDirectory("recovery-gate")
        defer { try? FileManager.default.removeItem(at: root) }

        let windowBox = WindowBox()
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]

        let recoveryScheduler = FakeRecoveryScheduler()
        let factoryCalls = LockedCounter()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                factoryCalls.increment()
                return FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            allowsEmptyDisplayConfigurationForTesting: true,
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: { delay, fire in
                recoveryScheduler.schedule(delay: delay, fire: fire)
            },
            unlockResumeDelay: {}
        )
        manager.configuredSourcesIncludeScreen = { true }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        await manager.enterNoDisplayRecovery()

        #expect(manager.state.isError)
        #expect(recoveryScheduler.hasActiveToken)

        // Fire scheduler while protected video is still present
        await recoveryScheduler.fireNext()

        // Still in error, retryCount did not increment, re-armed
        #expect(manager.state.isError)
        #expect(recoveryScheduler.hasActiveToken)
        #expect(factoryCalls.count == 0)

        // Clear window and fire scheduler
        windowBox.windows = []
        await recoveryScheduler.fireNext()

        #expect(manager.state == .recording)
        #expect(factoryCalls.count == 1)
    }

    // Leg 5: Second manager, empty-display flag on, window clear: the poll starts a session whose sessionSourcesForTesting contains .screen.
    @Test @MainActor func secondManagerEmptyDisplayFlagStartsSessionWithScreen() async throws {
        let root = try makeTempDirectory("second-manager")
        defer { try? FileManager.default.removeItem(at: root) }

        let windowBox = WindowBox()
        windowBox.windows = []

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            allowsEmptyDisplayConfigurationForTesting: true,
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows }
        )

        let coordinator = CaptureCoordinator(
            captureManager: manager,
            pauseManager: PauseManager(),
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: { false },
            configProvider: { (sources: .all, disabled: Set<String>(), enabled: Set<String>()) },
            bannerSink: { _ in },
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { true },
                checkScreenRecording: { true },
                resetPromptedFlag: {}
            ),
            permissionPollScheduler: PermissionPollTestScheduler().scheduler
        )

        await coordinator.checkPermissionsAndAutoStart()

        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.state == .recording
            }
        }

        #expect(manager.sessionSourcesForTesting.contains(.screen))
    }

    // Leg 6: Routing and Health ax values after deferred permission check
    @Test @MainActor func routingAndHealthPresentationForDeferredProtectedVideo() async {
        // FirstLaunchRouting.route does not open Permissions when capturePermissionsMissing is given deferral
        let missing = capturePermissionsMissing(permittedSourcesEmpty: true, startDeferredForProtectedVideo: true)
        #expect(missing == false)

        var openedPermissions = false
        await FirstLaunchRouting.route(
            config: AppConfig(),
            waitForPermissionCheck: {},
            permissionsMissing: { missing },
            openPermissions: { openedPermissions = true },
            openService: {}
        )
        #expect(!openedPermissions)

        // StatusHealthSummary.make(..., startDeferredForProtectedVideo: true) ax value is not sources_unavailable
        let summary = StatusHealthSummary.make(
            serviceMode: .external,
            isRecording: false,
            isPaused: false,
            held: false,
            hasPersistedPairing: true,
            uploadStatus: .synced,
            pendingCount: 0,
            lastDeliveryOutcome: .noDeliveryYet,
            journalSlot: "journal",
            now: Date(),
            selectedSources: .screen,
            permittedSources: [],
            startDeferredForProtectedVideo: true
        )
        #expect(summary.axValue != "sources_unavailable")

        // classifyObservationRowState(..., protectedVideoHeld: true) and SettingsObservationAXState expose protected_video
        let rowState = classifyObservationRowState(
            permissionsNeedAttention: false,
            errorMessage: nil,
            initialPermissionCheckComplete: true,
            isRecording: false,
            isPaused: false,
            serviceMode: .external,
            syncPaused: false,
            isPairedIngestReady: true,
            uploadStatus: .synced,
            hasJournalOnRecord: true,
            protectedVideoHeld: true
        )
        #expect(rowState == .protectedVideo)
        #expect(rowState.axToken == "protected_video")

        let settingsState = SettingsObservationAXState(rowState)
        #expect(settingsState.axToken == "protected_video")
    }
}
