// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Journal ingest presentation")
struct JournalIngestPresentationTests {
    @Test func connectionPresentationUsesTransportVerdict() {
        let presented = journalConnectionVerdictPresentation(
            tunnel: connectedTunnel,
            pairingMismatch: false
        )
        #expect(presented == connectedTunnel)
    }

    @Test func pairingMismatchOverridesTransportVerdict() {
        let presented = journalConnectionVerdictPresentation(
            tunnel: connectedTunnel,
            pairingMismatch: true
        )
        #expect(presented.failureCause == .mismatch)
        #expect(presented.axToken == PairingConnectionAXState.mismatch.axToken)
    }

    @Test func notServingRemedyIsOpenJournal() {
        let remedy = journalPanelRemedy(
            failureCause: .notServing,
            axToken: PairingConnectionAXState.notServing.axToken
        )
        #expect(remedy == .openJournal)
        let affordances = journalPanelAffordances(for: remedy)
        #expect(affordances.showOpenJournal)
        #expect(!affordances.showRelink)
        #expect(!affordances.showTunnelRetry)
        #expect(!affordances.showPairingForm)
    }

    @Test func pairingAndTunnelRetryRemedies() {
        #expect(
            journalPanelRemedy(
                failureCause: nil,
                axToken: PairingConnectionAXState.disconnected.axToken
            ) == .pairing
        )
        #expect(
            journalPanelRemedy(
                failureCause: .revoked,
                axToken: PairingConnectionAXState.revoked.axToken
            ) == .pairing
        )
        #expect(
            journalPanelRemedy(
                failureCause: .keychainUnavailable,
                axToken: PairingConnectionAXState.keychainUnavailable.axToken
            ) == .pairing
        )
        #expect(
            journalPanelRemedy(
                failureCause: .noRoute,
                axToken: PairingConnectionAXState.noRoute.axToken
            ) == .tunnelRetry
        )
        #expect(
            journalPanelRemedy(
                failureCause: .unreachable(nil),
                axToken: PairingConnectionAXState.unreachable.axToken
            ) == .tunnelRetry
        )
        #expect(
            journalPanelRemedy(
                failureCause: .loopbackUnavailable,
                axToken: PairingConnectionAXState.loopbackUnavailable.axToken
            ) == .tunnelRetry
        )
        #expect(
            journalPanelRemedy(
                failureCause: .notEntitled,
                axToken: PairingConnectionAXState.notEntitled.axToken
            ) == .none
        )
        #expect(
            journalPanelRemedy(
                failureCause: nil,
                axToken: PairingConnectionAXState.connected.axToken
            ) == .none
        )
    }

    @Test func pausedAndDisconnectedSyncDoNotShowStaleSuccess() {
        #expect(journalSyncStatusText(.synced, paused: true, ready: true, held: false) == "sync paused")
        #expect(journalSyncStatusText(.synced, paused: false, ready: false, held: false) == "waiting for a connection")
        #expect(journalSyncStatusText(.notSynced, paused: false, ready: true, held: false) == "sync hasn't checked yet")
        #expect(journalSyncStatusText(.synced, paused: false, ready: true, held: false) == "sync check complete")
    }

    @Test func activityDoesNotExposeSegmentNamesOrClaimDelivery() {
        #expect(journalSyncStatusText(.uploading(segment: "private-segment"), paused: false, ready: true, held: false) == "syncing to your journal…")
        #expect(journalSyncStatusText(.retrying(segment: "private-segment", attempts: 2), paused: false, ready: true, held: false) == "waiting to retry")
    }

    @Test func heldSyncRowShowsHeldCopyAndHandRaisedIcon() {
        #expect(journalSyncStatusText(.synced, paused: false, ready: false, held: true) == UICopy.JOURNAL_MARK_HELD)
        #expect(journalSyncStatusSymbol(.synced, paused: false, ready: false, held: true) == JournalSyncStatusSymbol(systemName: "hand.raised.circle", usesSecondaryStyle: true))
    }

    @Test func heldPausedSyncRowShowsPausedCopyAndPauseIcon() {
        #expect(journalSyncStatusText(.synced, paused: true, ready: false, held: true) == "sync paused")
        #expect(journalSyncStatusSymbol(.synced, paused: true, ready: false, held: true) == JournalSyncStatusSymbol(systemName: "pause.circle", usesSecondaryStyle: true))
    }

    @Test func disconnectedSyncRowShowsConnectionWaitingAndPauseIcon() {
        #expect(journalSyncStatusText(.synced, paused: false, ready: false, held: false) == "waiting for a connection")
        #expect(journalSyncStatusSymbol(.synced, paused: false, ready: false, held: false) == JournalSyncStatusSymbol(systemName: "pause.circle", usesSecondaryStyle: true))
    }

    private var connectedTunnel: JournalConnectionVerdict {
        JournalConnectionVerdict(
            severity: .good,
            message: "connected",
            caption: nil,
            axToken: PairingConnectionAXState.connected.axToken,
            failureCause: nil
        )
    }
}
