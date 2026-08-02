import Foundation
import JournalMarkKit
import os

extension JournalMarkConfirmationDriver {
    func confirm(appState: AppState) {
        confirm { mark in
            appState.setConfirmedMark(mark)
        }
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
        fetcher: JournalIdentityFetcher = JournalIdentityFetcher(),
        logFallback: @escaping FallbackLogger = { reason in
            Logger.journalMark.info("journal-mark fallback: proceeding without confirmed mark reason=\(reason.rawValue, privacy: .public)")
        }
    ) {
        // Never ask for a mark on a journal running on this same Mac. sol reaches it over a link
        // it has already verified as direct with exactly one loopback candidate, so there is no
        // second home it could be and nothing for the owner to tell apart — the question has one
        // possible answer.
        //
        // Establishing a same-machine link fresh never asked it. The upgrade migration did,
        // because it adopts the existing record by running the pairing ceremony, so upgrading
        // put an unrequested security decision in front of the owner and parked the settings
        // pane behind a modal until they answered it.
        guard !appState.isPairedHome else {
            Logger.journalMark.info("journal-mark skipped: same-machine home needs no mark comparison")
            return
        }
        startIfNeeded(
            for: state,
            resolveHomeBase: {
                await appState.resolveHomeBase()
            },
            fetchMark: { baseURL in
                await fetcher.fetch(baseURL: baseURL)
            },
            logFallback: logFallback
        )
    }

    func startIfNeeded(
        for state: PairingFlowState,
        resolveHomeBase: @escaping @MainActor @Sendable () async -> ResolvedHomeBase,
        fetchMark: @escaping MarkFetcher,
        logFallback: @escaping FallbackLogger = { reason in
            Logger.journalMark.info("journal-mark fallback: proceeding without confirmed mark reason=\(reason.rawValue, privacy: .public)")
        }
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
            fetchMark: fetchMark,
            logFallback: logFallback
        )
    }

    func startIfNeeded(
        for state: PairingFlowState,
        resolveHomeBase: @escaping HomeBaseResolver,
        fetchMark: @escaping MarkFetcher,
        logFallback: @escaping FallbackLogger = { reason in
            Logger.journalMark.info("journal-mark fallback: proceeding without confirmed mark reason=\(reason.rawValue, privacy: .public)")
        }
    ) {
        guard let successKey = Self.successKey(for: state) else { return }
        startIfNeeded(
            for: successKey,
            resolveHomeBase: resolveHomeBase,
            fetchMark: fetchMark,
            logFallback: logFallback
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
