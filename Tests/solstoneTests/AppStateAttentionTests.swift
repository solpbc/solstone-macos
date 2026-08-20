// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
import UpdateKit
@testable import solstone

@Suite("AppState attention")
@MainActor
struct AppStateAttentionTests {
    @Test func permissionsNeedAttentionFalseWhenBothPermissionsGranted() {
        let state = makeState()
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = true
        state.microphoneAuthorizationCause = .authorized

        #expect(!state.permissionsNeedAttention)
    }

    @Test func permissionsNeedAttentionTrueWhenScreenMissing() {
        let state = makeState()
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = false
        state.microphoneAuthorizationCause = .authorized

        #expect(state.permissionsNeedAttention)
    }

    @Test func permissionsNeedAttentionTrueWhenMicrophoneMissing() {
        let state = makeState()
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = true
        state.microphoneAuthorizationCause = .denied

        #expect(state.permissionsNeedAttention)
    }

    @Test func permissionsNeedAttentionFalseBeforeInitialPermissionCheck() {
        let state = makeState()
        state.initialPermissionCheckComplete = false
        state.screenRecordingGranted = false
        state.microphoneAuthorizationCause = .denied

        #expect(!state.permissionsNeedAttention)
    }

    @Test func serviceNeedsAttentionTrueWhenModeUnsetBecauseUploadConfigMissing() {
        let state = makeState(config: AppConfig(serviceMode: nil))

        #expect(state.serviceNeedsAttention)
        #expect(!state.serviceIsDone)
    }

    @Test func serviceNeedsAttentionTrueWhenExternalUploadConfigMissing() {
        let state = makeState(config: AppConfig(serviceMode: .external))

        #expect(state.serviceNeedsAttention)
        #expect(!state.serviceIsDone)
    }

    @Test func serviceNeedsAttentionFalseWhenExternalUploadConfigPresent() {
        let state = makeState(config: configuredExternal())

        #expect(!state.serviceNeedsAttention)
        #expect(state.serviceIsDone)
    }

    @Test func configuredNilModeUsesExternalFallbackForServiceDone() {
        let state = makeState(config: AppConfig(
            serverURL: "https://example.com",
            serverKey: "key",
            serviceMode: nil
        ))

        #expect(!state.serviceNeedsAttention)
        #expect(state.serviceIsDone)
    }

    @Test func loopbackExternalUploadConfigIsDone() {
        let state = makeState(config: AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "key",
            serviceMode: .external
        ))

