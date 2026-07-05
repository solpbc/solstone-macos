// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("Updates WireUp")
struct UpdatesWireUpTests {
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
}
