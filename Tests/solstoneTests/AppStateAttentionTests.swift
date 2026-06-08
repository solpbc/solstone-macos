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

    @Test func serviceNeedsAttentionBundledFalseDuringUpgradeWithOutdatedProbe() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .cleaningUp(SubprocessProgress(phase: "upgrade pre-clean"))
        state.installer.probedVersion = .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion)
        state.installer.upgradeInProgress = true

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledTrueWhenFailed() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .failed(.installSolstone(message: "failed"))

        #expect(state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenInstalledCurrent() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.installer.probedVersion = .current(version: "0.3.2")

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledFalseWhenInstalledOutdatedWithoutRecord() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.installer.probedVersion = .outdated(installed: "0.3.1", pinned: "0.3.2")

        #expect(!state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledTrueWhenUpgradeFailed() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .failed(.installSolstone(message: "failed"))
        state.installer.upgradeFailureRecord = UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        )

        #expect(state.serviceNeedsAttention)
    }

    @Test func serviceNeedsAttentionBundledTrueWhenPostInstallAutoTestFails() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.installer.probedVersion = .current(version: BundleConfig.solstonePinVersion)
        state.installer.postInstallAutoTest = .failure("offline")

        #expect(state.serviceNeedsAttention)
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
        #expect(serviceTabHeadingText(for: nil) == "set up your journal")
    }

    @Test func serviceTabHeadingAbsentWhenServiceModeSet() {
        #expect(serviceTabHeadingText(for: .bundled) == nil)
        #expect(serviceTabHeadingText(for: .external) == nil)
    }

    @Test func initialServiceModeDefaultsToBundledWhenConfigModeUnset() {
        #expect(initialServiceMode(for: AppConfig(serviceMode: nil)) == .bundled)
    }

    @Test func initialServiceModeUsesBundledConfigMode() {
        #expect(initialServiceMode(for: AppConfig(serviceMode: .bundled)) == .bundled)
    }

    @Test func initialServiceModeUsesExternalConfigMode() {
        #expect(initialServiceMode(for: AppConfig(serviceMode: .external)) == .external)
    }

    @Test func settingsViewInitializationDoesNotPersistInitialServiceMode() {
        let state = makeState(config: AppConfig(serviceMode: nil))
        _ = SettingsView(appState: state, updateController: UpdateController())

        #expect(state.config.serviceMode == nil)
    }

    @Test func serviceAttentionUsesPersistedBundledModeNotSelectorState() {
        let state = makeState(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.installer.probedVersion = .current(version: "0.3.2")

        #expect(!state.serviceNeedsAttention)
    }

    @Test func permissionsAreDoneRequiresAllPermissionInputs() {
        let missingInitialCheck = makeState()
        missingInitialCheck.initialPermissionCheckComplete = false
        missingInitialCheck.screenRecordingGranted = true
        missingInitialCheck.microphoneGranted = true
        #expect(!missingInitialCheck.permissionsAreDone)

        let missingScreen = makeState()
        missingScreen.initialPermissionCheckComplete = true
        missingScreen.screenRecordingGranted = false
        missingScreen.microphoneGranted = true
        #expect(!missingScreen.permissionsAreDone)

        let missingMicrophone = makeState()
        missingMicrophone.initialPermissionCheckComplete = true
        missingMicrophone.screenRecordingGranted = true
        missingMicrophone.microphoneGranted = false
        #expect(!missingMicrophone.permissionsAreDone)

        let done = makeState()
        done.initialPermissionCheckComplete = true
        done.screenRecordingGranted = true
        done.microphoneGranted = true
        #expect(done.permissionsAreDone)
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

    @Test func serviceIsDoneMatchesTruthfulDoneMatrixAcrossServiceStateSurface() {
        let cases = serviceAttentionCases()
        #expect(cases.count == 113)

        for testCase in cases {
            let state = makeState(config: AppConfig(serviceMode: testCase.serviceMode))
            if let main = testCase.main {
                state.installer.main = main
            }
            state.installer.probedVersion = testCase.probe
            state.installer.upgradeFailureRecord = testCase.record
            if let connectionTestState = testCase.connectionTestState {
                state.connectionTestState = connectionTestState
            }

            #expect(state.serviceIsDone == expectedServiceIsDone(for: testCase, state: state), "failed case: \(testCase.name)")
        }
    }

    @Test func serviceIsDoneBundledNeutralStatesAreNotDoneAndNeedNoAttention() {
        let progress = SubprocessProgress(phase: "phase")
        let cases: [(String, MainState, VersionProbeResult?)] = [
            ("detecting", .detecting, nil),
            ("installing", .installingSolstone(progress), nil),
            ("installedPlaceholder", .awaitingChoice(existingInstall: true), nil),
            ("installedUnknown", .done, .unknown),
            ("outdatedPendingUpgrade", .done, .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion)),
        ]

        for (name, main, probe) in cases {
            let state = makeState(config: AppConfig(serviceMode: .bundled))
            state.installer.main = main
            state.installer.probedVersion = probe

            #expect(!state.serviceNeedsAttention, "attention failed case: \(name)")
            #expect(!state.serviceIsDone, "done failed case: \(name)")
        }
    }

    @Test func serviceIsDoneBundledReadyStatesAreDone() {
        let cases: [(String, MainState, VersionProbeResult?)] = [
            ("done", .done, nil),
            ("installedCurrent", .done, .current(version: BundleConfig.solstonePinVersion)),
            ("externallyManaged", .externallyManaged(solPath: "/opt/sol"), nil),
        ]

        for (name, main, probe) in cases {
            let state = makeState(config: AppConfig(serviceMode: .bundled))
            state.installer.main = main
            state.installer.probedVersion = probe

            #expect(!state.serviceNeedsAttention, "attention failed case: \(name)")
            #expect(state.serviceIsDone, "done failed case: \(name)")
        }
    }

    @Test func serviceIsDoneBundledAttentionStatesAreNotDone() {
        let matchingRecord = UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        )
        let cases: [(String, MainState, VersionProbeResult?, UpgradeFailureRecord?)] = [
            ("absent", .awaitingChoice(existingInstall: false), nil, nil),
            ("failed", .failed(.installSolstone(message: "failed")), nil, nil),
            ("upgradeFailed", .failed(.installSolstone(message: "failed")), nil, matchingRecord),
        ]

        for (name, main, probe, record) in cases {
            let state = makeState(config: AppConfig(serviceMode: .bundled))
            state.installer.main = main
            state.installer.probedVersion = probe
            state.installer.upgradeFailureRecord = record

            #expect(state.serviceNeedsAttention, "attention failed case: \(name)")
            #expect(!state.serviceIsDone, "done failed case: \(name)")
        }
    }

    @Test func serviceIsDoneExternalBehaviorIsUnchanged() {
        let cases: [(String, ConnectionTestState, Bool)] = [
            ("idle", .idle, false),
            ("testing", .testing, false),
            ("failure", .failure("offline"), false),
            ("success", .success, true),
        ]

        for (name, connectionState, expectedDone) in cases {
            let state = makeState(config: AppConfig(serviceMode: .external))
            state.connectionTestState = connectionState

            #expect(state.serviceIsDone == expectedDone, "failed case: \(name)")
            #expect(state.serviceIsDone == !state.serviceNeedsAttention, "attention parity failed case: \(name)")
        }
    }

    private func makeState(config: AppConfig = AppConfig()) -> AppState {
        AppState.forSnapshot(config: config)
    }

    private struct ServiceAttentionCase {
        let name: String
        let serviceMode: ServiceMode?
        let main: MainState?
        let probe: VersionProbeResult?
        let record: UpgradeFailureRecord?
        let connectionTestState: ConnectionTestState?
    }

    private func serviceAttentionCases() -> [ServiceAttentionCase] {
        let progress = SubprocessProgress(phase: "phase")
        let mainStates: [(String, MainState)] = [
            ("detecting", .detecting),
            ("awaitingChoiceFalse", .awaitingChoice(existingInstall: false)),
            ("awaitingChoiceTrue", .awaitingChoice(existingInstall: true)),
            ("cleaningUp", .cleaningUp(progress)),
            ("installingSolstone", .installingSolstone(progress)),
            ("runningSolSetup", .runningSolSetup(progress)),
            ("registering", .registering(progress)),
            ("done", .done),
            ("failed", .failed(.installSolstone(message: "failed")))
        ]
        let probes: [(String, VersionProbeResult?)] = [
            ("nilProbe", nil),
            ("current", .current(version: "0.3.2")),
            ("outdated", .outdated(installed: "0.3.1", pinned: "0.3.2")),
            ("unknown", .unknown)
        ]
        let records: [(String, UpgradeFailureRecord?)] = [
            ("nilRecord", nil),
            ("matchingRecord", UpgradeFailureRecord(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion, errorDetails: "details")),
            ("staleRecord", UpgradeFailureRecord(installed: "0.3.1", pinned: "0.3.7", errorDetails: "details"))
        ]

        let bundled = mainStates.flatMap { mainName, main in
            probes.flatMap { probeName, probe in
                records.map { recordName, record in
                    ServiceAttentionCase(
                        name: "bundled-\(mainName)-\(probeName)-\(recordName)",
                        serviceMode: .bundled,
                        main: main,
                        probe: probe,
                        record: record,
                        connectionTestState: nil
                    )
                }
            }
        }

        let externalStates: [(String, ConnectionTestState)] = [
            ("idle", .idle),
            ("testing", .testing),
            ("success", .success),
            ("failure", .failure("offline"))
        ]
        let external = externalStates.map { name, state in
            ServiceAttentionCase(
                name: "external-\(name)",
                serviceMode: .external,
                main: nil,
                probe: nil,
                record: nil,
                connectionTestState: state
            )
        }

        return [
            ServiceAttentionCase(
                name: "nil-mode",
                serviceMode: nil,
                main: nil,
                probe: nil,
                record: nil,
                connectionTestState: nil
            )
        ] + external + bundled
    }

    private func expectedServiceIsDone(for testCase: ServiceAttentionCase, state: AppState) -> Bool {
        guard let serviceMode = testCase.serviceMode else { return false }
        switch serviceMode {
        case .external:
            return !state.serviceNeedsAttention
        case .bundled:
            guard let main = testCase.main else { return false }
            switch terminalCardState(main: main, probe: testCase.probe, failureRecord: testCase.record) {
            case .installedCurrent, .done, .externallyManaged:
                return true
            case .detecting,
                 .absent,
                 .installing,
                 .installedPlaceholder,
                 .installedUnknown,
                 .upgradeFailed,
                 .failed:
                return false
            }
        }
    }
}
