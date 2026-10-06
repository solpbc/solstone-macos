// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CryptoKit
import SPLTunnel

enum CarriedPairingAdmission: Equatable, Sendable {
    case ready
    case absent
    case blocked
    case migrationRequired
}

enum CarriedPairingLifecycleStatus: Equatable, Sendable {
    case preparing
    case offline
    case unsupported
    case storageUnavailable
    case keyRefused
}

enum CarriedPairingChoice: String, Codable, Sendable, Equatable {
    case sameDevice = "same_device"
    case newDevice = "new_device"
    case replaceDevice = "replace_device"
}

struct CarriedPairingBaseline: Codable, Sendable, Equatable {
    let journalIdentity: String
    let fingerprint: String
    let credentialRevision: String
    let marker: String
    let sourceProvenance: String
    let destinationProvenance: String

    init(
        journalIdentity: String,
        fingerprint: String,
        credentialRevision: String,
        marker: String,
        sourceProvenance: String = "user-login-keychain",
        destinationProvenance: String = "user-login-keychain:~/Library/Keychains/login.keychain-db"
    ) {
        self.journalIdentity = journalIdentity
        self.fingerprint = fingerprint
        self.credentialRevision = credentialRevision
        self.marker = marker
        self.sourceProvenance = sourceProvenance
        self.destinationProvenance = destinationProvenance
    }
}

struct CarriedPairingCandidate: Codable, Sendable, Equatable {
    let operationID: String
    let csrPEM: String
    let privateKeyPEM: String
    let previousFingerprint: String
    let previousRevision: String
    let previousInstanceID: String
    var rekeyReply: Data?
    var rekeyFingerprint: String?
}

struct CarriedPairingDecision: Codable, Sendable, Equatable {
    let decisionID: String
    let operationID: String?
    let previousCID: String?
    var choice: CarriedPairingChoice?
    let replacesCID: String?
    let credentialFingerprint: String
    let credentialRevision: String
    var submitted: Bool
}

struct CarriedPairingInvalidation: Codable, Sendable, Equatable {
    let operationID: String
    let fingerprint: String
    let journalIdentity: String
    let revision: String
    var remoteRetirementAttempted: Bool
    var remoteRetirementConfirmed = false
    var credentialCleanupPending: Bool
}

public struct CarriedPairingRecord: Codable, Sendable, Equatable {
    var localMarker: String?
    var initialMovePrepared = false
    var preparedCredentialFingerprint: String?
    var preparedCredentialRevision: String?
    var preparedJournalIdentity: String?
    var preparedCredentialSourceProvenance: String?
    var candidate: CarriedPairingCandidate?
    var decision: CarriedPairingDecision?
    var replacementOfferID: String?
    var replacementOfferShown = false
    var invalidation: CarriedPairingInvalidation?
    var legacyCleanupPending = false
    var legacyCleanupSourceProvenance: String?
    var legacyCleanupDestinationProvenance: String?
    var legacyCleanupCredentialDigest: String?
    var completedPortableBaseline: CarriedPairingBaseline?

    static let empty = CarriedPairingRecord()
}

struct PairingCredentialRevision: Codable, Sendable, Equatable {
    let fingerprint: String
    let revision: String

    init(from pairing: StoredPairing) {
        fingerprint = pairing.fingerprint
        revision = SHA256Digest.hex(Data(PairingCredentialStore.identityToken(for: pairing).utf8))
    }
}

enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
