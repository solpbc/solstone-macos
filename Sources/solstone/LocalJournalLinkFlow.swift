// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import SolstoneCore

enum LocalJournalDiscoveryResult: Equatable {
    case found(JournalMark)
    case fork
}

@MainActor
func discoverLocalJournal(
    fetchIdentity: @escaping @MainActor @Sendable (String) async -> JournalMark?
) async -> LocalJournalDiscoveryResult {
    if let mark = await fetchIdentity(ServiceMode.bundledServiceURL) {
        return .found(mark)
    }
    return .fork
}

func makeObserverRegistrationDescriptor(
    hostname: String = ProcessInfo.processInfo.hostName,
    version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
) -> ObserverRegistrationDescriptor {
    let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    return ObserverRegistrationDescriptor(
        platform: "darwin",
        hostname: trimmedHostname.isEmpty ? "unknown" : trimmedHostname,
        streamType: "desktop",
        version: version
    )
}

@MainActor
func persistLocalObserverRegistration(
    _ registration: ObserverRegistration,
    appState: AppState
) {
    var config = appState.config
    config.serverURL = ServiceMode.bundledServiceURL
    config.serverKey = registration.key
    config.observerName = registration.streamName
    config.serviceMode = .external
    appState.updateConfig(config)
}

@MainActor
func performLocalObserverRegistration(
    appState: AppState,
    register: @escaping @MainActor @Sendable (
        _ baseURL: String,
        _ descriptor: ObserverRegistrationDescriptor
    ) async -> Result<ObserverRegistration, ObserverRegistrationFailure>
) async -> Result<ObserverRegistration, ObserverRegistrationFailure> {
    let descriptor = makeObserverRegistrationDescriptor()
    let result = await register(ServiceMode.bundledServiceURL, descriptor)
    if case .success(let registration) = result {
        persistLocalObserverRegistration(registration, appState: appState)
    }
    return result
}

@MainActor
func resetForJournalRelink(
    appState: AppState,
    journalMarkDriver: JournalMarkConfirmationDriver
) {
    journalMarkDriver.resetForNewPairAttempt()
    appState.clearConfirmedMark()
}

func resolvedJournalDisplayName(
    fetchedName: String?,
    confirmedMark: JournalMark?,
    serverURL: String?
) -> String {
    if let fetchedName, !fetchedName.isEmpty {
        return fetchedName
    }
    if let confirmedMark {
        return confirmedMark.words.joined(separator: " ")
    }
    return journalHost(serverURL)
}
