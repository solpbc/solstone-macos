// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("SetupPairingLinkOffer")
struct SetupPairingLinkOfferTests {
    @Test func olderSetupOffersPairingOnEveryStep() {
        for phase in SetupPhase.allCases {
            #expect(SetupPairingLinkOffer.isVisible(phase: phase, isPeerSupportingSetup: false, hasPendingPairing: false, setupWindowPairingSucceeded: false))
        }
    }

    @Test func nativeSequenceOffersPairingOnlyOnItsFirstStep() {
        #expect(SetupPairingLinkOffer.isVisible(phase: .journal, isPeerSupportingSetup: true, hasPendingPairing: false, setupWindowPairingSucceeded: false))
        for phase in [SetupPhase.microphone, .screen, .connection] {
            #expect(!SetupPairingLinkOffer.isVisible(phase: phase, isPeerSupportingSetup: true, hasPendingPairing: false, setupWindowPairingSucceeded: false))
        }
    }

    @Test func aWaitingPairingLinkIsAlwaysShown() {
        for phase in SetupPhase.allCases {
            #expect(SetupPairingLinkOffer.isVisible(phase: phase, isPeerSupportingSetup: true, hasPendingPairing: true, setupWindowPairingSucceeded: false))
        }
    }

    @Test func successfulPairingHidesOfferOnLaterPhasesWhenNoLinkPending() {
        for phase in [SetupPhase.microphone, .screen, .connection] {
            #expect(!SetupPairingLinkOffer.isVisible(phase: phase, isPeerSupportingSetup: false, hasPendingPairing: false, setupWindowPairingSucceeded: true))
        }
        #expect(SetupPairingLinkOffer.isVisible(phase: .journal, isPeerSupportingSetup: false, hasPendingPairing: false, setupWindowPairingSucceeded: true))
    }

    @Test func waitingLinkStaysVisibleOnEveryPhaseEvenAfterSuccessfulPairing() {
        for phase in SetupPhase.allCases {
            #expect(SetupPairingLinkOffer.isVisible(phase: phase, isPeerSupportingSetup: false, hasPendingPairing: true, setupWindowPairingSucceeded: true))
        }
    }

    @Test func clearsSetupLinkPredicate() {
        #expect(SetupPairingLinkOffer.clearsSetupLink(on: .paired))
        #expect(SetupPairingLinkOffer.clearsSetupLink(on: .alreadyConnected))
        #expect(SetupPairingLinkOffer.clearsSetupLink(on: .switched))

        #expect(!SetupPairingLinkOffer.clearsSetupLink(on: .idle))
        #expect(!SetupPairingLinkOffer.clearsSetupLink(on: .pairing))
        #expect(!SetupPairingLinkOffer.clearsSetupLink(on: .switchConfirmPending))
        #expect(!SetupPairingLinkOffer.clearsSetupLink(on: .saveFailed))
        #expect(!SetupPairingLinkOffer.clearsSetupLink(on: .failed(.localSetup)))
    }
}
