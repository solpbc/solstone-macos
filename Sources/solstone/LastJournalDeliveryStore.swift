// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal enum LastJournalDeliveryOutcome: Equatable, Sendable {
    case delivered(Date)
    case noDeliveryYet
    case notLinked
    case unavailable
}

internal struct LastJournalDeliveryPayload: Codable, Equatable, Sendable {
    let date: Date
    let fingerprint: String
}

internal enum LastJournalDeliveryRead: Equatable, Sendable {
    case found(LastJournalDeliveryPayload)
    case absent
    case failed
}

internal enum LastJournalDeliveryWriteResult: Equatable, Sendable {
    case confirmed
    case failed
}

internal protocol LastJournalDeliveryStoring: Sendable {
    func read() -> LastJournalDeliveryRead
    func write(_ payload: LastJournalDeliveryPayload) -> LastJournalDeliveryWriteResult
}

internal final class UserDefaultsLastJournalDeliveryStore: LastJournalDeliveryStoring, @unchecked Sendable {
    static let storageKey = "lastJournalDelivery"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read() -> LastJournalDeliveryRead {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return .absent
        }
        do {
            let payload = try JSONDecoder().decode(LastJournalDeliveryPayload.self, from: data)
            guard isJournalConnectionFingerprintValue(payload.fingerprint) else {
                return .failed
            }
            return .found(payload)
        } catch {
            return .failed
        }
    }

    func write(_ payload: LastJournalDeliveryPayload) -> LastJournalDeliveryWriteResult {
        guard let data = try? JSONEncoder().encode(payload) else {
            return .failed
        }
        defaults.set(data, forKey: Self.storageKey)
        guard let stored = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(LastJournalDeliveryPayload.self, from: stored),
              decoded == payload else {
            return .failed
        }
        return .confirmed
    }
}

internal final class InMemoryLastJournalDeliveryStore: LastJournalDeliveryStoring, @unchecked Sendable {
    private var readResult: LastJournalDeliveryRead
    var writeResult: LastJournalDeliveryWriteResult

    init(
        readResult: LastJournalDeliveryRead = .absent,
        writeResult: LastJournalDeliveryWriteResult = .confirmed
    ) {
        self.readResult = readResult
        self.writeResult = writeResult
    }

    func read() -> LastJournalDeliveryRead {
        readResult
    }

    func write(_ payload: LastJournalDeliveryPayload) -> LastJournalDeliveryWriteResult {
        guard writeResult == .confirmed else {
            return .failed
        }
        readResult = .found(payload)
        return .confirmed
    }
}

/// Precedence, top to bottom:
/// 1. storage failure (undecodable / noncanonical fingerprint / negative or future date) → unavailable
/// 2. identity `.failed` → unavailable
/// 3. identity `.absent` → notLinked
/// 4. storage absent or fingerprint mismatch → noDeliveryYet
/// 5. match → delivered(date)
/// Then AC5: if `persistenceFailed` and the result is not `.delivered`, force `.unavailable`.
internal func resolveLastJournalDeliveryOutcome(
    read: LastJournalDeliveryRead,
    identity: JournalIdentityRead,
    now: Date,
    persistenceFailed: Bool
) -> LastJournalDeliveryOutcome {
    let honest = honestLastJournalDeliveryOutcome(read: read, identity: identity, now: now)
    if persistenceFailed {
        if case .delivered = honest {
            return honest
        }
        return .unavailable
    }
    return honest
}

private func honestLastJournalDeliveryOutcome(
    read: LastJournalDeliveryRead,
    identity: JournalIdentityRead,
    now: Date
) -> LastJournalDeliveryOutcome {
    if isLastJournalDeliveryStorageFailure(read: read, now: now) {
        return .unavailable
    }

    switch identity {
    case .failed:
        return .unavailable
    case .absent:
        return .notLinked
    case .identified(let current):
        switch read {
        case .absent:
            return .noDeliveryYet
        case .found(let payload):
            return payload.fingerprint == current.value ? .delivered(payload.date) : .noDeliveryYet
        case .failed:
            return .unavailable
        }
    }
}

private func isLastJournalDeliveryStorageFailure(read: LastJournalDeliveryRead, now: Date) -> Bool {
    switch read {
    case .failed:
        return true
    case .absent:
        return false
    case .found(let payload):
        return payload.date.timeIntervalSince1970 < 0 || payload.date > now
    }
}
