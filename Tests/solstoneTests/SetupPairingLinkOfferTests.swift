// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("SetupPairingLinkOffer")
struct SetupPairingLinkOfferTests {
    @Test func olderSetupOffersPairingOnEveryStep() {
        for phase in SetupPhase.allCases {
            #expect(SetupPairingLinkOffer.isVisible(phase: phase, isPeerSupportingSetup: false, hasPendingPairing: false))
        }
    }

    @Test func nativeSequenceOffersPairingOnlyOnItsFirstStep() {
        #expect(SetupPairingLinkOffer.isVisible(phase: .journal, isPeerSupportingSetup: true, hasPendingPairing: false))
        for phase in [SetupPhase.microphone, .screen, .connection] {
            #expect(!SetupPairingLinkOffer.isVisible(phase: phase, isPeerSupportingSetup: true, hasPendingPairing: false))
        }
    }

    @Test func aWaitingPairingLinkIsAlwaysShown() {
        for phase in SetupPhase.allCases {
            #expect(SetupPairingLinkOffer.isVisible(phase: phase, isPeerSupportingSetup: true, hasPendingPairing: true))
        }
    }
}
