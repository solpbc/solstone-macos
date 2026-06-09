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

    @Test func appUpdateControllerFinalizerStopsRecordingBeforeJournalAndWiresRecovery() throws {
        let source = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let stopRecording = try #require(source.range(of: "await appState.stopRecording()"))
        let stopJournal = try #require(source.range(of: "await appState.stopSupervisedJournalForUpdate()"))

        #expect(stopRecording.lowerBound < stopJournal.lowerBound)
        #expect(wireUpContains(source, """
            installFailureRecovery: { @MainActor in
                await appState.reestablishSupervisedJournalAfterFailedUpdate()
            }
        """))
    }
}
