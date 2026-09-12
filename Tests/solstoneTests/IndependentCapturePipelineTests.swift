// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import ScreenCaptureKit
import SolstoneCore
import Testing
@testable import solstone

@MainActor
@Suite("Independent capture pipeline")
struct IndependentCapturePipelineTests {

    @Test func permissionAndSelectionMatrix() async throws {
        let causes: [MicrophoneAuthorizationCause] = [.authorized, .denied, .notDetermined, .restricted, .unknown]
        let selections: [CaptureSources] = [[], .screen, .microphone, .all]
        // Exercise both a denied screen prompt and a never-requested screen permission.
        for screenState in ["granted", "denied", "undetermined"] {
            for cause in causes {
                for selection in selections {
                    var starts: [CaptureSources] = []
                    let (coordinator, root) = try makeCoordinator(
                        configProvider: { (selection, [], []) },
                        startOperation: { _, sources, _ in starts.append(sources); return .committed },
                        screenPermissionProvider: ScreenRecordingPermissionProvider(
                            hasPrompted: { screenState != "undetermined" },
                            preflight: { screenState == "granted" },
                            checkScreenRecording: {
                                #expect(selection.contains(.screen))
                                return screenState == "granted"
                            }, resetPromptedFlag: {}
                        )
                    )
                    coordinator.microphoneAuthorizationReader = { cause }
                    await coordinator.checkPermissionsAndAutoStart()
                    var expected: CaptureSources = []
                    if screenState == "granted", selection.contains(.screen) { expected.insert(.screen) }
                    if cause == .authorized, selection.contains(.microphone) { expected.insert(.microphone) }
                    #expect(starts == (expected.isEmpty ? [] : [expected]))
                    #expect(coordinator.screenRecordingGranted == (screenState == "granted"))
                    try FileManager.default.removeItem(at: root)
                }
            }
        }
    }

    @Test func coordinatorExplicitStopPreventsAutoStartUntilExplicitStart() async throws {
        let startCount = LockedCounter()
        let (coordinator, root) = try makeCoordinator(
            startOperation: { _, _, _ in
                startCount.increment()
                return .committed
            },
            screenPermissionProvider: grantedScreenPermissionProvider()
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .authorized }

        // Initial auto-start succeeds
        await coordinator.checkPermissionsAndAutoStart()
        #expect(startCount.count == 1)
        #expect(!coordinator.isExplicitlyStopped)

        // User stops recording -> isExplicitlyStopped becomes true
        await coordinator.stopRecording(reason: .user)
        #expect(coordinator.isExplicitlyStopped)
        #expect(!coordinator.isRecording)

        // Permission check or poll does NOT auto-start while explicitly stopped
        await coordinator.checkPermissionsAndAutoStart()
        #expect(startCount.count == 1)

        // Explicit user start resets isExplicitlyStopped and starts recording
        await coordinator.startRecording(reason: .user)
        #expect(!coordinator.isExplicitlyStopped)
        #expect(startCount.count == 2)
    }

    @Test func coordinatorStartsOnlyPermittedAndEnabledSources() async throws {
        var admittedSourcesPassed: CaptureSources?
        let (coordinator, root) = try makeCoordinator(
            configProvider: {
                (sources: [.screen, .microphone], disabled: [], enabled: [])
            },
            startOperation: { _, sources, _ in
                admittedSourcesPassed = sources
                return .committed
            },
            screenPermissionProvider: grantedScreenPermissionProvider()
        )
        defer { try? FileManager.default.removeItem(at: root) }
        // Screen is granted, mic is denied
        coordinator.microphoneAuthorizationReader = { .denied }

        await coordinator.checkPermissionsAndAutoStart()
        #expect(admittedSourcesPassed == [.screen])
    }

