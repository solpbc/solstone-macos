// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Re-link feedback")
struct RelinkFeedbackTests {
    @Test func everySameMachineEndingSaysWhatHappenedAndKeepsItsOwnCode() {
        let endings: [(SameMachineHomePairingResult, String?, DiagnosticEvidenceCode)] = [
            (.pairingStarted, nil, .pairingSameMachinePaired),
            (.notEligible, UICopy.SAME_MACHINE_LINK_ALREADY_LINKED, .pairingSameMachineAlreadyLinked),
            (.failed(.pairStart(.transport)), UICopy.SAME_MACHINE_LINK_UNREACHABLE, .pairingSameMachineUnreachable),
            (.failed(.pairStart(.httpStatus(503))), UICopy.SAME_MACHINE_LINK_UNREACHABLE, .pairingSameMachineUnreachable),
            (.failed(.pairStart(.httpStatus(403))), UICopy.SAME_MACHINE_LINK_REFUSED, .pairingSameMachineRefused),
            (.failed(.pairStart(.httpStatus(500))), UICopy.SAME_MACHINE_LINK_UNEXPECTED, .pairingSameMachineUnexpectedAnswer),
            (.failed(.pairStart(.decode)), UICopy.SAME_MACHINE_LINK_UNEXPECTED, .pairingSameMachineUnexpectedAnswer),
            (.failed(.linkShape(.lanCandidate)), UICopy.SAME_MACHINE_LINK_UNEXPECTED, .pairingSameMachineUnexpectedAnswer),
            (.failed(.ceremony(.failed(.staleLink))), PairingFailure.staleLink.message(address: nil), .pairingSameMachineCeremonyFailed),
            (.failed(.ceremony(.saveFailed)), UICopy.PAIRING_SAVE_FAILED, .pairingSameMachineSaveFailed),
            (.failed(.ceremony(.idle)), UICopy.SAME_MACHINE_LINK_UNFINISHED, .pairingSameMachineCeremonyFailed),
            (.failed(.pairingUnavailable), UICopy.SAME_MACHINE_LINK_CREDENTIALS_UNAVAILABLE, .pairingSameMachineCredentialsUnavailable),
            (.failed(.differentHomeAlreadyPaired), UICopy.SAME_MACHINE_LINK_OTHER_JOURNAL, .pairingSameMachineOtherJournalPaired),
        ]

        for (result, message, evidence) in endings {
            let outcome = sameMachineLinkOutcome(for: result, failedAddress: nil)
            #expect(outcome.message == message, "\(result)")
            #expect(outcome.evidence == evidence, "\(result)")
        }
    }

    @Test func alreadyLinkedIsANoticeAndNotASilentSuccess() {
        let outcome = sameMachineLinkOutcome(for: .notEligible, failedAddress: nil)

        #expect(outcome.tone == .notice)
        #expect(outcome.message != nil)
    }

    @Test func aCredentialFailureOnThisMacIsNotReportedAsTheJournalBeingUnreachable() {
        let credentials = sameMachineLinkOutcome(for: .failed(.pairingUnavailable), failedAddress: nil)
        let unreachable = sameMachineLinkOutcome(for: .failed(.pairStart(.transport)), failedAddress: nil)

        #expect(credentials.message != unreachable.message)
        #expect(credentials.tone == .error)
        #expect(!credentials.offersPairingLink)
    }

    @Test func onlyAJournalThatAnsweredButWouldNotLinkOffersAPastedLink() {
        // A link that landed, or a Mac already linked, has everything it needs: the paste
        // field stays closed.
        #expect(!sameMachineLinkOutcome(for: .pairingStarted, failedAddress: nil).offersPairingLink)
        #expect(!sameMachineLinkOutcome(for: .notEligible, failedAddress: nil).offersPairingLink)
        #expect(sameMachineLinkOutcome(for: .failed(.pairStart(.httpStatus(403))), failedAddress: nil).offersPairingLink)
        #expect(sameMachineLinkOutcome(for: .failed(.pairStart(.decode)), failedAddress: nil).offersPairingLink)
        #expect(!sameMachineLinkOutcome(for: .failed(.pairStart(.transport)), failedAddress: nil).offersPairingLink)
        #expect(!sameMachineLinkOutcome(for: .failed(.ceremony(.saveFailed)), failedAddress: nil).offersPairingLink)
    }

    @Test func aPastedLinkKeepsACodeOnlyOnceItHasEnded() {
        #expect(pairingLinkEvidence(for: .paired) == .pairingLinkPaired)
        #expect(pairingLinkEvidence(for: .alreadyConnected) == .pairingLinkPaired)
        #expect(pairingLinkEvidence(for: .switched) == .pairingLinkPaired)
        #expect(pairingLinkEvidence(for: .failed(.network)) == .pairingLinkFailed)
        #expect(pairingLinkEvidence(for: .saveFailed) == .pairingLinkSaveFailed)
        #expect(pairingLinkEvidence(for: .switchConfirmPending) == nil)
        #expect(pairingLinkEvidence(for: .pairing) == nil)
    }

    @Test func relinkNamesWhereThisMacIsSetToSendByHostAndPortOnly() {
        #expect(journalAddressForOwner("http://localhost:5016") == "localhost:5016")
        #expect(journalAddressForOwner("https://journal.example/base?key=secret") == "journal.example")
        #expect(journalAddressForOwner(nil) == nil)
        #expect(journalAddressForOwner("not a url") == nil)

        #expect(UICopy.relinkNeedsPairingLink(address: "localhost:5016").contains("localhost:5016"))
        #expect(UICopy.relinkNeedsPairingLink(address: nil).contains("pairing link"))
    }

    @Test func copiedDiagnosticsLeadWithWhenTheyWereRead() {
        func report(at seconds: TimeInterval) -> DiagnosticReport {
            buildDiagnosticReport(DiagnosticReportInput(
                appVersion: "1.2.3",
                screenRecording: .granted,
                microphone: .granted,
                isRecording: true,
                isPaused: false,
                hasError: false,
                lastDelivery: .noDeliveryYet,
                lastJournalContact: .noSyncYet,
                evidence: .unavailable,
                ingestReason: nil,
                ingestRoute: nil,
                now: Date(timeIntervalSince1970: seconds)
            ))
        }

        let first = report(at: 1_000)
        let second = report(at: 1_060)

        #expect(first.text.hasPrefix("\(UICopy.SETTINGS_DIAGNOSTICS_CHECKED_AT): 1970-01-01T00:16:40.000Z\n"))
        #expect(first.text != second.text)
    }
}
