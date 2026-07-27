// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
import SolstoneCore
@testable import solstone

@Suite("AppState.forSnapshot")
@MainActor
struct AppStateSnapshotTests {
    @Test func snapshotStateDefaults() {
        let state = AppState.forSnapshot()
        #expect(state.isRecording == false)
        #expect(state.errorMessage == nil)
        #expect(state.initialPermissionCheckComplete == false)
        #expect(state.observationRowState == .starting)
    }

    @Test func captureTruthSettersForwardToCoordinator() {
        let state = AppState.forSnapshot()

        state.isRecording = true
        state.isPaused = true
        state.screenRecordingGranted = true
        state.microphoneAuthorizationCause = .authorized
        state.initialPermissionCheckComplete = true
        state.captureQueuedForJournalReadiness = true
        state.audioReconciledCount = 3

        #expect(state.capture.isRecording)
        #expect(state.capture.isPaused)
        #expect(state.capture.screenRecordingGranted)
        #expect(state.capture.microphoneAuthorizationCause == .authorized)
        #expect(state.microphoneGranted)
        #expect(state.capture.microphoneGranted)
        #expect(state.capture.initialPermissionCheckComplete)
        #expect(state.capture.captureQueuedForJournalReadiness)
        #expect(state.capture.audioReconciledCount == 3)
    }

    @Test func snapshotCaptureCoordinatorIsInertButHeartbeatProviderWorks() async {
        let state = AppState.forSnapshot()

        #expect(state.capture.captureManager.onStateChanged == nil)
        #expect(state.pauseManager.onPause == nil)
        #expect(state.pauseManager.onResume == nil)
        #expect(state.audioDeviceMonitor.onDeviceChange == nil)
        #expect(!state.capture.isPermissionPollingActiveForTesting)
        #expect(await state.heartbeatService.pausedForTesting() == false)

        state.isPaused = true
        #expect(await state.heartbeatService.pausedForTesting() == true)

        state.isPaused = false
        state.pauseManager.pause(for: .indefinite)
        #expect(await state.heartbeatService.pausedForTesting() == false)
        state.pauseManager.resume()
    }

    @Test func appStateDoesNotStoreCaptureTruthMirrors() throws {
        let appStateSource = try readWireUpSource("Sources/solstone/AppState.swift")
        let coordinatorSource = try readWireUpSource("Sources/solstone/CaptureCoordinator.swift")

        let removedDeclarations = [
            "public internal(set) var isRecording = false",
            "public internal(set) var isPaused = false",
            "public internal(set) var audioReconciledCount: Int = 0",
            "public internal(set) var captureQueuedForJournalReadiness: Bool = false",
            "public internal(set) var screenRecordingGranted = false",
            "internal var microphoneAuthorizationCause: MicrophoneAuthorizationCause = .unknown",
            "public internal(set) var initialPermissionCheckComplete = false",
            "private var permissionPollTimer: Timer?",
            "private var isCheckingPermissions = false"
        ]

        for declaration in removedDeclarations {
            #expect(!appStateSource.contains(declaration))
        }

        #expect(coordinatorSource.contains("public internal(set) var isRecording = false"))
        #expect(coordinatorSource.contains("internal var microphoneAuthorizationCause: MicrophoneAuthorizationCause = .unknown"))
        #expect(coordinatorSource.contains("private var permissionPollTimer: Timer?"))
        #expect(coordinatorSource.contains("private var isCheckingPermissions = false"))
    }

}
