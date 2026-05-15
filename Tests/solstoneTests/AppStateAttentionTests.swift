// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("AppState attention")
@MainActor
struct AppStateAttentionTests {
    @Test func permissionsNeedAttentionFalseWhenBothPermissionsGranted() {
        let state = makeState()
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = true
        state.microphoneGranted = true

        #expect(!state.permissionsNeedAttention)
    }

    @Test func permissionsNeedAttentionTrueWhenScreenMissing() {
        let state = makeState()
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = false
        state.microphoneGranted = true

        #expect(state.permissionsNeedAttention)
    }

    @Test func permissionsNeedAttentionTrueWhenMicrophoneMissing() {
        let state = makeState()
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = true
        state.microphoneGranted = false

        #expect(state.permissionsNeedAttention)
    }

    @Test func permissionsNeedAttentionFalseBeforeInitialPermissionCheck() {
        let state = makeState()
        state.initialPermissionCheckComplete = false
        state.screenRecordingGranted = false
        state.microphoneGranted = false

        #expect(!state.permissionsNeedAttention)
    }

    @Test func serviceNeedsAttentionTrueWhenModeUnset() {
        let state = makeState(config: AppConfig(serviceMode: nil))

        #expect(state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledTrueWhenInstallerAbsent() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .awaitingChoice(existingInstall: false)

        #expect(state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenDetecting() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .detecting

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenInstalling() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .installingSolstone(SubprocessProgress(phase: "phase"))

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenFailed() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .failed(.installSolstone(message: "failed"))

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenInstalledCurrent() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.installer.probedVersion = .current(version: "0.3.2")

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenInstalledOutdated() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.installer.probedVersion = .outdated(installed: "0.3.1", pinned: "0.3.2")

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenInstalledUnknown() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.installer.probedVersion = .unknown

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenDoneOrPlaceholder() {
        let done = makeState(config: AppConfig(serviceMode: .bundled))
        done.installer.main = .done
        done.installer.probedVersion = nil

        let placeholder = makeState(config: AppConfig(serviceMode: .bundled))
        placeholder.installer.main = .awaitingChoice(existingInstall: true)
        placeholder.installer.probedVersion = nil

        #expect(!done.serviceNeedsAttention)
        #expect(!placeholder.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionExternalTrueWhenIdle() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .idle

        #expect(state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionExternalTrueWhenTesting() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .testing

        #expect(state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionExternalTrueWhenFailure() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .failure("offline")

        #expect(state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionExternalFalseWhenSuccess() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .success

        #expect(!state.serviceNeedsAttention)
    }

    @Test func anyTabNeedsAttentionCombinesPermissionsAndService() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = true
        state.microphoneGranted = true
        state.connectionTestState = .success
        #expect(!state.anyTabNeedsAttention)

        state.microphoneGranted = false
        #expect(state.anyTabNeedsAttention)

        state.microphoneGranted = true
        state.connectionTestState = .idle
        #expect(state.anyTabNeedsAttention)
    }

    @Test func externalURLFieldEditResetsSuccessfulConnectionTestToIdle() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .success

        state.connectionTestState = .idle

        #expect(state.connectionTestState == .idle)
    }

    @Test func externalKeyFieldEditResetsFailedConnectionTestToIdle() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .failure("offline")

        state.connectionTestState = .idle

        #expect(state.connectionTestState == .idle)
    }

    @Test func externalSuccessClearsServiceAttention() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .success

        #expect(!state.serviceNeedsAttention)
    }

    @Test func externalFailureSetsServiceAttention() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .failure("offline")

        #expect(state.serviceNeedsAttention)
    }

    @Test func externalIdleSetsServiceAttention() {
        let state = makeState(config: AppConfig(serviceMode: .external))
        state.connectionTestState = .idle

        #expect(state.serviceNeedsAttention)
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

    @Test func serviceTabHeadingPresentWhenServiceModeNil() {
        #expect(serviceTabHeadingText(for: nil) == "set up the solstone service")
    }

    @Test func serviceTabHeadingAbsentWhenServiceModeSet() {
        #expect(serviceTabHeadingText(for: .bundled) == nil)
        #expect(serviceTabHeadingText(for: .external) == nil)
    }

    private func makeState(config: AppConfig = AppConfig()) -> AppState {
        AppState.forSnapshot(config: config)
    }
}