        #expect(!state.serviceNeedsAttention)
        #expect(state.serviceIsDone)
    }

    @Test func bundledModeAlwaysNeedsMigrationAttentionAndIsNotDone() {
        let state = makeState(config: AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "key",
            serviceMode: .bundled
        ))

        #expect(state.serviceNeedsAttention)
        #expect(!state.serviceIsDone)
    }

    @Test func externalConnectionTestStateNoLongerDrivesServiceAttention() {
        for connectionTestState in [ConnectionTestState.idle, .testing, .failure("offline"), .success] {
            let state = makeState(config: configuredExternal())
            state.connectionTestState = connectionTestState

            #expect(!state.serviceNeedsAttention)
            #expect(state.serviceIsDone)
        }
    }

    @Test func connectButtonDisabledUntilConnectionTestSucceeds() {
        #expect(isConnectButtonDisabled(observerURL: "", observerKey: "key", connectionTestState: .success))
        #expect(isConnectButtonDisabled(observerURL: "http://localhost:5015", observerKey: "", connectionTestState: .success))
        #expect(isConnectButtonDisabled(observerURL: "http://localhost:5015", observerKey: "key", connectionTestState: .idle))
        #expect(!isConnectButtonDisabled(observerURL: "http://localhost:5015", observerKey: "key", connectionTestState: .success))
    }

    @Test func inFlightConnectionTestResultIgnoredAfterFieldEdit() {
        let generation = UUID()
        var inFlightTestID: UUID? = generation
        var state = ConnectionTestState.testing

        inFlightTestID = nil
        state = .idle
        if shouldApplyConnectionTestCompletion(inFlightTestID: inFlightTestID, testGeneration: generation) {
            state = .success
        }

        #expect(state == .idle)
    }

    @Test func resolvedServiceModeDefaultsToExternalWhenConfigModeUnset() {
        #expect(resolvedServiceMode(for: AppConfig(serviceMode: nil)) == .external)
    }

    @Test func resolvedServiceModeUsesBundledConfigMode() {
        #expect(resolvedServiceMode(for: AppConfig(serviceMode: .bundled)) == .bundled)
    }

    @Test func resolvedServiceModeUsesExternalConfigMode() {
        #expect(resolvedServiceMode(for: AppConfig(serviceMode: .external)) == .external)
    }

    @Test func permissionsAreDoneRequiresAllPermissionInputs() {
        let missingInitialCheck = makeState()
        missingInitialCheck.initialPermissionCheckComplete = false
        missingInitialCheck.screenRecordingGranted = true
        missingInitialCheck.microphoneAuthorizationCause = .authorized
        #expect(!missingInitialCheck.permissionsAreDone)

        let missingScreen = makeState()
        missingScreen.initialPermissionCheckComplete = true
        missingScreen.screenRecordingGranted = false
        missingScreen.microphoneAuthorizationCause = .authorized
        #expect(!missingScreen.permissionsAreDone)

        let missingMicrophone = makeState()
        missingMicrophone.initialPermissionCheckComplete = true
        missingMicrophone.screenRecordingGranted = true
        missingMicrophone.microphoneAuthorizationCause = .denied
        #expect(!missingMicrophone.permissionsAreDone)

        let done = makeState()
        done.initialPermissionCheckComplete = true
        done.screenRecordingGranted = true
        done.microphoneAuthorizationCause = .authorized
        #expect(done.permissionsAreDone)
    }

    @Test func menubarPresentationComposesSnapshotAppStateInputs() {
        let state = makeState(config: configuredExternal())
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = true
        state.microphoneAuthorizationCause = .authorized
        state.isRecording = true
        state.uploadCoordinator.status = .synced

        let presentation = state.menubarPresentation(
            durableUpdateStatus: .available(version: "1.3.9", releaseNotes: nil)
        )

        #expect(presentation.observation == .observing)
        #expect(presentation.attention == .updateAvailable)
        #expect(presentation.icon == .recording)
        #expect(presentation.overlayState == .attention)
    }

    @Test func updateAttentionStatusesReachRecordingIcon() {
        let statuses: [(String, DurableUpdateStatus)] = [
            ("available", .available(version: "1.3.9", releaseNotes: nil)),
            ("staged", .staged(version: "1.3.9", releaseNotes: nil)),
            ("deferred", .deferred(version: "1.3.9")),
            ("failedWithAvailable", .failedWithAvailable(version: "1.3.9")),
            ("failed", .failed),
        ]

        for (name, status) in statuses {
            let state = makeState(config: configuredExternal())
            state.initialPermissionCheckComplete = true
            state.screenRecordingGranted = true
            state.microphoneAuthorizationCause = .authorized
            state.isRecording = true
            state.uploadCoordinator.status = .synced

            let presentation = state.menubarPresentation(durableUpdateStatus: status)

            #expect(presentation.icon == .recording, "\(name) should preserve the recording icon")
            #expect(presentation.showsAttentionBadge, "\(name) should show the attention badge")
        }
    }

    @Test func menubarPresentationSurfacesMicrophoneAuthorizationAttention() {
        let cases: [(MicrophoneAuthorizationCause, Bool)] = [
            (.authorized, false),
            (.notDetermined, true),
            (.denied, true),
            (.restricted, true),
            (.unknown, true),
        ]

        for (cause, expectsPermissionsAttention) in cases {
            let state = makeState(config: configuredExternal())
            state.initialPermissionCheckComplete = true
            state.screenRecordingGranted = true
            state.microphoneAuthorizationCause = cause
            state.isRecording = true
            state.uploadCoordinator.status = .synced

            let presentation = state.menubarPresentation(durableUpdateStatus: .idle)

            #expect((presentation.attention == .permissions) == expectsPermissionsAttention)
        }
    }

    @Test func visitedSettingsTabsPersistAndRestore() {
        let key = "SolstoneVisitedSettingsTabs"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let state = makeState()
        state.markSettingsTabVisited(.service)
        state.markSettingsTabVisited(.service)

        #expect(state.visitedSettingsTabs == ["service"])
        #expect(UserDefaults.standard.stringArray(forKey: key) == ["service"])

        let restored = makeState()
        #expect(restored.visitedSettingsTabs == ["service"])
    }

    private func makeState(config: AppConfig = AppConfig()) -> AppState {
        AppState.forSnapshot(config: config)
    }

    private func configuredExternal() -> AppConfig {
        AppConfig(serverURL: "https://example.com", serverKey: "key", serviceMode: .external)
    }
}
