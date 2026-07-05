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
