// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

extension TerminalContinuityPlan.AppPairing {
    init?(pairing: StoredPairing, confirmed: Bool) {
        guard let certificate = try? CertChain.certificates(fromPEM: pairing.clientCertPEM).first else { return nil }
        let caCertificate = try? CertChain.certificates(fromPEM: pairing.caChainPEM).first
        self.init(
            deviceID: "sha256:" + CertChain.sha256Fingerprint(of: certificate),
            journal: TerminalJournalIdentity(
                journalID: try? CertChain.journalID(ofCAChainPEM: pairing.caChainPEM),
                instanceID: pairing.instanceID,
                caFingerprint: caCertificate.map { CertChain.sha256Fingerprint(of: $0) } ?? ""
            ),
            confirmed: confirmed
        )
    }
}

/// The old app's credential, as its file holds it.
struct TerminalLegacyCredential: Decodable, Equatable, Sendable {
    let clientCertPEM: String
    let caChainPEM: [String]
    let caFingerprintPrefix: [UInt8]
    let instanceID: String

    enum CodingKeys: String, CodingKey {
        case clientCertPEM = "client_cert_pem"
        case caChainPEM = "ca_chain_pem"
        case caFingerprintPrefix = "ca_fp_prefix"
        case instanceID = "instance_id"
    }

    var deviceID: String? {
        guard let certificate = try? CertChain.certificates(fromPEM: clientCertPEM).first else { return nil }
        return "sha256:" + CertChain.sha256Fingerprint(of: certificate)
    }

    var journal: TerminalJournalIdentity {
        let chain = caChainPEM.joined(separator: "\n")
        return TerminalJournalIdentity(
            journalID: try? CertChain.journalID(ofCAChainPEM: chain),
            instanceID: instanceID,
            caFingerprint: caFingerprintPrefix.map { String(format: "%02x", $0) }.joined()
        )
    }
}

enum TerminalMigrationAnswer: Equatable, Sendable {
    case settled(TerminalContinuity)
    /// Keep the stored request and send it again later; the text is for status.
    case retry(String)

    static func classify(status: Int, reason: String?) -> TerminalMigrationAnswer {
        if (200..<300).contains(status) { return .settled(.continued) }
        switch reason {
        case "paired_device_not_found", "migration_target_conflict", "migration_protocol_unsupported",
             "migration_forbidden", "migration_request_invalid", "migration_replay_forbidden",
             "migration_self_replacement":
            return .settled(.newStream(reason: reason ?? "", needsAttention: false))
        case "migration_operation_conflict":
            return .settled(.newStream(reason: "migration_operation_conflict", needsAttention: true))
        case nil where status == 404:
            return .settled(.newStream(reason: "journal_too_old", needsAttention: false))
        case let reason?:
            return .retry(reason)
        case nil:
            return .retry("status \(status)")
        }
    }
}

enum TerminalContinuityPlan: Equatable, Sendable {
    case settle(TerminalContinuity)
    /// Paired and waiting for a confirmed link, or not paired yet.
    case wait
    case migrate(replaces: String, callerID: String)

    struct AppPairing: Equatable, Sendable {
        let deviceID: String
        let journal: TerminalJournalIdentity
        let confirmed: Bool
    }

    struct Legacy: Equatable, Sendable {
        let deviceID: String
        let journal: TerminalJournalIdentity
    }

    /// `legacy` is the old pairing as read, or what was recorded when a migration
    /// was first sent. `nil` means there is no usable old pairing.
    static func decide(legacy: Legacy?, app: AppPairing?) -> TerminalContinuityPlan {
        guard let legacy else { return .settle(.newStream(reason: "no_old_pairing", needsAttention: false)) }
        guard let app else { return .wait }
        guard legacy.journal.isSameJournal(as: app.journal) else {
            return .settle(.newStream(reason: "different_journal", needsAttention: false))
        }
        guard app.deviceID != legacy.deviceID else { return .settle(.continued) }
        guard app.confirmed else { return .wait }
        return .migrate(replaces: legacy.deviceID, callerID: app.deviceID)
    }

    /// The migration request. The journal compares these exact bytes on any retry.
    static func migrationBody(operationID: String, replaces: String) -> String {
        "{\"protocol_version\":1,\"operation_id\":\"\(operationID)\",\"choice\":\"replace_device\",\"replaces_cid\":\"\(replaces)\"}"
    }

    /// The stored request, kept for retries and replaced only when this app
    /// re-paired under a new device.
    static func storedOrNew(
        _ record: inout TerminalTakeoverRecord,
        replaces: String,
        callerID: String,
        newOperationID: () -> String = { UUID().uuidString.lowercased() }
    ) -> TerminalMigrationRecord {
        if let stored = record.migration, stored.callerID == callerID { return stored }
        let operationID = newOperationID()
        let created = TerminalMigrationRecord(
            operationID: operationID,
            body: migrationBody(operationID: operationID, replaces: replaces),
            callerID: callerID
        )
        record.migration = created
        return created
    }
}
