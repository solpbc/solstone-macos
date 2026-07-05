// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
@testable import SPLTunnel
import Testing
@testable import solstone

@Suite("Pairing overlay", .serialized)
@MainActor
struct PairingOverlayTests {
    @Test func notEntitledRendersDistinctPairedButTierWarning() {
        let presentation = makePairingConnectionPresentation(for: .error(.notEntitled), hasPairing: true)

        #expect(presentation.message == "can't sync over the internet yet")
        #expect(presentation.severity == .warn)
        #expect(presentation.axToken == PairingConnectionAXState.notEntitled.axToken)
    }

    @Test func relayAccessUnavailableRendersDistinctLineAndCaption() throws {
        let presentation = try #require(makePairingRelayAccessPresentation(for: .unavailable))

        #expect(presentation.message == "paired · remote access unavailable")
        #expect(presentation.caption == "on the same wi-fi or over your own vpn, sol connects to your journal directly.")
        #expect(presentation.severity == .warn)
        #expect(presentation.axToken == PairingRelayAccessAXState.unavailable.axToken)
    }

    @Test func relayAccessAvailableAndNoPairingRenderNothing() {
        #expect(makePairingRelayAccessPresentation(for: .available) == nil)
        #expect(makePairingRelayAccessPresentation(for: .noPairing) == nil)
    }

    @Test func localJournalConnectionPresentationIsUploadStatusDriven() {
        let synced = makeLocalJournalConnectionPresentation(for: .synced)
        #expect(synced.message == "connected to your journal on this mac")
        #expect(synced.severity == .good)
        #expect(synced.axToken == PairingConnectionAXState.connected.axToken)

        for status in [
            UploadCoordinator.Status.notSynced,
            .syncing(checked: 1, total: 3),
            .uploading(segment: "segment-1"),
            .awaitingTunnel,
            .retrying(segment: "segment-1", attempts: 2)
        ] {
            let presentation = makeLocalJournalConnectionPresentation(for: status)
            #expect(presentation.severity == .warn)
            #expect(presentation.axToken == PairingConnectionAXState.connecting.axToken)
        }

        let offline = makeLocalJournalConnectionPresentation(for: .offline("network"))
        #expect(offline.message == "can't reach your journal on this mac")
        #expect(offline.severity == .attention)
        #expect(offline.axToken == PairingConnectionAXState.loopbackUnavailable.axToken)
    }

    @Test func unpairLeavesConfigByteIdentical() async throws {
        let config = AppConfig(
            serverURL: "https://journal.example",
            serverKey: "secret",
            serviceMode: .external
        )
        let before = serviceConfigSnapshot(config)
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))
        let resolver = makeResolver(owner: owner, config: config)
        let coordinator = makeCoordinator(store: store, owner: owner)

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        #expect(await resolver.resolve() == .url("http://127.0.0.1:24680"))

        await coordinator.unpair()
        try await waitUntil { owner.state == .disconnected }
        #expect(await resolver.resolve() == .url("https://journal.example"))
        await owner.stop()

        #expect(serviceConfigSnapshot(config) == before)
        #expect(coordinator.state == .idle)
        #expect(transport.disconnectCount >= 1)
        #expect(!owner.isTunnelManaged)
        #expect(store.deleted)
        #expect(store.currentPairing == nil)
    }

    @Test func activationWiringFlipsTunnelManagedAndResolverYieldsLoopback() async throws {
        let config = AppConfig(
            serverURL: "https://journal.example",
            serverKey: "secret",
            serviceMode: .external
        )
        let store = PairingStore(pairing: nil)
        let transport = FakeTunnelTransport(connection: .init(localPort: 24681, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))
        let resolver = makeResolver(owner: owner, config: config)

        owner.start()
        try await waitUntil { owner.state == .disconnected }
        #expect(await resolver.resolve() == .url("https://journal.example"))
        try store.save(pairing())

        await owner.reevaluatePairing()
        try await waitUntil { owner.state == .connected(localPort: 24681, via: .relay) }
        #expect(owner.isTunnelManaged)
        #expect(await resolver.resolve() == .url("http://127.0.0.1:24681"))
        await owner.stop()
    }

    @Test func relayAccessStatusLoadsOnRelaunchWhilePairingFlowIdle() {
        let store = PairingStore(pairing: pairing(relayEnrollment: .unavailable))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([FakeTunnelTransport()]))
        let coordinator = makeCoordinator(store: store, owner: owner)

        #expect(coordinator.state == .idle)
        #expect(owner.relayAccessStatus == .unavailable)
    }

    @Test func pairingSectionIsInertWhenSettingsSceneNotRendered() async {
        let config = AppConfig(
            serverURL: "https://journal.example",
            serverKey: "secret",
            serviceMode: .external
        )
        let state = AppState.forSnapshot(config: config)

        #expect(state.pairingCoordinator.state == .idle)
        #expect(state.tunnelLifecycleOwner.state == .disconnected)
        #expect(!state.tunnelLifecycleOwner.isTunnelManaged)
        #expect(serviceConfigSnapshot(state.config) == serviceConfigSnapshot(config))
    }

    private func makeCoordinator(store: PairingStore, owner: TunnelLifecycleOwner) -> PairingCoordinator {
        PairingCoordinator(
            pair: { _, _, _ in pairing() },
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            reactivate: { [owner] in
                await owner.reevaluatePairing()
            },
            ownerState: { [owner] in
                owner.state
            }
        )
    }

    private func makeOwner(
        store: PairingStore,
        factory: FakeTransportFactory
    ) -> TunnelLifecycleOwner {
        TunnelLifecycleOwner(
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(store.currentPairing ?? pairing())]).seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            sleep: { _ in try await Task.sleep(for: .seconds(10)) }
        )
    }

    private func makeResolver(owner: TunnelLifecycleOwner, config: AppConfig) -> HomeBaseURLResolver {
        HomeBaseURLResolver { [owner, config] in
            await MainActor.run {
                if owner.isTunnelManaged {
                    guard let localPort = owner.localPort else {
                        return .held
                    }
                    return .url("http://127.0.0.1:\(localPort)")
                }
                guard let serverURL = config.serverURL else {
                    return .held
                }
                return .url(serverURL)
            }
        }
    }

    private func serviceConfigSnapshot(_ config: AppConfig) -> ServiceConfigSnapshot {
        ServiceConfigSnapshot(
            serverURL: config.serverURL,
            serverKey: config.serverKey,
            serviceMode: config.serviceMode
        )
    }
}

private struct ServiceConfigSnapshot: Equatable {
    let serverURL: String?
    let serverKey: String?
    let serviceMode: ServiceMode?
}
