// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SolstoneCore

enum OnDiskJournalAdoptionAction: Equatable, Sendable {
    case install
    case open(URL)
}

extension OnDiskJournalAdoptionAction {
    var buttonTitle: String {
        switch self {
        case .install:
            return UICopy.SETTINGS_LOCAL_JOURNAL_INSTALL_EXISTING
        case .open:
            return UICopy.SETTINGS_LOCAL_JOURNAL_OPEN_EXISTING
        }
    }
}

struct OnDiskJournalAdoptionFlowDependencies {
    var acquirer: JournalAppAcquirer
    var runningJournal: any RunningJournalController
    var trustVerifier: any TrustVerifier
    var handoffFileURL: URL
    var fileManager: FileManager
    var now: @Sendable () -> Date
    var discoveryCapableBuild: Int

    @MainActor
    static func live(defaults: UserDefaults = .standard) -> OnDiskJournalAdoptionFlowDependencies {
        let trustVerifier = LiveTrustVerifier()
        return OnDiskJournalAdoptionFlowDependencies(
            acquirer: .live(defaults: defaults, trustVerifier: trustVerifier),
            runningJournal: LiveRunningJournalController(),
            trustVerifier: trustVerifier,
            handoffFileURL: JournalHandoffFile.url(),
            fileManager: .default,
            now: { Date() },
            discoveryCapableBuild: JournalHandoffConstants.discoveryCapableJournalBuild
        )
    }
}

@MainActor
@Observable
final class OnDiskJournalAdoptionFlow {
    private(set) var state: FreshJournalState = .idle

    @ObservationIgnored
    private var task: Task<Void, Never>?
    @ObservationIgnored
    private let dependencies: OnDiskJournalAdoptionFlowDependencies

    init(dependencies: OnDiskJournalAdoptionFlowDependencies = .live()) {
        self.dependencies = dependencies
    }

    func resolveOfferAction() async -> OnDiskJournalAdoptionAction {
        if let installed = await installedDiscoveryCapableJournalURL() {
            return .open(installed)
        }
        return .install
    }

    func start(
        discoveredPath: String,
        observerName: String?,
        action: OnDiskJournalAdoptionAction? = nil
    ) {
        guard task == nil else { return }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
            }
            await self.runStart(
                discoveredPath: discoveredPath,
                observerName: observerName,
                action: action
            )
        }
    }

    private func runStart(
        discoveredPath: String,
        observerName: String?,
        action: OnDiskJournalAdoptionAction?
    ) async {
        do {
            let resolvedAction: OnDiskJournalAdoptionAction
            if let action {
                resolvedAction = action
            } else {
                resolvedAction = await resolveOfferAction()
            }
            let trustedURL: URL
            switch resolvedAction {
            case .open(let installed):
                try assertDiscoveryCapableBuild(at: installed)
                trustedURL = installed
            case .install:
                trustedURL = try await dependencies.acquirer.acquire { phase in
                    self.state = .acquiring(phase)
                }
                try assertFreshlyInstalledDiscoveryCapableBuild(at: trustedURL)
            }

            state = .launching
            try writeDiscoveryHandoff(discoveredPath: discoveredPath, observerName: observerName)
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

    private func installedDiscoveryCapableJournalURL() async -> URL? {
        guard let installed = dependencies.runningJournal.installedURL(),
              (try? await dependencies.trustVerifier.verifyJournalApp(at: installed)) != nil,
              isDiscoveryCapableBuild(at: installed)
        else {
            return nil
        }
        return installed
    }

    private func isDiscoveryCapableBuild(at url: URL) -> Bool {
        guard let build = journalBuild(at: url) else {
            return false
        }
        return build >= dependencies.discoveryCapableBuild
    }

    private func assertDiscoveryCapableBuild(at url: URL) throws {
        guard isDiscoveryCapableBuild(at: url) else {
            throw JournalHandoffFailure.trustFailed("journal app build is too old for on-disk journal discovery")
        }
    }

    private func assertFreshlyInstalledDiscoveryCapableBuild(at url: URL) throws {
        guard let build = journalBuildFromInfoPlist(at: url),
              build >= dependencies.discoveryCapableBuild
        else {
            throw JournalHandoffFailure.trustFailed("journal app build is too old for on-disk journal discovery")
        }
    }

    private func journalBuild(at url: URL) -> Int? {
        guard let raw = Bundle(url: url)?.infoDictionary?["CFBundleVersion"] else {
            return nil
        }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let value = raw as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func journalBuildFromInfoPlist(at url: URL) -> Int? {
        let plistURL = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = plist["CFBundleVersion"]
        else {
            return nil
        }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
        }
        if let value = raw as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func writeDiscoveryHandoff(discoveredPath: String, observerName: String?) throws {
        let trimmedObserverName = observerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let handoff = JournalHandoff(
            journalRootPath: discoveredPath,
            observerName: trimmedObserverName?.isEmpty == false ? trimmedObserverName! : ProcessInfo.processInfo.hostName,
            provenance: JournalHandoffProvenance.observerDiscovery,
            timestamp: dependencies.now()
        )

        do {
            try dependencies.fileManager.createDirectory(
                at: dependencies.handoffFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(handoff)
            try data.write(to: dependencies.handoffFileURL, options: .atomic)
        } catch {
            throw JournalHandoffFailure.writeHandoffFailed(String(describing: error))
        }
    }
}
