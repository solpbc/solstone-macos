// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Setup snapshot builder")
struct SetupSnapshotBuilderTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func allRequiredRowsReadyProducesReadyVerdict() {
        let presentation = buildSetupSnapshot(input())

        #expect(presentation.verdict == .ready)
        #expect(states(in: presentation)[.solApp] == .ready)
        #expect(states(in: presentation)[.journalLink] == .ready)
        #expect(states(in: presentation)[.journalApp] == .ready)
        #expect(states(in: presentation)[.commandLineTools] == .ready)
        #expect(states(in: presentation)[.screenRecording] == .ready)
        #expect(states(in: presentation)[.microphone] == .ready)
    }

    @Test func missingRequiredRowsCountAttentionRowsOnly() {
        let presentation = buildSetupSnapshot(input(
            solAppPlacement: .needsAttention,
            serviceIsDone: false,
            screenRecording: .notGranted
        ))

        #expect(presentation.verdict == .needsAttention(count: 3))
        #expect(row(.lastSync, in: presentation).votes == false)
    }

    @Test func unavailableRequiredRowTakesPrecedenceOverMissingRows() {
        let presentation = buildSetupSnapshot(input(
            journalAppInstalled: .unavailable,
            microphone: .notGranted
        ))

        #expect(presentation.verdict == .someUnavailable)
        #expect(states(in: presentation)[.journalApp] == .unavailable)
        #expect(states(in: presentation)[.microphone] == .needsAttention)
        #expect(row(.microphone, in: presentation).action == .grantPermission)
    }

    @Test func checkingRequiredRowFailsClosedUnavailable() {
        let presentation = buildSetupSnapshot(input(screenRecording: .checking))

        #expect(presentation.verdict == .someUnavailable)
        #expect(states(in: presentation)[.screenRecording] == .checking)
    }

    @Test func remoteTopologyMakesLocalArtifactsNonVoting() {
        let presentation = buildSetupSnapshot(input(
            topology: .remote,
            journalAppInstalled: .needsAttention,
            solWrapperExecutable: .needsAttention,
            journalWrapperExecutable: .needsAttention
        ))

        #expect(presentation.verdict == .ready)
        #expect(states(in: presentation)[.journalApp] == .notRequired)
        #expect(states(in: presentation)[.commandLineTools] == .notRequired)
        #expect(row(.journalApp, in: presentation).votes == false)
        #expect(row(.commandLineTools, in: presentation).votes == false)
    }

    @Test func lastSyncNeverVotesAndUsesCoarseFormatter() {
        let synced = now.addingTimeInterval(-120)
        let presentation = buildSetupSnapshot(input(
            lastSyncOutcome: .synced(synced)
        ))

        #expect(presentation.verdict == .ready)
        #expect(row(.lastSync, in: presentation).value == "2m ago")
        #expect(row(.lastSync, in: presentation).votes == false)

        let never = buildSetupSnapshot(input(lastSyncOutcome: .noSyncYet))
        #expect(never.verdict == .ready)
        #expect(row(.lastSync, in: never).value == UICopy.SETTINGS_SETUP_LAST_SYNC_NEVER)
    }

    private func input(
        topology: SetupTopology = .local,
        solAppPlacement: SetupProbeOutcome = .ready,
        journalAppInstalled: SetupProbeOutcome = .ready,
        serviceIsDone: Bool = true,
        solWrapperExecutable: SetupProbeOutcome = .ready,
        journalWrapperExecutable: SetupProbeOutcome = .ready,
        screenRecording: PermissionOutcome = .granted,
        microphone: PermissionOutcome = .granted,
        lastSyncOutcome: SetupLastSyncOutcome = .noSyncYet
    ) -> SetupSnapshotInput {
        SetupSnapshotInput(
            topology: topology,
            solAppPlacement: solAppPlacement,
            journalAppInstalled: journalAppInstalled,
            serviceIsDone: serviceIsDone,
            solWrapperExecutable: solWrapperExecutable,
            journalWrapperExecutable: journalWrapperExecutable,
            screenRecording: screenRecording,
            microphone: microphone,
            lastSyncOutcome: lastSyncOutcome,
            now: now
        )
    }

    private func states(in presentation: SetupSnapshotPresentation) -> [SetupCheckRowID: SetupCheckRowAXState] {
        Dictionary(uniqueKeysWithValues: presentation.rows.map { ($0.id, $0.state) })
    }

    private func row(_ id: SetupCheckRowID, in presentation: SetupSnapshotPresentation) -> SetupCheckRow {
        presentation.rows.first { $0.id == id }!
    }
}
