import Foundation
import JournalMarkKit
import os

extension JournalMarkConfirmationDriver {
    func confirm(appState: AppState) {
        guard case .valid = phase else { return }
        confirm { mark in
            appState.setConfirmedMark(mark)
        }
        appState.recordJournalMarkConfirmed()
    }

    /// Continuing after a check that could not finish is the owner's answer too.
    func continueAnyway(appState: AppState) {
        guard case .unverified = phase else { return }
        continueAnyway()
        appState.recordJournalMarkConfirmed()
    }

    /// Asks again for a pairing whose question is still open, such as one left unanswered
    /// when the app quit or settings closed. The pairing sends nothing until it is answered.
    func startIfUnconfirmed(
        appState: AppState,
        fetcher: JournalIdentityFetcher = JournalIdentityFetcher(prepareRequest: { $0.attachLoopbackCapability() })
    ) {
        guard !isPresented,
              appState.needsJournalMarkConfirmation,
              let journal = appState.tunnelLifecycleOwner.cachedJournalMarkIdentity else {
            return
        }
        startIfNeeded(
            for: "unconfirmed:\(journal)",
            resolveHomeBase: unconfirmedHomeBaseResolver(appState),
            fetchMark: unconfirmedMarkFetcher(appState, fetcher)
        )
    }

    func reaskUnconfirmed(
        journal: String,
        resolveHomeBase: @escaping HomeBaseResolver,
        fetchMark: @escaping MarkFetcher
    ) {
        guard !isPresented else { return }
        resetForNewPairAttempt()
        startIfNeeded(
            for: "unconfirmed:\(journal)",
            resolveHomeBase: resolveHomeBase,
            fetchMark: fetchMark
        )
    }

    func reaskUnconfirmed(
        appState: AppState,
        fetcher: JournalIdentityFetcher = JournalIdentityFetcher(prepareRequest: { $0.attachLoopbackCapability() })
    ) {
        guard let journal = appState.needsJournalMarkConfirmation
            ? appState.tunnelLifecycleOwner.cachedJournalMarkIdentity
            : nil else { return }
        reaskUnconfirmed(
            journal: journal,
            resolveHomeBase: unconfirmedHomeBaseResolver(appState),
            fetchMark: unconfirmedMarkFetcher(appState, fetcher)
        )
    }

    private func unconfirmedHomeBaseResolver(_ appState: AppState) -> HomeBaseResolver {
        {
            switch await appState.resolveHomeBase() {
            case .held:
                return .held
            case .url(let baseURL):
                return .url(baseURL)
            }
        }
    }

    private func unconfirmedMarkFetcher(
        _ appState: AppState,
        _ fetcher: JournalIdentityFetcher
    ) -> MarkFetcher {
        { baseURL in
            guard let expected = appState.tunnelLifecycleOwner.storedPairingInstanceID else { return nil }
            guard case .mark(let mark) = await fetcher.fetch(baseURL: baseURL, expectedInstanceID: expected) else {
                return nil
            }
            return mark
        }
    }

    func cancelPairing(appState: AppState) async {
        await cancelPairing(
            clearConfirmedMark: {
                appState.clearConfirmedMark()
            },
            unpair: {
                await appState.pairingCoordinator.unpair()
            }
        )
    }

    func reject(appState: AppState, onMismatch: @MainActor () -> Void) async {
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

    func startIfNeeded(
        for state: PairingFlowState,
        appState: AppState,
        fetcher: JournalIdentityFetcher = JournalIdentityFetcher(prepareRequest: { $0.attachLoopbackCapability() })
    ) {
        // The automatic same-machine adoption re-uses this ceremony to take over a journal the
        // owner already had linked on this Mac. It runs automatically during launch, so leaving the mark
        // question in place means an owner who merely took an update is asked to make a security
        // decision they never started, with settings stuck behind the sheet until they do.
        //
        // ⛔ Only the automatic adoption is exempt. Every owner-initiated pairing still confirms
        // its mark, including a fresh link to a journal on this same Mac — the release gate
        // drives that confirmation and fails `pairing_mark_absent` without it.
        guard !appState.isAdoptingSameMachineHomeAutomatically else {
            Logger.journalMark.info("journal-mark skipped: automatic same-machine adoption of an already-linked journal")
            return
        }
        startIfNeeded(
            for: state,
            resolveHomeBase: {
                await appState.resolveHomeBase()
            },
            fetchMark: { baseURL in
                guard let expected = appState.tunnelLifecycleOwner.storedPairingInstanceID else { return nil }
                guard case .mark(let mark) = await fetcher.fetch(baseURL: baseURL, expectedInstanceID: expected) else {
                    return nil
                }
                return mark
            }
        )
    }

    func startIfNeeded(
        for state: PairingFlowState,
        resolveHomeBase: @escaping @MainActor @Sendable () async -> ResolvedHomeBase,
        fetchMark: @escaping MarkFetcher
    ) {
        guard let successKey = Self.successKey(for: state) else { return }
        startIfNeeded(
            for: successKey,
            resolveHomeBase: {
                switch await resolveHomeBase() {
                case .held:
                    return .held
                case .url(let baseURL):
                    return .url(baseURL)
                }
            },
            fetchMark: fetchMark
        )
    }

    func startIfNeeded(
        for state: PairingFlowState,
        resolveHomeBase: @escaping HomeBaseResolver,
        fetchMark: @escaping MarkFetcher
    ) {
        guard let successKey = Self.successKey(for: state) else { return }
        startIfNeeded(
            for: successKey,
            resolveHomeBase: resolveHomeBase,
            fetchMark: fetchMark
        )
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
