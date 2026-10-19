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
            return "finish setting up in the journal app. your journal will appear here when it's ready"
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

@MainActor
final class InertRunningJournalController: RunningJournalController {
    var installed: URL? = nil
    init(installed: URL? = nil) {
        self.installed = installed
    }
    func installedURL() -> URL? { installed }
    func runningPID() -> pid_t? { nil }
    func terminateRunningJournal() -> Bool { false }
    func launchJournal(at url: URL) throws {}
    func launchJournalActivating(at url: URL) throws {}
}

@MainActor
final class InertTrustVerifier: TrustVerifier {
    func verifyJournalApp(at url: URL) async throws {}
}

@MainActor
struct FreshJournalFlowDependencies {
    var acquirer: JournalAppAcquirer?
    var runningJournal: any RunningJournalController
    var trustVerifier: any TrustVerifier
    var fetchIdentity: @MainActor @Sendable (String) async -> JournalIdentityResolution
    var waitingPollInterval: Duration
    var sleep: @MainActor @Sendable (Duration) async throws -> Void

    @MainActor
    static func live(defaults: UserDefaults = .standard) -> FreshJournalFlowDependencies {
        let trustVerifier = LiveTrustVerifier()
        let runningJournal = LiveRunningJournalController()
        return FreshJournalFlowDependencies(
            acquirer: .live(defaults: defaults, trustVerifier: trustVerifier, runningJournal: runningJournal),
            runningJournal: runningJournal,
            trustVerifier: trustVerifier,
            fetchIdentity: { baseURL in
                await JournalIdentityFetcher(prepareRequest: { $0.attachLoopbackCapability() })
                    .resolveIdentity(baseURL: baseURL, expectedInstanceID: nil)
            },
            waitingPollInterval: .seconds(3),
            sleep: { duration in
                try await Task.sleep(for: duration)
            }
        )
    }

    @MainActor
    static func inert(
        installedURL: URL? = nil,
        runningJournal: any RunningJournalController = InertRunningJournalController(),
        trustVerifier: any TrustVerifier = InertTrustVerifier(),
        fetchIdentity: @escaping @MainActor @Sendable (String) async -> JournalIdentityResolution = { _ in .absent }
    ) -> FreshJournalFlowDependencies {
        let runner = (installedURL != nil && runningJournal is InertRunningJournalController)
            ? InertRunningJournalController(installed: installedURL)
            : runningJournal
        return FreshJournalFlowDependencies(
            acquirer: nil,
            runningJournal: runner,
            trustVerifier: trustVerifier,
            fetchIdentity: fetchIdentity,
            waitingPollInterval: .milliseconds(10),
            sleep: { _ in }
        )
    }

    @MainActor
    init(
        acquirer: JournalAppAcquirer? = nil,
        runningJournal: any RunningJournalController,
        trustVerifier: any TrustVerifier,
        fetchIdentity: @escaping @MainActor @Sendable (String) async -> JournalIdentityResolution = { _ in .absent },
        waitingPollInterval: Duration = .seconds(3),
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in }
    ) {
        self.acquirer = acquirer
        self.runningJournal = runningJournal
        self.trustVerifier = trustVerifier
        self.fetchIdentity = fetchIdentity
        self.waitingPollInterval = waitingPollInterval
        self.sleep = sleep
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
    @ObservationIgnored
    private let resolveTrustedJournalOverride: (@MainActor () async throws -> URL)?

    init(
        dependencies: FreshJournalFlowDependencies,
        resolveTrustedJournalOverride: (@MainActor () async throws -> URL)? = nil
    ) {
        self.dependencies = dependencies
        self.resolveTrustedJournalOverride = resolveTrustedJournalOverride
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

    func trustedInstalledJournalURL() async -> URL? {
        if let installed = dependencies.runningJournal.installedURL(),
           (try? await dependencies.trustVerifier.verifyJournalApp(at: installed)) != nil {
            return installed
        }
        return nil
    }

    func resolveTrustedJournal() async throws -> URL {
        if let resolveTrustedJournalOverride {
            return try await resolveTrustedJournalOverride()
        }
        if let installed = await trustedInstalledJournalURL() {
            return installed
        } else {
            guard let acquirer = dependencies.acquirer else {
                throw JournalHandoffFailure.trustFailed("no acquirer available")
            }
            return try await acquirer.acquire { phase in
                self.state = .acquiring(phase)
            }
        }
    }

    func launchTrustedJournal(at trustedURL: URL) async throws {
        state = .launching
        try dependencies.runningJournal.launchJournalActivating(at: trustedURL)
        state = .waitingForJournal
    }

    private func runStart() async {
        cancelWaitingProbe()
        discoveredJournalMark = nil

        do {
            let trustedURL = try await resolveTrustedJournal()
            try await launchTrustedJournal(at: trustedURL)
        } catch is CancellationError {
            state = .idle
        } catch let failure as JournalHandoffFailure {
            state = .failed(failure)
        } catch {
            state = .failed(.appcastUnavailable(String(describing: error)))
        }
    }
}
