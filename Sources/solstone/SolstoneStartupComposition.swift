// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import UpdateKit

@MainActor
internal enum SolstoneStartupComposition {
    static func makeNormalStartup<Startup>(
        decision: AppPlacementDecision,
        repairCoordinator: AppPlacementRepairCoordinator = .shared,
        automaticObservationPipelineEnabled: Bool,
        evidenceNow: @escaping @Sendable () -> Date = Date.init,
        makeEvidenceStore: @escaping @MainActor (@escaping @Sendable () -> Date) -> DiagnosticEvidenceStore = { now in
            DiagnosticEvidenceStore(now: now)
        },
        makeRecorder: @escaping @MainActor (DiagnosticEvidenceStore, @escaping @Sendable () -> Date) -> DiagnosticEvidenceRecorder = { store, now in
            DiagnosticEvidenceRecorder(store: store, now: now)
        },
        makeState: @escaping @MainActor (DiagnosticEvidenceRecorder, Bool) -> AppState = { recorder, pipelineEnabled in
            AppState(
                automaticObservationPipelineEnabled: pipelineEnabled,
                recorder: recorder
            )
        },
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
                    appState.appQuitCoordinator.resetAfterFailedUpdaterInstall()
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
        SolstoneStartupPlanner.planStartup(
            decision: decision,
            coordinator: repairCoordinator
        ) {
            let store = makeEvidenceStore(evidenceNow)
            let recorder = makeRecorder(store, evidenceNow)
            let appState = makeState(recorder, automaticObservationPipelineEnabled)
            recorder.enqueue(.appLaunch)
            let updateController = makeUpdateController(appState)
            registerUpdateAnnouncement(updateController)
            return makeStartup(appState, updateController)
        }
    }
}
