import Foundation
import JournalMarkKit
import os

extension JournalMarkConfirmationDriver {
    func confirm(appState: AppState) {
        guard !appState.setupModel.isPeerSupportingSetup else { return }
        guard case .valid(let mark) = phase,
              appState.recordJournalMarkConfirmed(
                mark: mark,
                expectedRevision: appState.currentJournalMarkAttemptRevision
              ) else { return }
        complete()
    }

    /// Continuing after a check that could not finish is the owner's answer too.
    func continueAnyway(appState: AppState) {
        guard !appState.setupModel.isPeerSupportingSetup else { return }
        guard case .unverified = phase,
              appState.recordJournalMarkConfirmed(
                expectedRevision: appState.currentJournalMarkAttemptRevision
              ) else { return }
        continueAnyway()
    }

    /// Asks again for a pairing whose question is still open, such as one left unanswered
    /// when the app quit or settings closed. The pairing sends nothing until it is answered.
    func startIfUnconfirmed(appState: AppState) {
        guard !appState.setupModel.isPeerSupportingSetup else { return }
        guard !isPresented,
              appState.needsJournalMarkConfirmation,
              let journal = appState.tunnelLifecycleOwner.cachedJournalMarkIdentity else {
            return
        }
        startIfNeeded(for: "unconfirmed:\(journal)", deriveMark: { await appState.markForAnswer() })
    }

    func reaskUnconfirmed(journal: String, deriveMark: @escaping MarkDeriver) {
        guard !isPresented else { return }
        resetForNewPairAttempt()
        startIfNeeded(for: "unconfirmed:\(journal)", deriveMark: deriveMark)
    }

    func reaskUnconfirmed(appState: AppState) {
        guard let journal = appState.needsJournalMarkConfirmation
            ? appState.tunnelLifecycleOwner.cachedJournalMarkIdentity
            : nil else { return }
        reaskUnconfirmed(journal: journal, deriveMark: { await appState.markForAnswer() })
    }

    func cancelPairing(appState: AppState) async -> Bool {
        await cancelPairing(
            clearConfirmedMark: {
                appState.clearConfirmedMark()
            },
            unpair: {
                await appState.pairingCoordinator.unpair()
            }
        )
    }

    func reject(appState: AppState, onMismatch: @MainActor () -> Void) async -> Bool {
        await reject(
            clearConfirmedMark: {
                appState.clearConfirmedMark()
            },
            unpair: {
                await appState.pairingCoordinator.unpair()
            },
            onMismatch: onMismatch
        )
    }

    func startIfNeeded(for state: PairingFlowState, appState: AppState) {
        guard !appState.setupModel.isPeerSupportingSetup else { return }
        // The automatic same-machine adoption re-uses this ceremony to take over a journal the
        // owner already had linked on this Mac. It runs automatically during launch, so leaving the mark
        // question in place means an owner who merely took an update is asked to make a security
        // decision they never started, with settings stuck behind the sheet until they do.
        guard !appState.isAdoptingSameMachineHomeAutomatically else {
            if Self.successKey(for: state) != nil {
                appState.recordDiagnosticEvidence(.pairingMarkSkippedForAdoption)
            }
            Logger.journalMark.info("journal-mark skipped: automatic same-machine adoption of an already-linked journal")
            return
        }
        // Settings' link to the journal on this Mac verifies over the tunnel instead: there is
        // nothing independent to compare. This keys on the ceremony that path ran, never on what a
        // pairing looks like, so a pasted link to a loopback address still asks.
        guard !appState.pairingCoordinator.lastSubmissionWasSameComputer else {
            Logger.journalMark.info("journal-mark skipped: same-computer link verifies over the tunnel")
            return
        }
        startIfNeeded(for: state, deriveMark: { await appState.markForAnswer() })
    }

    func startIfNeeded(for state: PairingFlowState, deriveMark: @escaping MarkDeriver) {
        guard let successKey = Self.successKey(for: state) else { return }
        startIfNeeded(for: successKey, deriveMark: deriveMark)
    }

    private static func successKey(for state: PairingFlowState) -> String? {
        switch state {
        case .paired:
            return "paired"
        case .switched:
            return "switched"
        case .idle, .pairing, .switchConfirmPending, .alreadyConnected, .saveFailed, .failed:
            return nil
        }
    }
}
