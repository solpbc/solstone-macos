// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Testing
import UpdateKit
import SolstoneCore
@testable import solstone

@MainActor
@Suite("Held idle presentation")
struct HeldIdlePresentationTests {
    @Test func heldIdleUsesPausedPresentationWithoutChangingPermissionFlags() throws {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let held = pairedState(permissionsGranted: true)
        held.pauseManager.pause(for: .indefinite)
        let baseline = pairedState(permissionsGranted: true)

        #expect(held.ownerPauseHeldIdle)
        #expect(held.observationRowState == .paused)
        let updateController = UpdateController(
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: isolated.defaults
        )
        #expect(MenuContent(appState: held, updateController: updateController).hasPauseResumeControl)
        #expect(held.captureSourcesStatusText == UICopy.sourceStatus(held.availableSelectedSources, isPaused: true))
        let summary = healthSummary(for: held)
        #expect(summary.axValue == "paused")
        #expect(summary.title == "solstone is paused")
        #expect(held.permissionsAreDone == baseline.permissionsAreDone)
        #expect(held.permissionsNeedAttention == baseline.permissionsNeedAttention)

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let browserSummary = healthSummaryIncludingBrowser(for: held)
        #expect(browserSummary.axValue == "paused")
        #expect(browserSummary.title == "solstone is paused")
#endif

        let settingsSource = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let summaryStart = try #require(settingsSource.range(of: "    private var statusHealthSummary: StatusHealthSummary {"))
        let summaryEnd = try #require(settingsSource[summaryStart.lowerBound...].range(of: "    @ViewBuilder\n    private func healthSummaryCard"))
        let summarySource = String(settingsSource[summaryStart.lowerBound..<summaryEnd.lowerBound])
        #expect(wireUpContains(summarySource, "ownerPauseHeldIdle: appState.ownerPauseHeldIdle"))
    }

    @Test func permissionsKeepPrecedenceOverHeldIdlePause() {
        let held = pairedState(permissionsGranted: false)
        held.pauseManager.pause(for: .indefinite)
        let baseline = pairedState(permissionsGranted: false)

        #expect(held.observationRowState == .permissions)
        #expect(held.permissionsNeedAttention)
        #expect(held.captureSourcesStatusText == UICopy.SOURCES_NONE_GRANTED)
        let summary = healthSummary(for: held)
        #expect(summary.axValue == "sources_unavailable")
        #expect(summary.title == UICopy.SOURCES_NONE_GRANTED)
        #expect(held.permissionsAreDone == baseline.permissionsAreDone)
        #expect(held.permissionsNeedAttention == baseline.permissionsNeedAttention)

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let browserSummary = healthSummaryIncludingBrowser(for: held)
        #expect(browserSummary.axValue == "sources_unavailable")
        #expect(browserSummary.title == UICopy.SOURCES_NONE_GRANTED)
#endif
    }

    @Test func absentPairingStillLeadsHeldIdleHealthSummary() {
        let state = AppState.forSnapshot(config: AppConfig(isBrowserIntakeEnabled: false))
        state.capture.publishScreenRecordingPermission(.granted)
        state.microphoneAuthorizationCause = .authorized
        state.initialPermissionCheckComplete = true
        state.pauseManager.pause(for: .indefinite)

        #expect(healthSummary(for: state).axValue == "external_not_linked")
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        #expect(healthSummaryIncludingBrowser(for: state).axValue == "external_not_linked")
#endif
    }

    @Test func diagnosticCaptureStateRecognizesHeldIdleAndErrorWins() throws {
        #expect(diagnosticCaptureAXState(
            isRecording: false,
            isPaused: false,
            ownerPauseHeldIdle: true,
            hasError: false
        ) == .paused)
        #expect(diagnosticCaptureAXState(
            isRecording: false,
            isPaused: false,
            ownerPauseHeldIdle: true,
            hasError: true
        ) == .error)

        let settingsSource = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let reportStart = try #require(settingsSource.range(of: "    private func openProblemReport(aboutSnapshot: String) {"))
        let reportEnd = try #require(settingsSource[reportStart.lowerBound...].range(of: "    private var currentScreenPermissionOutcome"))
        let reportSource = String(settingsSource[reportStart.lowerBound..<reportEnd.lowerBound])
        #expect(wireUpContains(reportSource, "appState.isPaused || appState.ownerPauseHeldIdle"))
        #expect(wireUpContains(reportSource, "appState.errorMessage != nil ? \"error\""))
    }

    private func pairedState(permissionsGranted: Bool) -> AppState {
        let state = AppState.forSnapshot(
            config: AppConfig(isBrowserIntakeEnabled: false),
            initialTunnelPairing: pairing(relayEnrollment: .unavailable)
        )
        state.initialPermissionCheckComplete = true
        if permissionsGranted {
            state.capture.publishScreenRecordingPermission(.granted)
            state.microphoneAuthorizationCause = .authorized
        } else {
            state.capture.publishScreenRecordingPermission(.notGranted)
            state.microphoneAuthorizationCause = .denied
        }
        return state
    }

    private func healthSummary(for state: AppState) -> StatusHealthSummary {
        StatusHealthSummary.make(
            serviceMode: state.config.serviceMode,
            isRecording: state.isRecording,
            isPaused: state.isPaused,
            ownerPauseHeldIdle: state.ownerPauseHeldIdle,
            held: state.needsJournalMarkConfirmation,
            hasPersistedPairing: state.tunnelLifecycleOwner.hasPersistedPairing,
            uploadStatus: state.uploadCoordinator.status,
            pendingCount: state.uploadCoordinator.pendingCount,
            lastDeliveryOutcome: state.uploadCoordinator.lastJournalDeliveryOutcome,
            journalSlot: "your journal",
            now: Date(timeIntervalSince1970: 1_800_000_000),
            selectedSources: state.config.selectedSources,
            permittedSources: state.capture.permittedSources,
            errorMessage: state.errorMessage,
            setupVerdict: nil,
            lastHealthReason: state.uploadCoordinator.lastHealthReason,
            isPairedIngestReady: state.isPairedIngestReady,
            journalConnectionAXToken: state.tunnelLifecycleOwner.connectionVerdict.axToken
        )
    }

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    private func healthSummaryIncludingBrowser(for state: AppState) -> StatusHealthSummary {
        StatusHealthSummary.makeIncludingBrowser(
            serviceMode: state.config.serviceMode,
            isRecording: state.isRecording,
            isPaused: state.isPaused,
            ownerPauseHeldIdle: state.ownerPauseHeldIdle,
            held: state.needsJournalMarkConfirmation,
            hasPersistedPairing: state.tunnelLifecycleOwner.hasPersistedPairing,
            uploadStatus: state.uploadCoordinator.status,
            pendingCount: state.uploadCoordinator.pendingCount,
            lastDeliveryOutcome: state.uploadCoordinator.lastJournalDeliveryOutcome,
            journalSlot: "your journal",
            now: Date(timeIntervalSince1970: 1_800_000_000),
            selectedSources: state.config.selectedSources,
            permittedSources: state.capture.permittedSources,
            errorMessage: state.errorMessage,
            setupVerdict: nil,
            lastHealthReason: state.uploadCoordinator.lastHealthReason,
            isPairedIngestReady: state.isPairedIngestReady,
            journalConnectionAXToken: state.tunnelLifecycleOwner.connectionVerdict.axToken,
            snapshot: state.browserHostSnapshot.value
        )
    }
#endif
}
