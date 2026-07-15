// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import Observation
import SolstoneCore

enum FreshJournalState: Equatable, Sendable {
    case idle
    case acquiring(AcquirePhase)
    case launching
    case waitingForJournal
    case failed(JournalHandoffFailure)
}

extension FreshJournalState {
    var ownerStatusMessage: String {
        switch self {
        case .idle:
            return ""
        case .acquiring(let phase):
            return JournalHandoffStep.acquiring(phase).ownerStatusMessage
        case .launching:
            return JournalHandoffStep.launchingJournal.ownerStatusMessage
        case .waitingForJournal:
            return "finish setting up in the journal app — your journal will appear here when it's ready"
        case .failed(let failure):
            return failure.ownerMessage
        }
    }

    var isBusy: Bool {
        switch self {
        case .acquiring, .launching, .waitingForJournal:
            return true
        case .idle, .failed:
            return false
        }
    }

    var axState: FreshJournalAXState {
        switch self {
        case .idle:
            return .idle
        case .acquiring:
            return .acquiring
        case .launching:
            return .launching
        case .waitingForJournal:
            return .waitingForJournal
        case .failed:
            return .failed
        }
    }
}

struct FreshJournalFlowDependencies {
    var acquirer: JournalAppAcquirer
    var runningJournal: any RunningJournalController
    var trustVerifier: any TrustVerifier
    var fetchIdentity: @MainActor @Sendable (String) async -> JournalMark?
    var waitingPollInterval: Duration
    var sleep: @MainActor @Sendable (Duration) async throws -> Void

    @MainActor
    static func live(defaults: UserDefaults = .standard) -> FreshJournalFlowDependencies {
        let trustVerifier = LiveTrustVerifier()
        return FreshJournalFlowDependencies(
            acquirer: .live(defaults: defaults, trustVerifier: trustVerifier),
            runningJournal: LiveRunningJournalController(),
            trustVerifier: trustVerifier,
            fetchIdentity: { baseURL in
                await JournalIdentityFetcher().fetch(baseURL: baseURL)
            },
            waitingPollInterval: .seconds(3),
            sleep: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }
}

@MainActor
@Observable
final class FreshJournalFlow {
    private(set) var state: FreshJournalState = .idle
    private(set) var discoveredJournalMark: JournalMark?

    @ObservationIgnored
    private var task: Task<Void, Never>?
    @ObservationIgnored
    private var waitingProbeTask: Task<Void, Never>?
    @ObservationIgnored
    private let dependencies: FreshJournalFlowDependencies

    init(dependencies: FreshJournalFlowDependencies = .live()) {
        self.dependencies = dependencies
    }

    func start() {
        guard task == nil else { return }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
            }
            await self.runStart()
        }
    }

    func armWaitingProbe() {
        guard state == .waitingForJournal,
              waitingProbeTask == nil,
              discoveredJournalMark == nil
        else {
            return
        }

        waitingProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.waitingProbeTask = nil
            }

            while !Task.isCancelled {
                let result = await discoverLocalJournal(fetchIdentity: self.dependencies.fetchIdentity)
                guard !Task.isCancelled else { return }
                if case .found(let mark) = result {
                    self.discoveredJournalMark = mark
                    return
                }

                do {
                    try await self.dependencies.sleep(self.dependencies.waitingPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    func cancelWaitingProbe() {
        waitingProbeTask?.cancel()
        waitingProbeTask = nil
    }

    private func runStart() async {
        cancelWaitingProbe()
        discoveredJournalMark = nil

        do {
            let trustedURL: URL
            if let installed = dependencies.runningJournal.installedURL(),
               (try? await dependencies.trustVerifier.verifyJournalApp(at: installed)) != nil {
                trustedURL = installed
            } else {
                trustedURL = try await dependencies.acquirer.acquire { phase in
                    self.state = .acquiring(phase)
                }
            }

            state = .launching
            try dependencies.runningJournal.launchJournalActivating(at: trustedURL)
            state = .waitingForJournal
        } catch is CancellationError {
            state = .idle
        } catch let failure as JournalHandoffFailure {
            state = .failed(failure)
        } catch {
            state = .failed(.appcastUnavailable(String(describing: error)))
        }
    }
}
