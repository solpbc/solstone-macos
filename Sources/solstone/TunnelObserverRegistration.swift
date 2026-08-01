// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import JournalMarkKit
import os
import SolstoneCore

@MainActor
func performTunnelObserverRegistration(
    appState: AppState,
    isTunnelManaged: Bool,
    resolveBase: @escaping @MainActor @Sendable () async -> ResolvedHomeBase,
    register: @escaping @MainActor @Sendable (
        _ baseURL: String,
        _ descriptor: ObserverRegistrationDescriptor
    ) async -> Result<ObserverRegistration, ObserverRegistrationFailure>
) async {
    guard isTunnelManaged else { return }

    let resolvedBase = await resolveBase()
    guard case .url(let baseURL) = resolvedBase else {
        Logger.upload.debug("tunnel observer register held: tunnel base unavailable")
        return
    }

    let descriptor = makeObserverRegistrationDescriptor()
    let result = await register(baseURL, descriptor)
    switch result {
    case .success(let registration):
        if appState.config.serverKey == registration.key,
           appState.config.isUploadConfigured,
           !BundledJournalEndpoint.isBundledServiceURL(appState.config.serverURL) {
            // Key identity preserves dynamic-port reconnects once the persisted base has already moved.
            // Bundled-base same-key adoption must still rewrite the base to the tunnel endpoint.
            return
        }

        var config = appState.config
        config.serverURL = baseURL
        config.serverKey = registration.key
        config.observerName = registration.streamName
        config.serviceMode = .external
        appState.clearLastSuccessfulJournalContact()
        appState.updateConfig(config)

    case .failure(let failure):
        Logger.upload.warning("tunnel observer register failed: \(String(describing: failure.kind), privacy: .public)")
    }
}
