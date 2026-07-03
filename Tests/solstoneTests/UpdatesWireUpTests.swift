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
            "AXID.Updates.dismissStaged",
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
        let prepareBody = String(source[prepareStart.lowerBound..<prepareEnd.lowerBound])
        let methodStart = try #require(source.range(of: "internal func performUpdatePreparation() async"))
        let methodEnd = try #require(source[methodStart.upperBound...].range(of: "private func drainRemixQueueForTermination() async"))
        let methodBody = String(source[methodStart.lowerBound..<methodEnd.lowerBound])
        let stopRecording = try #require(methodBody.range(of: "await stopRecording(reason: .update)"))
        let stopJournal = try #require(methodBody.range(of: "await stopSupervisedJournalForUpdate()"))
        let drain = try #require(methodBody.range(of: "await drainRemixQueueForTermination()"))

        #expect(wireUpContains(prepareBody, "await self?.performUpdatePreparation()"))
        #expect(stopRecording.lowerBound < stopJournal.lowerBound)
        #expect(stopJournal.lowerBound < drain.lowerBound)
    }

    @Test func stagedInstallButtonRoutesThroughUpdateController() throws {
        let source = try readWireUpSource("Sources/solstone/UpdatesTabView.swift")
        let functionStart = try #require(source.range(of: "private func relaunchToInstallStagedUpdate()"))
        let functionEnd = try #require(source[functionStart.upperBound...].range(of: "private func titleBlock"))
        let body = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        #expect(wireUpContains(body, "controller.installStagedUpdate()"))
        #expect(!wireUpContains(body, "NSApplication.shared.terminate(nil)"))
    }
}
