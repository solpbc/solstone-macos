// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CryptoKit
import SPLTunnel

enum CarriedPairingAdmission: Equatable, Sendable {
    case ready
    case absent
    case blocked
}

/// The answer to "is this replacing one of your devices?" after a fresh pairing.
enum CarriedPairingChoice: String, Codable, Sendable, Equatable {
    case newDevice = "new_device"
    case replaceDevice = "replace_device"
}

struct CarriedPairingDecision: Codable, Sendable, Equatable {
    let decisionID: String
    let choice: CarriedPairingChoice
    let replacesCID: String?
    let credentialFingerprint: String
    let credentialRevision: String
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

/// Device-only state kept beside the pairing credential: the one-shot
/// replacement offer, its persisted decision, and a durable invalidation that
/// fences ordinary traffic while a credential is being removed.
public struct CarriedPairingRecord: Codable, Sendable, Equatable {
    var decision: CarriedPairingDecision?
    var replacementOfferID: String?
    var replacementOfferShown = false
    var invalidation: CarriedPairingInvalidation?
    var freshPairObligation: PairingCredentialRevision?
    var freshPairIntent: PairingCredentialRevision?
    var freshPairEligibilityAttempt: String?

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
