// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ServiceManagement
import SolstoneCore
import Testing
@testable import solstone

private enum DeliveryPairingLoadError: Error {
    case unavailable
}

@Suite("Journal delivery seams")
@MainActor
struct JournalDeliverySeamTests {
    @Test func unlinkDoesNotClearDeliveryPayload() throws {
        let config = linkedConfig()
        let fingerprint = try #require(directFingerprint(config))
        let payload = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: 50),
            fingerprint: fingerprint.value
        )
        let delivery = InMemoryLastJournalDeliveryStore(readResult: .found(payload))
        let state = AppState.forSnapshot(config: config, lastDeliveryStore: delivery)

        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .delivered(payload.date))

        state.clearLastSuccessfulJournalContact()

        #expect(delivery.read() == .found(payload))
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .delivered(payload.date))
    }

    @Test func updateConfigReResolvesDeliveryWithoutClearing() throws {
        let config = linkedConfig()
        let fingerprint = try #require(directFingerprint(config))
        let payload = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: 50),
            fingerprint: fingerprint.value
        )
        let delivery = InMemoryLastJournalDeliveryStore(readResult: .found(payload))
        let state = AppState.forSnapshot(config: config, lastDeliveryStore: delivery)

        var next = config
        next.serverKey = "other-key"
        state.updateConfig(next)

        #expect(delivery.read() == .found(payload))
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .noDeliveryYet)
    }

    @Test func handleTunnelLifecycleStateReResolvesDelivery() throws {
        let config = linkedConfig()
        let fingerprint = try #require(directFingerprint(config))
        let payload = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: 50),
            fingerprint: fingerprint.value
        )
        let delivery = InMemoryLastJournalDeliveryStore(readResult: .found(payload))
        let state = AppState.forSnapshot(config: config, lastDeliveryStore: delivery)

        state.handleTunnelLifecycleState(.disconnected)

        #expect(delivery.read() == .found(payload))
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .delivered(payload.date))
    }

    @Test func throwingPairingLoadFailsClosedAndReevaluateReResolves() async throws {
        let pairingHeld = pairing()
        let pairingStore = PairingStore(
            pairing: pairingHeld,
            loadOutcomes: [
                .success(pairingHeld),
                .failure(DeliveryPairingLoadError.unavailable)
            ]
        )
        let state = AppState.forLoginItemTest(
            loginService: FakeLoginItemService(
                watchdogStatus: .notRegistered,
                mainAppStatus: .notRegistered
            ),
            pairingLoad: { try pairingStore.load() }
        )

        #expect(state.currentJournalIdentity() != .failed)
        #expect(state.currentJournalIdentity() != .absent)

        await state.reevaluateTunnelPairing()

        #expect(state.currentJournalIdentity() == .failed)
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .unavailable)
    }

    @Test func invalidStorageStaysUnavailableThroughInitRefreshAndUnlink() throws {
        let config = linkedConfig()
        let fingerprint = try #require(directFingerprint(config))
        let invalid = LastJournalDeliveryPayload(
            date: Date(timeIntervalSince1970: -1),
            fingerprint: fingerprint.value
        )
        let delivery = InMemoryLastJournalDeliveryStore(readResult: .found(invalid))
        let state = AppState.forSnapshot(config: config, lastDeliveryStore: delivery)

        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .unavailable)
        #expect(delivery.read() == .found(invalid))

        state.uploadCoordinator.updateConfig(config)
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .unavailable)
        #expect(delivery.read() == .found(invalid))

        state.handleTunnelLifecycleState(.disconnected)
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .unavailable)
        #expect(delivery.read() == .found(invalid))

        state.clearLastSuccessfulJournalContact()
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .unavailable)
        #expect(delivery.read() == .found(invalid))

        let now = Date(timeIntervalSince1970: 200)
        state.uploadCoordinator.nowProvider = { now }
        state.uploadCoordinator.handleProgressEvent(
            .uploadSucceeded(segment: "x", journalFingerprint: fingerprint.value)
        )
        #expect(delivery.read() == .found(LastJournalDeliveryPayload(
            date: now,
            fingerprint: fingerprint.value
        )))
        #expect(state.uploadCoordinator.lastJournalDeliveryOutcome == .delivered(now))
    }
}

private func linkedConfig() -> AppConfig {
    AppConfig(
        serverURL: "https://journal.example",
        serverKey: "secret",
        serviceMode: .external
    )
}

private func directFingerprint(_ config: AppConfig) -> JournalConnectionFingerprint? {
    journalConnectionFingerprint(
        config: config,
        topology: .remote,
        isTunnelManaged: false,
        tunnelPairing: nil
    )
}
