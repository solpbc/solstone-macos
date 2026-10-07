// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

@Suite("PairingCredentialStore")
struct PairingCredentialStoreTests {
    @Test func aStoredCredentialIsAdmittedUnlessADurableInvalidationIsPending() throws {
        let stored = pairing()
        let backend = PairingStore(pairing: stored)
        let credentials = PairingCredentialStore(store: backend)
        let loaded = try #require(try credentials.load())
        // A credential saved before the device record existed is still ready.
        #expect(credentials.admission(for: loaded) == .ready)
        #expect(credentials.admission(for: nil) == .absent)

        _ = try credentials.beginInvalidation(for: loaded, operationID: "unpair")
        #expect(credentials.admission(for: loaded) == .blocked)
    }

    @Test func unreadableDeviceRecordBlocksAdmission() throws {
        let stored = pairing()
        let backend = PairingStore(pairing: stored)
        backend.setCarriedRecordLoadError(SPLKeychainError.loadFailed(status: -1))

        #expect(PairingCredentialStore(store: backend).admission(for: stored) == .blocked)
    }

    @Test func invalidationOwnershipIncludesCredentialRevisionAndOperationID() throws {
        let old = pairing()
        let backend = PairingStore(pairing: old)
        let credentials = PairingCredentialStore(store: backend)
        _ = try credentials.load()
        let oldRevision = PairingCredentialRevision(from: old)
        _ = try credentials.beginInvalidation(for: old, operationID: "operation-a")
        #expect(credentials.owns(oldRevision, operationID: "operation-a"))
        #expect(!credentials.owns(oldRevision, operationID: "operation-b"))

        let replacement = StoredPairing(
            instanceID: old.instanceID,
            homeLabel: old.homeLabel,
            relayEndpoint: old.relayEndpoint,
            fingerprint: "replacement-fingerprint",
            clientCertPEM: "replacement-cert",
            clientKeyPEM: "replacement-key",
            caChainPEM: old.caChainPEM,
            relayEnrollment: old.relayEnrollment,
            localEndpoints: old.localEndpoints,
            pairedAt: old.pairedAt
        )
        try backend.save(replacement)
        #expect(!credentials.owns(oldRevision, operationID: "operation-a"))
    }

    @Test func markAnswerRequiresCurrentCredentialAndNoDurableInvalidation() throws {
        let old = pairing()
        let backend = PairingStore(pairing: old)
        let credentials = PairingCredentialStore(store: backend)
        _ = try credentials.load()
        let oldRevision = PairingCredentialRevision(from: old)
        #expect(credentials.markAnswerIsCurrent(oldRevision))

        let invalidation = try credentials.beginInvalidation(for: old, operationID: "mark-revocation")
        #expect(!credentials.markAnswerIsCurrent(oldRevision))

        let replacement = StoredPairing(
            instanceID: old.instanceID,
            homeLabel: old.homeLabel,
            relayEndpoint: old.relayEndpoint,
            fingerprint: "replacement-fingerprint",
            clientCertPEM: "replacement-certificate",
            clientKeyPEM: "replacement-private-key",
            caChainPEM: old.caChainPEM,
            relayEnrollment: old.relayEnrollment,
            localEndpoints: old.localEndpoints,
            pairedAt: old.pairedAt
        )
        try credentials.save(replacement)
        let replacementRevision = PairingCredentialRevision(from: replacement)
        try credentials.clearInvalidation(
            operationID: invalidation.operationID,
            fingerprint: invalidation.fingerprint,
            revision: invalidation.revision,
            expectedCurrentPairing: replacementRevision
        )

        #expect(credentials.markAnswerIsCurrent(replacementRevision))
        #expect(!credentials.markAnswerIsCurrent(oldRevision))
    }

    @Test func staleSameJournalInvalidationCannotDeleteReplacementCredential() throws {
        let old = pairing()
        let backend = PairingStore(pairing: old)
        let credentials = PairingCredentialStore(store: backend)
        _ = try credentials.load()
        var invalidation = try credentials.beginInvalidation(for: old, operationID: "retire-old")
        invalidation.remoteRetirementAttempted = true
        invalidation.remoteRetirementConfirmed = true
        try credentials.updateInvalidation(invalidation)

        let replacement = StoredPairing(
            instanceID: old.instanceID,
            homeLabel: old.homeLabel,
            relayEndpoint: old.relayEndpoint,
            fingerprint: "new-certificate-fingerprint",
            clientCertPEM: "new-certificate",
            clientKeyPEM: "new-key",
            caChainPEM: old.caChainPEM,
            relayEnrollment: old.relayEnrollment,
            localEndpoints: old.localEndpoints,
            pairedAt: old.pairedAt
        )
        try credentials.save(replacement, after: invalidation)
        #expect(throws: PairingCredentialStoreError.staleGeneration) {
            try credentials.delete(after: invalidation)
        }
        #expect(try credentials.load() == replacement)
        #expect(credentials.admission(for: replacement) == .blocked)
    }

    @Test func lateInvalidationCannotClearReplacementDecisionForSameJournal() throws {
        let old = pairing()
        let backend = PairingStore(pairing: old)
        let credentials = PairingCredentialStore(store: backend)
        _ = try credentials.load()
        var invalidation = try credentials.beginInvalidation(for: old, operationID: "retire-old")
        invalidation.remoteRetirementAttempted = true
        invalidation.remoteRetirementConfirmed = true
        try credentials.updateInvalidation(invalidation)

        let replacement = StoredPairing(
            instanceID: old.instanceID,
            homeLabel: old.homeLabel,
            relayEndpoint: old.relayEndpoint,
            fingerprint: "replacement-certificate-fingerprint",
            clientCertPEM: "replacement-certificate",
            clientKeyPEM: "replacement-private-key",
            caChainPEM: old.caChainPEM,
            relayEnrollment: old.relayEnrollment,
            localEndpoints: old.localEndpoints,
            pairedAt: old.pairedAt
        )
        try credentials.save(replacement, after: invalidation)
        let replacementRevision = PairingCredentialRevision(from: replacement)
        var record = try credentials.carriedPairingRecord()
        record.decision = CarriedPairingDecision(
            decisionID: "new-decision",
            choice: .newDevice,
            replacesCID: nil,
            credentialFingerprint: replacement.fingerprint,
            credentialRevision: replacementRevision.revision
        )
        try credentials.saveCarriedPairingRecord(record)

        #expect(throws: PairingCredentialStoreError.staleGeneration) {
            try credentials.clearInvalidation(
                operationID: invalidation.operationID,
                fingerprint: invalidation.fingerprint,
                revision: invalidation.revision,
                expectedCurrentPairing: PairingCredentialRevision(from: old)
            )
        }
        try credentials.clearInvalidation(
            operationID: invalidation.operationID,
            fingerprint: invalidation.fingerprint,
            revision: invalidation.revision,
            expectedCurrentPairing: replacementRevision
        )

        let latest = try credentials.carriedPairingRecord()
        #expect(latest.invalidation == nil)
        #expect(latest.decision?.decisionID == "new-decision")
    }
}
