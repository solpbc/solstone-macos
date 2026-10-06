// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

@Suite("PairingCredentialStore")
struct PairingCredentialStoreTests {
    @Test func onlyMatchingCompletedPortableBaselineAndDeviceMarkerAdmitTraffic() throws {
        let stored = pairing()
        let backend = PairingStore(pairing: stored)
        let credentials = PairingCredentialStore(store: backend)
        let loaded = try #require(try credentials.load())
        #expect(credentials.admission(for: loaded) == .ready)

        var record = try backend.loadCarriedPairingRecord()
        record.localMarker = "marker-from-another-device"
        try backend.saveCarriedPairingRecord(record)
        let restored = PairingCredentialStore(store: backend)
        #expect(restored.admission(for: loaded) == .migrationRequired)
    }

    @Test func markerWithoutBaselineNeverAdmitsAndPreparedMoveRequiresRecovery() throws {
        let stored = pairing()
        let backend = PairingStore(pairing: stored)
        var record = CarriedPairingRecord.empty
        record.localMarker = "marker-alone"
        try backend.saveCarriedPairingRecord(record)
        #expect(PairingCredentialStore(store: backend).admission(for: stored) == .blocked)

        record.initialMovePrepared = true
        try backend.saveCarriedPairingRecord(record)
        #expect(PairingCredentialStore(store: backend).admission(for: stored) == .migrationRequired)
    }

    @Test func completedBaselineAndMatchingMarkerAdmitInterruptedCompletion() throws {
        let stored = pairing()
        let backend = PairingStore(pairing: stored)
        var record = try backend.loadCarriedPairingRecord()
        let revision = PairingCredentialRevision(from: stored)
        record.initialMovePrepared = true
        record.preparedCredentialFingerprint = revision.fingerprint
        record.preparedCredentialRevision = revision.revision
        record.preparedJournalIdentity = journalMarkConfirmationIdentity(for: stored)
        try backend.saveCarriedPairingRecord(record)

        #expect(PairingCredentialStore(store: backend).admission(for: stored) == .ready)
    }

    @Test(arguments: [false, true])
    func completedBaselineDoesNotAdoptWhenActualMarkerIsAbsentOrMismatched(markerPresent: Bool) throws {
        let stored = pairing()
        let backend = PairingStore(pairing: stored)
        var record = try backend.loadCarriedPairingRecord()
        let baselineMarker = try #require(record.completedPortableBaseline?.marker)
        let revision = PairingCredentialRevision(from: stored)
        record.initialMovePrepared = true
        record.preparedCredentialFingerprint = revision.fingerprint
        record.preparedCredentialRevision = revision.revision
        record.preparedJournalIdentity = journalMarkConfirmationIdentity(for: stored)
        record.localMarker = markerPresent ? "marker-from-restored-device" : nil
        if markerPresent { #expect(record.localMarker != baselineMarker) }
        try backend.saveCarriedPairingRecord(record)

        #expect(PairingCredentialStore(store: backend).admission(for: stored) == .migrationRequired)
        #expect(try backend.loadCarriedPairingRecord().completedPortableBaseline?.marker == baselineMarker)
    }

    @Test func unreadableDeviceMarkerStateBlocksAdmission() throws {
        let stored = pairing()
        let backend = PairingStore(pairing: stored)
        backend.setCarriedRecordLoadError(SPLKeychainError.loadFailed(status: -1))

        #expect(PairingCredentialStore(store: backend).admission(for: stored) == .blocked)
    }

    @Test func candidateOwnershipIncludesCredentialRevisionAndOperationID() throws {
        let old = pairing()
        let backend = PairingStore(pairing: old)
        let credentials = PairingCredentialStore(store: backend)
        _ = try credentials.load()
        var record = try backend.loadCarriedPairingRecord()
        let oldRevision = PairingCredentialRevision(from: old)
        record.candidate = CarriedPairingCandidate(
            operationID: "operation-a",
            csrPEM: "csr",
            privateKeyPEM: "private-key",
            previousFingerprint: oldRevision.fingerprint,
            previousRevision: oldRevision.revision,
            previousInstanceID: old.instanceID,
            rekeyReply: nil,
            rekeyFingerprint: nil
        )
        try credentials.saveCarriedPairingRecord(record)
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

    @Test func mismatchedPortableMarkerDiscardsStaleCandidateBeforeFreshAdmission() throws {
        let stored = pairing()
        let backend = PairingStore(pairing: stored)
        let credentials = PairingCredentialStore(store: backend)
        _ = try credentials.load()
        var record = try backend.loadCarriedPairingRecord()
        record.localMarker = "marker-from-restored-device"
        record.candidate = CarriedPairingCandidate(
            operationID: "stale-operation",
            csrPEM: "old-csr",
            privateKeyPEM: "old-private-key",
            previousFingerprint: "old-fingerprint",
            previousRevision: "old-revision",
            previousInstanceID: stored.instanceID,
            rekeyReply: nil,
            rekeyFingerprint: nil
        )
        try backend.saveCarriedPairingRecord(record)

        #expect(PairingCredentialStore(store: backend).admission(for: stored) == .migrationRequired)
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

    @Test func lateInvalidationCannotClearReplacementOperationsForSameJournal() throws {
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
        record.candidate = CarriedPairingCandidate(
            operationID: "new-operation",
            csrPEM: "new-csr",
            privateKeyPEM: "new-private-key",
            previousFingerprint: replacementRevision.fingerprint,
            previousRevision: replacementRevision.revision,
            previousInstanceID: replacement.instanceID,
            rekeyReply: nil,
            rekeyFingerprint: nil
        )
        record.decision = CarriedPairingDecision(
            decisionID: "new-decision",
            operationID: "new-operation",
            previousCID: old.fingerprint,
            choice: nil,
            replacesCID: nil,
            credentialFingerprint: replacement.fingerprint,
            credentialRevision: replacementRevision.revision,
            submitted: false
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
        #expect(latest.candidate?.operationID == "new-operation")
        #expect(latest.decision?.decisionID == "new-decision")
    }
}
