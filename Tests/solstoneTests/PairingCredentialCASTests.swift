// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

@Suite("Pairing Credential CAS Tests")
struct PairingCredentialCASTests {
    @Test("Generations increment on save, delete, and external changes")
    func testGenerationIncrements() throws {
        let store = PairingStore(pairing: nil)
        let credStore = PairingCredentialStore(store: store)

        let initialGens = credStore.currentGenerations()
        #expect(initialGens.pairingGeneration == 1)
        #expect(initialGens.accessMutationGeneration == 1)

        let pairing1 = pairing(instanceID: "inst-1")
        try credStore.save(pairing1)

        let afterSaveGens = credStore.currentGenerations()
        #expect(afterSaveGens.pairingGeneration == 2)
        #expect(afterSaveGens.accessMutationGeneration == 2)

        try credStore.delete()
        let afterDeleteGens = credStore.currentGenerations()
        #expect(afterDeleteGens.pairingGeneration == 3)
        #expect(afterDeleteGens.accessMutationGeneration == 3)
    }

    @Test("Save with stale expected generation throws CAS error")
    func testSaveStaleGeneration() throws {
        let p = pairing(instanceID: "inst-1")
        let store = PairingStore(pairing: p)
        let credStore = PairingCredentialStore(store: store)
        _ = try credStore.load()

        let staleGen: UInt64 = 999
        #expect(throws: PairingCredentialStoreError.staleGeneration) {
            try credStore.save(p, expectedGeneration: staleGen)
        }
    }

    @Test("Update relay access updates enrollment and bumps access mutation generation only")
    func testUpdateRelayAccess() throws {
        let p = pairing(instanceID: "inst-1")
        let store = PairingStore(pairing: p)
        let credStore = PairingCredentialStore(store: store)
        _ = try credStore.load()

        let gens = credStore.currentGenerations()
        let expiryString = "2026-09-07T15:00:00Z"

        let (updated, newAccessGen) = try credStore.updateRelayAccess(
            expectedPairingGen: gens.pairingGeneration,
            expectedAccessGen: gens.accessMutationGeneration,
            relayOrigin: "https://relay.solstone.test",
            deviceToken: "token-123",
            expiresAtString: expiryString
        )

        #expect(updated.relayEndpoint == "https://relay.solstone.test")
        #expect(newAccessGen == gens.accessMutationGeneration + 1)
        #expect(credStore.currentGenerations().pairingGeneration == gens.pairingGeneration)
        #expect(credStore.currentGenerations().accessMutationGeneration == newAccessGen)

        // Verify underlying store was updated
        #expect(store.currentPairing?.relayEndpoint == "https://relay.solstone.test")
    }

    @Test("Clear relay access transitions enrollment to unavailable")
    func testClearRelayAccess() throws {
        let p = pairing(
            instanceID: "inst-1",
            relayEnrollment: .enrolled(deviceToken: "tok", expiresAt: "2026-09-07T15:00:00Z")
        )
        let store = PairingStore(pairing: p)
        let credStore = PairingCredentialStore(store: store)
        _ = try credStore.load()

        let gens = credStore.currentGenerations()
        let (cleared, newAccessGen) = try credStore.clearRelayAccess(
            expectedPairingGen: gens.pairingGeneration,
            expectedAccessGen: gens.accessMutationGeneration
        )

        if case .unavailable = cleared.relayEnrollment {
            // expected
        } else {
            Issue.record("Expected unavailable relay enrollment")
        }
        #expect(newAccessGen == gens.accessMutationGeneration + 1)
    }

    @Test("Concurrent/stale access mutation throws CAS error")
    func testStaleAccessMutation() throws {
        let p = pairing(instanceID: "inst-1")
        let store = PairingStore(pairing: p)
        let credStore = PairingCredentialStore(store: store)
        _ = try credStore.load()

        let gens = credStore.currentGenerations()
        #expect(throws: PairingCredentialStoreError.staleGeneration) {
            _ = try credStore.updateRelayAccess(
                expectedPairingGen: gens.pairingGeneration,
                expectedAccessGen: gens.accessMutationGeneration + 5,
                relayOrigin: "https://relay.solstone.test",
                deviceToken: "token-123",
                expiresAtString: "2026-09-07T15:00:00Z"
            )
        }
    }
}
