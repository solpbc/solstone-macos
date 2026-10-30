// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import os
import SolstoneCore
import UpdateKit

@MainActor
internal enum SolstoneStartupComposition {
    enum ConfigurationFailureChoice {
        case retry
        case quit
    }

    static func makeNormalStartup<Startup>(
        decision: AppPlacementDecision,
        repairCoordinator: AppPlacementRepairCoordinator = .shared,
        automaticObservationPipelineEnabled: Bool,
        nativeSetupEnabled: Bool = journalSupportsSetupSequence(Bundle.main.object(forInfoDictionaryKey: "SolstoneSetupCapabilities")),
        loadConfiguration: @escaping @MainActor (Bool) throws -> AppConfig = { enabled in
            try AppConfig.loadOrCreateDefault(nativeSetupEnabled: enabled)
        },
        onConfigurationFailure: @escaping @MainActor (Error) -> ConfigurationFailureChoice = { _ in
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = UICopy.SETUP_COULDNT_SAVE_PROGRESS
            alert.addButton(withTitle: UICopy.SETUP_TRY_AGAIN)
            alert.addButton(withTitle: AppPlacementAlertCopy.repairSecondaryButton)
            return alert.runModal() == .alertFirstButtonReturn ? .retry : .quit
        },
        markExpectedExit: @escaping @MainActor (String) -> Void = { reason in
            ExpectedExitMarker.markExpectedExit(reason: reason)
        },
        terminateBeforeStartup: @escaping @MainActor () -> Void = { terminateFromMainRunLoop() },
        evidenceNow: @escaping @Sendable () -> Date = Date.init,
        makeEvidenceStore: @escaping @MainActor (@escaping @Sendable () -> Date) -> DiagnosticEvidenceStore = { now in
            DiagnosticEvidenceStore(now: now)
        },
        makeRecorder: @escaping @MainActor (DiagnosticEvidenceStore, @escaping @Sendable () -> Date) -> DiagnosticEvidenceRecorder = { store, now in
            DiagnosticEvidenceRecorder(store: store, now: now)
        },
        makeState: @escaping @MainActor (DiagnosticEvidenceRecorder, Bool, AppConfig, Bool) -> AppState = { recorder, pipelineEnabled, config, setupEnabled in
            AppState(
                config: config,
                nativeSetupEnabled: setupEnabled,
                automaticObservationPipelineEnabled: pipelineEnabled,
                recorder: recorder
            )
        },
        registerSharedState: @escaping @MainActor (AppState) -> Void = { AppState.shared = $0 },
        makeUpdateController: @escaping @MainActor (AppState) -> UpdateController = { appState in
            let updateAnnouncer = UpdateNotificationAnnouncer()
            return UpdateController(
                log: Logger.setup,
                errorDomain: "app.solstone.observer.updates",
                exclusivity: { appState.journalHandoffActive },
                preInstallFinalizer: { @MainActor in
                    await appState.appQuitCoordinator.prepareForUpdaterInstall()
                },
                installFailureRecovery: { @MainActor in
                    await appState.recoverAfterFailedUpdaterInstall()
                },
                terminationBegan: { @MainActor in
                    appState.appKitTerminationBegan
                },
                announce: { version in
                    updateAnnouncer.announce(version: version)
                }
            )
        },
        registerUpdateAnnouncement: @escaping @MainActor (UpdateController) -> Void = {
            UpdateAnnouncementLaunchRegistry.register($0)
        },
        makeStartup: @escaping @MainActor (AppState, UpdateController) -> Startup
    ) -> Startup? {
        let result: Startup?? = SolstoneStartupPlanner.planStartup(
            decision: decision,
            coordinator: repairCoordinator
        ) {
            let config: AppConfig
            while true {
                do {
                    config = try loadConfiguration(nativeSetupEnabled)
                    break
                } catch {
                    Logger.setup.error("Configuration initialization failed: \(error.localizedDescription, privacy: .private)")
                    if onConfigurationFailure(error) == .quit {
                        markExpectedExit(ExitReason.ordinaryQuit.markerString)
                        terminateBeforeStartup()
                        return nil
                    }
                }
            }
            let store = makeEvidenceStore(evidenceNow)
            let recorder = makeRecorder(store, evidenceNow)
            let appState = makeState(recorder, automaticObservationPipelineEnabled, config, nativeSetupEnabled)
            registerSharedState(appState)
            recorder.enqueue(.appLaunch)
            let updateController = makeUpdateController(appState)
            registerUpdateAnnouncement(updateController)
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            appState.safariExtensionHealth.start()
            appState.startBrowserIntake(updateController: updateController)
#endif
            if automaticObservationPipelineEnabled {
                appState.capture.activate()
            }
            return makeStartup(appState, updateController)
        }
        return result.flatMap { $0 }
    }
}