    @Test func coordinatorMicOnlyStartsWhenScreenDenied() async throws {
        var admittedSourcesPassed: CaptureSources?
        let (coordinator, root) = try makeCoordinator(
            configProvider: {
                (sources: [.microphone], disabled: [], enabled: [])
            },
            startOperation: { _, sources, _ in
                admittedSourcesPassed = sources
                return .committed
            },
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true },
                preflight: { false },
                checkScreenRecording: { false },
                resetPromptedFlag: {}
            )
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .authorized }

        await coordinator.checkPermissionsAndAutoStart()
        #expect(admittedSourcesPassed == [.microphone])
    }

    @Test func coordinatorDoesNotStartWhenNoSourcesAdmitted() async throws {
        let startCount = LockedCounter()
        let (coordinator, root) = try makeCoordinator(
            configProvider: {
                (sources: [], disabled: [], enabled: [])
            },
            startOperation: { _, _, _ in
                startCount.increment()
                return .committed
            },
            screenPermissionProvider: grantedScreenPermissionProvider()
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .authorized }

        await coordinator.startRecording()
        #expect(startCount.count == 0)
    }

    @Test func captureManagerIgnoresMicChangesInScreenOnlySession() async throws {
        let finalizer = FakeFinalizer()
        let root = try makeTempDirectory("screen-only-mic-event")
        defer { try? FileManager.default.removeItem(at: root) }

        let segmentBox = LockedValue<FakeCaptureSegment>()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: outputDirectory)
                segmentBox.set(segment)
                return segment
            },
            finalizer: finalizer,
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )
        let startOutcome = await executor.enqueue(.start(reason: .user, sources: [.screen], disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = startOutcome else {
            Issue.record("expected start to commit")
            return
        }
        #expect(manager.activeSources == [.screen])

        // Triggering device change should be a no-op because microphone source is inactive
        let testMic = AudioInputDevice(id: AudioDeviceID(42), name: "New Mic", uid: "new-mic", manufacturer: nil, sampleRate: 48000, transportType: .usb)
        await manager.handleDeviceChange(added: [testMic], removed: [])
        // No errors or state disruptions
        #expect(manager.activeSources == [.screen])
    }

    @Test func captureManagerIgnoresDisplayChangesInMicOnlySession() async throws {
        let finalizer = FakeFinalizer()
        let root = try makeTempDirectory("mic-only-display-event")
        defer { try? FileManager.default.removeItem(at: root) }

        let segmentBox = LockedValue<FakeCaptureSegment>()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: outputDirectory)
                segmentBox.set(segment)
                return segment
            },
            finalizer: finalizer,
            shareableContentProvider: {
                Issue.record("microphone-only must not ask ScreenCaptureKit for displays")
                throw CaptureManager.CaptureError.noDisplaysAvailable
            }
        )

        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )
        let startOutcome = await executor.enqueue(.start(reason: .user, sources: [.microphone], disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = startOutcome else {
            Issue.record("expected start to commit")
            return
        }
        await manager.handleDisplayChange()
        #expect(manager.activeSources == [.microphone])
    }

    @Test func lossOfOnlyMicrophoneNeverClaimsScreenIsRunning() {
        let state = AppState.forSnapshot(config: AppConfig(isMicrophoneCaptureEnabled: true))
        state.isRecording = true
        #expect(state.captureManager.activeSources.isEmpty)
        #expect(state.captureSourcesStatusText == UICopy.SOURCES_UNAVAILABLE)
        #expect(state.captureSourceNotice == nil)
    }

    @Test func appStatePermissionsDerivedFromSelectedSources() {
        let config = AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: false)
        let state = AppState.forSnapshot(config: config)
        state.initialPermissionCheckComplete = true

        // Screen enabled, mic disabled
        state.capture.publishScreenRecordingPermission(.notGranted)
        state.capture.microphoneAuthorizationCause = .denied
        #expect(state.permissionsNeedAttention)
        #expect(!state.permissionsAreDone)

        // Grant screen -> attention should be false and permissionsAreDone should be true even though mic is denied
        state.capture.publishScreenRecordingPermission(.granted)
        #expect(!state.permissionsNeedAttention)
        #expect(state.permissionsAreDone)

        // Selecting an ungranted second source does not make the usable screen source need permission.
        var updatedConfig = state.config
        updatedConfig.isMicrophoneCaptureEnabled = true
        state.updateConfig(updatedConfig)
        #expect(!state.permissionsNeedAttention)
        #expect(state.permissionsAreDone)

        // Grant mic
        state.capture.microphoneAuthorizationCause = .authorized
        #expect(!state.permissionsNeedAttention)
        #expect(state.permissionsAreDone)
    }

    @Test func aSelectedPermittedSourceStartsWithoutAnExplicitStart() async throws {
        let starts = LockedCounter()
        let (coordinator, root) = try makeCoordinator(
            configProvider: { (sources: [.microphone], disabled: [], enabled: []) },
            startOperation: { _, _, _ in starts.increment(); return .committed },
            screenPermissionProvider: grantedScreenPermissionProvider()
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .authorized }
        await coordinator.checkPermissionsAndAutoStart()
        #expect(starts.count == 1)
    }

    @Test func anExplicitStopStillSurvivesPermissionPolling() async throws {
        let starts = LockedCounter()
        let (coordinator, root) = try makeCoordinator(
            configProvider: { (sources: [.microphone], disabled: [], enabled: []) },
            startOperation: { _, _, _ in starts.increment(); return .committed },
            screenPermissionProvider: grantedScreenPermissionProvider()
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .authorized }
        _ = await coordinator.stopRecording(reason: .user)
        await coordinator.checkPermissionsAndAutoStart()
        #expect(starts.count == 0)
    }

    @Test(arguments: [false, true])
    func microphoneRequiresADeviceThatActuallyStarts(failingDevice: Bool) async throws {
        let root = try makeTempDirectory("source-mic-start-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = FakeAudioManager(behavior: .throwOnMicrophoneStart)
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000",
            screenshotCapturerFactory: { _, _, _, _, _, _ in
                Issue.record("microphone-only constructed a screenshot capturer")
                return FakeScreenshotCapturer()
            },
            audioManagerFactory: { _, _, _, _ in audio })
        do {
            _ = try await writer.start(sources: .microphone,
                mics: failingDevice ? [testMicrophone] : [], micCaptureManager: MicrophoneCaptureManager())
            Issue.record("zero successful microphones must not commit")
        } catch {}
        #expect(audio.startSystemAudioCount.count == 0)
        #expect(audio.addMicrophoneCount.count == (failingDevice ? 1 : 0))
    }

    @Test func failedScreenStartStillStartsMicrophoneWithoutScreenMedia() async throws {
        let root = try makeTempDirectory("source-screen-start-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = FakeAudioManager()
        let screen = FakeScreenshotCapturer(behavior: .throwOnStart)
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000",
            screenshotCapturerFactory: { _, videoURL, _, _, _, _ in
                // A failed SCK start can leave partial media behind.
                try Data("partial screen".utf8).write(to: videoURL)
                try Data("partial system audio".utf8).write(to: root.appendingPathComponent("120000_audio_system.m4a"))
                return screen
            },
            audioManagerFactory: { _, _, _, _ in audio })
        let active = try await writer.start(sources: .all, displayInfos: [testDisplay], mics: [testMicrophone])
        #expect(active == .microphone)
        #expect(screen.stopCount.count > 0)
        #expect(audio.addMicrophoneCount.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func screenOnlyNeverAttachesMicrophones() async throws {
        let root = try makeTempDirectory("source-screen-only")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = FakeAudioManager()
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000",
            screenshotCapturerFactory: { _, _, _, _, _, _ in FakeScreenshotCapturer() },
            audioManagerFactory: { _, _, _, _ in audio })
        let active = try await writer.start(sources: .screen, displayInfos: [testDisplay], mics: [testMicrophone])
        #expect(active == .screen)
        #expect(audio.addMicrophoneCount.count == 0)
        _ = await writer.finishCapture()
    }

    @Test func disconnectedMicrophoneStopsBeingReportedAndCanRejoinSelectedSession() async throws {
        let root = try makeTempDirectory("source-mic-disconnect")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = MicrophoneCaptureManager()
        let audio = PerSourceAudioManager(outputDirectory: root, timePrefix: "120000",
            captureManager: capture, startMicrophoneCapture: { _ in })
        let writer = SegmentWriter(outputDirectory: root, timePrefix: "120000",
            audioManagerFactory: { _, _, _, _ in audio })
        _ = try await writer.start(sources: .microphone, mics: [testMicrophone])
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root), finalizer: FakeFinalizer())
        manager.seedRecordingForTesting(currentSegment: writer, sources: .microphone)
        await manager.handleDeviceChange(added: [], removed: [testMicrophone])
        #expect(manager.activeSources.isEmpty)
        #expect(audio.activeMicrophoneUIDs().isEmpty)
        let replacement = AudioInputDevice(id: 43, name: "Replacement Mic", uid: "replacement-mic",
            manufacturer: nil, sampleRate: 48000, transportType: .usb)
        await manager.handleDeviceChange(added: [replacement], removed: [])
        #expect(manager.activeSources == .microphone)
        #expect(audio.activeMicrophoneUIDs() == [replacement.uid])
        _ = await manager.enqueueTransition(.stop(reason: .user))
    }

    @Test func failedMicrophoneStartupLeavesNoRegisteredWriterOrMetadata() async throws {
        let root = try makeTempDirectory("source-mic-registration")
        defer { try? FileManager.default.removeItem(at: root) }
        let called = LockedCounter()
        let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "120000",
            captureManager: MicrophoneCaptureManager(), startMicrophoneCapture: { _ in
                called.increment()
                throw FakeCaptureError.startFailed
            })
        do {
            _ = try manager.addMicrophone(testMicrophone)
            Issue.record("expected startup failure after writer creation")
        } catch {}
        #expect(called.count == 1)
        #expect(manager.activeMicrophoneUIDs().isEmpty)
        #expect(manager.getMicMetadata().isEmpty)
        #expect(await manager.finishAll().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func displayInitializationFailureFallsBackBeforeStartingSegment() async throws {
        let root = try makeTempDirectory("source-display-init-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { path, _, _, _, _ in FakeCaptureSegment(outputDirectory: path) },
            finalizer: FakeFinalizer(), microphoneDevices: { [] },
            shareableContentProvider: { throw CaptureManager.CaptureError.noDisplaysAvailable })
        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        let outcome = await executor.enqueue(.start(reason: .user, sources: .all, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = outcome else { Issue.record("healthy selected mic fallback did not commit"); return }
        #expect(manager.activeSources == .microphone)
        _ = await executor.enqueue(.stop(reason: .user))
    }

    private var testMicrophone: AudioInputDevice {
        AudioInputDevice(id: AudioDeviceID(42), name: "Fixture Mic", uid: "fixture-mic", manufacturer: nil,
            sampleRate: 48000, transportType: .usb)
    }

    private var testDisplay: DisplayInfo {
        DisplayInfo(displayID: 42, width: 64, height: 64, bounds: CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    // MARK: - Test Helpers

    private func makeCoordinator(
        pauseManager: PauseManager = PauseManager(),
        isTerminating: @escaping CaptureCoordinator.IsTerminatingProvider = { false },
        configProvider: @escaping CaptureCoordinator.CaptureConfigProvider = {
            (sources: .all, disabled: Set<String>(), enabled: Set<String>())
        },
        bannerSink: @escaping CaptureCoordinator.BannerSink = { _ in },
        startOperation: CaptureCoordinator.StartOperation? = nil,
        screenPermissionProvider: ScreenRecordingPermissionProvider = .live,
        permissionPollScheduler: PermissionPollScheduler? = nil
    ) throws -> (CaptureCoordinator, URL) {
        let root = try makeTempDirectory("capture-coordinator-independent")
        let captureManager = CaptureManager(storageManager: StorageManager(baseDirectory: root))
        let coordinator = CaptureCoordinator(
            captureManager: captureManager,
            pauseManager: pauseManager,
            audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
            isTerminating: isTerminating,
            configProvider: configProvider,
            bannerSink: bannerSink,
            startOperation: startOperation,
            screenPermissionProvider: screenPermissionProvider,
            permissionPollScheduler: permissionPollScheduler ?? PermissionPollTestScheduler().scheduler
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
