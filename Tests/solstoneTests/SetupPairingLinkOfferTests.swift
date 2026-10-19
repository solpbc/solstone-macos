// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import JournalMarkKit
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

    @Test func acquiringStatusReturnsOwnerStatusMessageAndDifferentiatesPhases() {
        let fetching = FreshJournalState.acquiring(.fetchingAppcast)
        let downloading = FreshJournalState.acquiring(.downloadingDMG)
        let captionFetching = SetupJournalStatus.caption(
            flowState: fetching,
            journalPollingText: UICopy.SETUP_OPENING_YOUR_JOURNAL
        )
        let captionDownloading = SetupJournalStatus.caption(
            flowState: downloading,
            journalPollingText: UICopy.SETUP_OPENING_YOUR_JOURNAL
        )

        #expect(captionFetching == fetching.ownerStatusMessage)
        #expect(captionDownloading == downloading.ownerStatusMessage)
        #expect(captionFetching != captionDownloading)
    }

    @Test func launchingStatusReturnsOpeningYourJournalAndDiffersFromOwnerStatusMessage() {
        let launching = FreshJournalState.launching
        let caption = SetupJournalStatus.caption(flowState: launching, journalPollingText: nil)

        #expect(caption == UICopy.SETUP_OPENING_YOUR_JOURNAL)
        #expect(caption != launching.ownerStatusMessage)
    }

    @Test func waitingForJournalPassesThroughProvidedPollingText() {
        let stillSettingUp = SetupJournalStatus.caption(
            flowState: .waitingForJournal,
            journalPollingText: UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP
        )
        let opening = SetupJournalStatus.caption(
            flowState: .waitingForJournal,
            journalPollingText: UICopy.SETUP_OPENING_YOUR_JOURNAL
        )

        #expect(stillSettingUp == UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP)
        #expect(opening == UICopy.SETUP_OPENING_YOUR_JOURNAL)
    }

    @Test func journalStepContentDecisions() {
        let omitted = SetupJournalStep.content(
            isOwnerComparison: false,
            isPeerSupporting: false,
            hasMark: false,
            hasError: false,
            hasStatus: false,
            linkWaiting: true
        )
        #expect(omitted == .omitted)
        #expect(omitted != .create)

        let ownerComp = SetupJournalStep.content(
            isOwnerComparison: true,
            isPeerSupporting: false,
            hasMark: false,
            hasError: false,
            hasStatus: false,
            linkWaiting: true
        )
        #expect(ownerComp == .ownerComparison)

        let peerSup = SetupJournalStep.content(
            isOwnerComparison: false,
            isPeerSupporting: true,
            hasMark: false,
            hasError: false,
            hasStatus: false,
            linkWaiting: true
        )
        #expect(peerSup == .peerSupporting)

        let idleCreate = SetupJournalStep.content(
            isOwnerComparison: false,
            isPeerSupporting: false,
            hasMark: false,
            hasError: false,
            hasStatus: false,
            linkWaiting: false
        )
        #expect(idleCreate == .create)

        let failureWins = SetupJournalStep.content(
            isOwnerComparison: false,
            isPeerSupporting: false,
            hasMark: false,
            hasError: true,
            hasStatus: true,
            linkWaiting: false
        )
        #expect(failureWins == .failure)
        #expect(failureWins != .activity)
    }

    @Test func connectionStepContentDecisions() {
        let peerConnected = SetupConnectionStep.content(
            isPeerSupporting: true,
            state: .connected(JournalMark.uiTestSample)
        )
        #expect(peerConnected.headline == UICopy.SETUP_CONNECTED_TO_YOUR_JOURNAL)
        #expect(peerConnected.showsConnectedCaption == false)

        let peerConnecting = SetupConnectionStep.content(
            isPeerSupporting: true,
            state: .connecting
        )
        #expect(peerConnecting.headline == UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL)
        #expect(peerConnecting.showsConnectedCaption == false)

        let peerIdle = SetupConnectionStep.content(
            isPeerSupporting: true,
            state: .idle
        )
        #expect(peerIdle.headline == UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL)
        #expect(peerIdle.showsConnectedCaption == false)

        let peerFailed = SetupConnectionStep.content(
            isPeerSupporting: true,
            state: .failed(UICopy.SETUP_COULDNT_VERIFY_MARK)
        )
        #expect(peerFailed.headline == UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL)
        #expect(peerFailed.showsConnectedCaption == false)

        let olderPeerConnected = SetupConnectionStep.content(
            isPeerSupporting: false,
            state: .connected(JournalMark.uiTestSample)
        )
        #expect(olderPeerConnected.headline == UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL)
        #expect(olderPeerConnected.showsConnectedCaption == false)
    }
}
