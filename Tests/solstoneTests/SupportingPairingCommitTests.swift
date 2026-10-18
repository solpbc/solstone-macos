// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MacTestSupport
import SPLTunnel
import Testing
@testable import solstone

@Suite("Supporting pairing commit admission")
@MainActor
struct SupportingPairingCommitTests {
    private func fingerprint(_ pem: String = testCACertPEM) throws -> String {
        CertChain.sha256Fingerprint(of: try #require(CertChain.certificates(fromPEM: pem).first))
    }

    @Test(arguments: ["comparison", "termination", "cancel", "credential", "wrong-instance", "wrong-ca", "phase"])
    func actualCeremonyMustStillBeAdmittedBeforeCommit(change: String) async throws {
        let saved = pairing()
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let entered = LockedCounter()
        let store = PairingStore(pairing: nil)
        let credentials = PairingCredentialStore(store: store)
        let result = change == "wrong-instance" ? pairing(instanceID: "other-instance")
            : change == "wrong-ca" ? pairing(caChainPEM: otherCACertPEM) : saved
        var active = true
        var cleared = 0
        var reactivated = 0
        let coordinator = PairingCoordinator(
            pair: { _, _, _ in entered.increment(); await gate.wait(); return result },
            keychainStore: store, credentialStore: credentials,
            reactivate: { reactivated += 1 }, clearJournalMarkConfirmation: { cleared += 1 }
        )
        let handoff = UUID()
        let link = try relayPairLink(caPEM: testCACertPEM)
        let expectedCA = try fingerprint()
        let pending = Task {
            await coordinator.submitSupportingPairingLink(link, handoffID: handoff,
                expectedInstanceID: saved.instanceID, expectedCAFingerprint: expectedCA, while: { active })
        }
        try await waitUntil { entered.count == 1 }
        switch change {
        case "comparison", "termination": active = false; coordinator.cancelSupportingPairing(handoffID: handoff)
        case "cancel": pending.cancel()
        case "credential": try store.save(pairing(instanceID: "new-owner"))
        default: break
        }
        let beforeRecord = try store.loadCarriedPairingRecord()
        let writes = store.saveCount
        gate.release()
        await pending.value
        if change == "phase" {
            #expect(store.currentPairing == saved)
            #expect(store.saveCount == 1)
            #expect(cleared == 1)
            #expect(reactivated == 1)
            #expect(coordinator.state == .paired)
            #expect(try credentials.carriedPairingRecord().freshPairObligation == PairingCredentialRevision(from: saved))
        } else {
            #expect(store.saveCount == writes)
            #expect(try store.loadCarriedPairingRecord() == beforeRecord)
            #expect(cleared == 0)
            #expect(reactivated == 0)
        }
    }

    @Test func obsoleteCeremonyErrorCannotOverwriteNewOwnerPairing() async throws {
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let calls = LockedCounter()
        let saved = pairing()
        let newer = pairing(instanceID: "new-owner")
        let store = PairingStore(pairing: nil)
        let coordinator = PairingCoordinator(pair: { _, _, _ in
            calls.increment()
            if calls.count == 1 { await gate.wait(); throw URLError(.cancelled) }
            return newer
        }, keychainStore: store)
        let handoff = UUID()
        let link = try relayPairLink(caPEM: testCACertPEM)
        let expectedCA = try fingerprint()
        let old = Task {
            await coordinator.submitSupportingPairingLink(link, handoffID: handoff,
                expectedInstanceID: saved.instanceID, expectedCAFingerprint: expectedCA, while: { true })
        }
        try await waitUntil { calls.count == 1 }
        coordinator.cancelSupportingPairing(handoffID: handoff)
        await coordinator.submitPairingLink(link)
        #expect(coordinator.state == .paired)
        #expect(store.currentPairing == newer)
        gate.release()
        await old.value
        #expect(coordinator.state == .paired)
        #expect(store.currentPairing == newer)
        #expect(store.savedPairings == [newer])
    }

    @Test func cancellationAfterCommitPreservesCredentialAndNewerState() async throws {
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let entered = LockedCounter()
        let saved = pairing()
        let store = PairingStore(pairing: nil)
        var cleared = 0
        let coordinator = PairingCoordinator(pair: { _, _, _ in saved }, keychainStore: store,
            reactivate: { entered.increment(); await gate.wait() },
            clearJournalMarkConfirmation: { cleared += 1 })
        let handoff = UUID()
        let link = try relayPairLink(caPEM: testCACertPEM)
        let expectedCA = try fingerprint()
        let old = Task {
            await coordinator.submitSupportingPairingLink(link, handoffID: handoff,
                expectedInstanceID: saved.instanceID, expectedCAFingerprint: expectedCA, while: { true })
        }
        try await waitUntil { entered.count == 1 }
        #expect(store.currentPairing == saved)
        coordinator.cancelSupportingPairing(handoffID: handoff)
        await coordinator.submitPairingLink(try relayPairLink(caPEM: otherCACertPEM))
        #expect(coordinator.state == .switchConfirmPending)
        gate.release()
        await old.value
        #expect(coordinator.state == .switchConfirmPending)
        #expect(store.currentPairing == saved)
        #expect(store.savedPairings == [saved])
        #expect(cleared == 1)
    }

    @Test(arguments: ["held", "stale", "unreadable", "invalidation", "positive"])
    func conditionalSaveChecksDurableAbsenceBeforeIntent(change: String) throws {
        let saved = pairing()
        let store = PairingStore(pairing: nil)
        let credentials = PairingCredentialStore(store: store)
        #expect(try credentials.load() == nil)
        let generation = credentials.pairingGeneration
        switch change {
        case "held": try store.save(pairing(instanceID: "held-owner"))
        case "stale": try credentials.delete()
        case "unreadable": store.setCarriedRecordLoadError(CocoaError(.fileReadNoPermission))
        case "invalidation":
            var record = CarriedPairingRecord.empty
            record.invalidation = .init(operationID: "held", fingerprint: "fixture", journalIdentity: "fixture",
                                        revision: "fixture", remoteRetirementAttempted: false, credentialCleanupPending: false)
            try store.saveCarriedPairingRecord(record)
        default: break
        }
        let beforePairing = store.currentPairing
        let beforeRecord: CarriedPairingRecord? = try? store.loadCarriedPairingRecord()
        let writes = store.saveCount
        if change == "positive" {
            try credentials.saveFreshPairIfAbsent(saved, expectedGeneration: generation)
            #expect(store.currentPairing == saved)
            #expect(try credentials.carriedPairingRecord().freshPairObligation == PairingCredentialRevision(from: saved))
        } else {
            #expect(throws: (any Error).self) {
                try credentials.saveFreshPairIfAbsent(saved, expectedGeneration: generation)
            }
            #expect(store.currentPairing == beforePairing)
            #expect(store.saveCount == writes)
            store.setCarriedRecordLoadError(nil)
            if let beforeRecord { #expect(try store.loadCarriedPairingRecord() == beforeRecord) }
            else { #expect(try store.loadCarriedPairingRecord() == .empty) }
        }
    }
}
