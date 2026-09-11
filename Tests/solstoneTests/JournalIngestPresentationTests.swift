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
