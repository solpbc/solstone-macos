// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Journal ingest presentation")
struct JournalIngestPresentationTests {
    @Test func connectedHttp404OverlaysNotServing() {
        let presented = overlayIngestOnConnectionVerdict(
            tunnel: connectedTunnel,
            pairingMismatch: false,
            healthReason: .httpStatus(404)
        )
        #expect(presented.failureCause == .notServing)
        #expect(presented.axToken == PairingConnectionAXState.notServing.axToken)
    }

    @Test func connectedHttp403OverlaysRevoked() {
        let presented = overlayIngestOnConnectionVerdict(
            tunnel: connectedTunnel,
            pairingMismatch: false,
            healthReason: .httpStatus(403)
        )
        #expect(presented.failureCause == .revoked)
        #expect(presented.axToken == PairingConnectionAXState.revoked.axToken)
    }

    @Test func connectedUrlErrorOverlaysUnreachable() {
        let presented = overlayIngestOnConnectionVerdict(
            tunnel: connectedTunnel,
            pairingMismatch: false,
            healthReason: .urlErrorCode(URLError.timedOut.rawValue)
        )
        #expect(presented.failureCause == .unreachable(nil))
        #expect(presented.axToken == PairingConnectionAXState.unreachable.axToken)
    }

    @Test func connected404403AndUrlErrorAreThreeDistinctTokens() {
        let tokens = [
            overlayIngestOnConnectionVerdict(
                tunnel: connectedTunnel,
                pairingMismatch: false,
                healthReason: .urlErrorCode(-1009)
            ).axToken,
            overlayIngestOnConnectionVerdict(
                tunnel: connectedTunnel,
                pairingMismatch: false,
                healthReason: .httpStatus(403)
            ).axToken,
            overlayIngestOnConnectionVerdict(
                tunnel: connectedTunnel,
                pairingMismatch: false,
                healthReason: .httpStatus(404)
            ).axToken,
        ]
        #expect(Set(tokens) == [
            PairingConnectionAXState.unreachable.axToken,
            PairingConnectionAXState.revoked.axToken,
            PairingConnectionAXState.notServing.axToken,
        ])
        #expect(Set(tokens).count == 3)
    }

    @Test func connectedOtherHealthReasonDoesNotOverlay() {
        for reason: ObserverHealthFailureReason in [
            .httpStatus(503),
            .uploadFailed,
            .uploadInvalidResponse,
            .configChanged,
        ] {
            let presented = overlayIngestOnConnectionVerdict(
                tunnel: connectedTunnel,
                pairingMismatch: false,
                healthReason: reason
            )
            #expect(presented.axToken == PairingConnectionAXState.connected.axToken)
            #expect(presented.failureCause == nil)
        }
    }

    @Test func pairingMismatchWinsOverHttp404() {
        let presented = overlayIngestOnConnectionVerdict(
            tunnel: connectedTunnel,
            pairingMismatch: true,
            healthReason: .httpStatus(404)
        )
        #expect(presented.failureCause == .mismatch)
        #expect(presented.axToken == PairingConnectionAXState.mismatch.axToken)
    }

    @Test func doesNotOverlayWhenTunnelNotConnected() {
        let connecting = JournalConnectionVerdict(
            severity: .warn,
            message: "connecting",
            caption: nil,
            axToken: PairingConnectionAXState.connecting.axToken,
            failureCause: nil
        )
        let unreachable = JournalConnectionVerdict(
            severity: .attention,
            message: "unreachable",
            caption: nil,
            axToken: PairingConnectionAXState.unreachable.axToken,
            failureCause: .unreachable(nil)
        )
        let disconnected = JournalConnectionVerdict.neutral
        for tunnel in [connecting, unreachable, disconnected] {
            let presented = overlayIngestOnConnectionVerdict(
                tunnel: tunnel,
                pairingMismatch: false,
                healthReason: .httpStatus(404)
            )
            #expect(presented.axToken == tunnel.axToken)
            #expect(presented.failureCause == tunnel.failureCause)
        }
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
