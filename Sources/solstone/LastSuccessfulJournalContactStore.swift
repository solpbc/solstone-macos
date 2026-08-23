// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import SolstoneCore

internal struct JournalConnectionFingerprint: Equatable, Sendable {
    let value: String
}

internal struct TunnelPairingIdentity: Equatable, Sendable {
    let instanceID: String
    let fingerprint: String
}

internal enum PairingIdentityRead: Equatable, Sendable {
    case found(TunnelPairingIdentity)
    case absent
    case failed
}

internal enum JournalIdentityRead: Equatable, Sendable {
    case identified(JournalConnectionFingerprint)
    case absent
    case failed

    var fingerprint: JournalConnectionFingerprint? {
        switch self {
        case .identified(let fingerprint):
            return fingerprint
        case .absent, .failed:
            return nil
        }
    }
}

internal struct LastSuccessfulJournalContactPayload: Codable, Equatable, Sendable {
    let date: Date
    let fingerprint: String
}

internal enum LastSuccessfulJournalContactRead: Equatable, Sendable {
    case found(LastSuccessfulJournalContactPayload)
    case absent
    case failed
}

internal protocol LastSuccessfulJournalContactStoring: Sendable {
    func read() -> LastSuccessfulJournalContactRead
    func write(_ payload: LastSuccessfulJournalContactPayload)
    func clear()
}

internal final class UserDefaultsLastSuccessfulJournalContactStore: LastSuccessfulJournalContactStoring, @unchecked Sendable {
    static let storageKey = "lastSuccessfulJournalContact"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read() -> LastSuccessfulJournalContactRead {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return .absent
        }
        do {
            return .found(try JSONDecoder().decode(LastSuccessfulJournalContactPayload.self, from: data))
        } catch {
            return .failed
        }
    }

    func write(_ payload: LastSuccessfulJournalContactPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

internal final class InMemoryLastSuccessfulJournalContactStore: LastSuccessfulJournalContactStoring, @unchecked Sendable {
    private var readResult: LastSuccessfulJournalContactRead

    init(readResult: LastSuccessfulJournalContactRead = .absent) {
        self.readResult = readResult
    }

    func read() -> LastSuccessfulJournalContactRead {
        readResult
    }

    func write(_ payload: LastSuccessfulJournalContactPayload) {
        readResult = .found(payload)
    }

    func clear() {
        readResult = .absent
    }
}

internal func resolveLastSuccessfulJournalContactOutcome(
    read: LastSuccessfulJournalContactRead,
    currentFingerprint: JournalConnectionFingerprint?
) -> SetupLastSyncOutcome {
    switch read {
    case .failed:
        return .couldNotCheck
    case .found(let payload):
        guard let currentFingerprint else {
            return .notLinked
        }
        return payload.fingerprint == currentFingerprint.value ? .synced(payload.date) : .noSyncYet
    case .absent:
        guard currentFingerprint != nil else {
            return .notLinked
        }
        return .noSyncYet
    }
}

internal func journalConnectionFingerprint(
    config: AppConfig,
    topology: SetupTopology,
    isTunnelManaged: Bool,
    tunnelPairing: TunnelPairingIdentity?
) -> JournalConnectionFingerprint? {
    if isTunnelManaged {
        guard let tunnelPairing else { return nil }
        return makeJournalConnectionFingerprint([
            "tunnel",
            tunnelPairing.instanceID,
            tunnelPairing.fingerprint
        ])
    }

    if config.serviceMode == .bundled {
        return makeJournalConnectionFingerprint([
            "bundled",
            "serviceMode=bundled",
            config.journalPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "<nil-journal-path>"
        ])
    }

    guard topology != .undecided,
          let serverURL = config.serverURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
          let serverKey = config.serverKey?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
        return nil
    }

    return makeJournalConnectionFingerprint([
        "direct",
        serverURL,
        serverKey
    ])
}

internal func isJournalConnectionFingerprintValue(_ value: String) -> Bool {
    guard value.hasPrefix("sha256:") else {
        return false
    }
    let hex = value.dropFirst("sha256:".count)
    guard hex.count == 64 else {
        return false
    }
    return hex.allSatisfy { character in
        ("0"..."9").contains(character) || ("a"..."f").contains(character)
    }
}

private func makeJournalConnectionFingerprint(_ parts: [String]) -> JournalConnectionFingerprint {
    let canonical = parts.joined(separator: "\u{1F}")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return JournalConnectionFingerprint(value: "sha256:\(hex)")
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
