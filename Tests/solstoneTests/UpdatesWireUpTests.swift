// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("Updates WireUp")
struct UpdatesWireUpTests {
    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func updatesTabReferencesExpectedAXIDs() throws {
        let source = try readWireUpSource("Sources/solstone/UpdatesTabView.swift")
        let references = [
            "AXID.Updates.statusState",
            "AXID.Updates.unavailable",
            "AXID.Updates.debugStatePicker",
            "AXID.Updates.cancel",
            "AXID.Updates.check",
            "AXID.Updates.download",
            "AXID.Updates.dismiss",
            "AXID.Updates.extractProgress",
            "AXID.Updates.install",
            "AXID.Updates.retry",
            "AXID.Updates.automaticChecks",
            "AXID.Updates.frequencyPicker",
            "AXID.Updates.frequencyState",
            "AXID.Updates.automaticDownloads",
            "AXID.Updates.releaseNotesOnline",
            "AXID.Updates.releaseNotes",
            "AXID.Updates.downloadProgress",
            "AXID.Updates.deferredInstallState"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }

    @Test func appUpdateControllerFinalizerRoutesThroughCoordinatorAndWiresRecovery() throws {
        let source = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")

        #expect(wireUpContains(source, """
            preInstallFinalizer: { @MainActor in
                await appState.appQuitCoordinator.prepareForUpdaterInstall()
            }
        """))
        #expect(wireUpContains(source, """
            installFailureRecovery: { @MainActor in
                appState.appQuitCoordinator.resetAfterFailedUpdaterInstall()
                await appState.reestablishSupervisedJournalAfterFailedUpdate()
            }
        """))
    }

    @Test func appQuitCoordinatorUpdatePreparationStopsRecordingBeforeJournal() throws {
        let source = try readWireUpSource("Sources/solstone/AppState.swift")
        let prepareStart = try #require(source.range(of: "prepareForUpdate: { [weak self] in"))
        let prepareEnd = try #require(source[prepareStart.upperBound...].range(of: "terminate: terminate"))
        let body = String(source[prepareStart.lowerBound..<prepareEnd.lowerBound])
        let stopRecording = try #require(body.range(of: "await self.stopRecording()"))
        let stopJournal = try #require(body.range(of: "await self.stopSupervisedJournalForUpdate()"))

        #expect(stopRecording.lowerBound < stopJournal.lowerBound)
    }
}
