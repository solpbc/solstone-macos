// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security
import SPLTunnel

enum SPLRuntime {
    static var clientInfo: SPLClientInfo {
        SPLClientInfo(userAgent: "solstone-macos/\(AppVersion.short)")
    }
}

enum SPLPairingKeychain {
    static let service = "app.solstone.observer.spl"
    static let account = "spl-pairing-bundle"
    static let accessGroup = "7QCG8V4M6H.app.solstone.observer.spl"
    static let migrationService = "app.solstone.observer.spl.migration"
    static let portableBaselineAccount = "carried-pairing-portable-baseline-v1"
    static let destinationProvenance = "user-login-keychain:~/Library/Keychains/login.keychain-db"
    static let designatedRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"7QCG8V4M6H\" and identifier \"app.solstone.observer\""

    static func localMarkerMatches(_ record: CarriedPairingRecord, baseline: CarriedPairingBaseline) -> Bool {
        guard let marker = record.localMarker, !marker.isEmpty else { return false }
        return marker == baseline.marker
    }

    static func store() -> PairingStoring {
        SPLLoginKeychainStore()
    }
}

enum PairingKeychainError: Error, Equatable {
    case status(OSStatus)
    case unreadableCredential
    case conflictingCredentials
    case verificationFailed
}

/// The selected destination is always the user's login keychain file. Each item
/// query names its SecKeychain explicitly, so Security's process search list and
/// global keychain settings are never changed.
final class SPLLoginKeychainStore: PairingStoring, @unchecked Sendable {
    private let items: any PairingKeychainItems
    private let lock = NSRecursiveLock()

    init(items: any PairingKeychainItems = SecurityPairingKeychainItems()) {
        self.items = items
    }

    func load() throws -> StoredPairing? {
        try lock.withLock { () throws -> StoredPairing? in
            var record = try loadCarriedPairingRecord()
            let destination = try readDestination()
            if let destination {
                let pairing = try decode(destination)
                if let baseline = record.completedPortableBaseline {
                    // A completed portable baseline is portable only when this
                    // device still has its own matching, device-bound marker.
                    // Never recreate it from the record or baseline after restore.
                    guard SPLPairingKeychain.localMarkerMatches(record, baseline: baseline),
                          let marker = record.localMarker else {
                        return pairing
                    }
                    if Self.preparedTarget(record, matches: pairing) {
                        try completeBaseline(for: pairing, marker: marker, record: record)
                        record = try loadCarriedPairingRecord()
                    } else if record.initialMovePrepared,
                              baseline.fingerprint == pairing.fingerprint,
                              baseline.credentialRevision == PairingCredentialRevision(from: pairing).revision {
                        record.initialMovePrepared = false
                        try saveCarriedPairingRecord(record)
                        record = try loadCarriedPairingRecord()
                    }
                    if record.legacyCleanupPending {
                        // Once the portable baseline exists the login keychain wins;
                        // cleanup never reopens the legacy value as a fallback.
                        do {
                            try cleanLegacySource(record: record)
                            guard try readLegacy() == nil else { throw PairingKeychainError.verificationFailed }
                            try setCleanupPending(false, record: record)
                        } catch PairingKeychainError.conflictingCredentials {
                            throw PairingKeychainError.conflictingCredentials
                        } catch {
                            // Preserve the destination and durable cleanup obligation.
                        }
                    }
                    return pairing
                }

                let source = try readLegacy()
                if let source, source != destination {
                    throw PairingKeychainError.conflictingCredentials
                }
                guard record.initialMovePrepared, let marker = record.localMarker else {
                    if Self.preparedTarget(record, matches: pairing), let marker = record.localMarker {
                        try completeBaseline(for: pairing, marker: marker, record: record)
                        return pairing
                    }
                    throw PairingKeychainError.unreadableCredential
                }
                if let source {
                    record.preparedCredentialSourceProvenance = "data-protection-keychain"
                    Self.setCleanupPending(true, source: source, record: &record)
                    try saveCarriedPairingRecord(record)
                }
                try completeBaseline(for: pairing, marker: marker, record: record)
                if source != nil {
                    do {
                        try cleanLegacySource(record: try loadCarriedPairingRecord())
                        guard try readLegacy() == nil else { throw PairingKeychainError.verificationFailed }
                        try setCleanupPending(false, record: try loadCarriedPairingRecord())
                    } catch {
                        // Keep the verified destination authoritative and retry cleanup later.
                    }
                }
                return pairing
            }

            if record.completedPortableBaseline != nil {
                if record.legacyCleanupPending {
                    do {
                        try cleanLegacySource(record: record)
                        guard try readLegacy() == nil else { throw PairingKeychainError.verificationFailed }
                        try setCleanupPending(false, record: record)
                    } catch PairingKeychainError.conflictingCredentials {
                        throw PairingKeychainError.conflictingCredentials
                    } catch {
                        // A completed baseline keeps the destination authoritative;
                        // the tombstone retries cleanup without reviving this source.
                    }
                }
                return nil
            }
            if record.preparedCredentialFingerprint != nil {
                return nil // A fresh credential write had not reached the destination before restart.
            }
            if !record.initialMovePrepared {
                guard record.localMarker == nil else { throw PairingKeychainError.unreadableCredential }
                var prepared = record
                prepared.initialMovePrepared = true
                prepared.localMarker = UUID().uuidString
                prepared.preparedCredentialSourceProvenance = "data-protection-keychain"
                try saveCarriedPairingRecord(prepared)
                record = prepared
            }
            guard record.localMarker != nil else { throw PairingKeychainError.unreadableCredential }
            guard let legacy = try readLegacy() else {
                var finished = try loadCarriedPairingRecord()
                finished.initialMovePrepared = false
                finished.localMarker = nil
                finished.preparedCredentialSourceProvenance = nil
                try saveCarriedPairingRecord(finished)
                return nil
            }
            try writeDestination(legacy)
            guard try readDestination() == legacy else { throw PairingKeychainError.verificationFailed }
            let moved = try decode(legacy)
            var movedRecord = try loadCarriedPairingRecord()
            Self.setCleanupPending(true, source: legacy, record: &movedRecord)
            try saveCarriedPairingRecord(movedRecord)
            try completeBaseline(for: moved, marker: movedRecord.localMarker!, record: movedRecord)
            do {
                try cleanLegacySource(record: try loadCarriedPairingRecord())
                try setCleanupPending(false, record: try loadCarriedPairingRecord())
            } catch {
                // The verified destination and its cleanup tombstone are durable.
            }
            return moved
        }
    }

    func save(_ pairing: StoredPairing) throws {
        try lock.withLock {
            let bytes = try encode(pairing)
            var record = try loadCarriedPairingRecord()
            let wasPortable = record.completedPortableBaseline != nil
            let destination = try readDestination()
            if !wasPortable {
                guard !record.initialMovePrepared else {
                    throw PairingKeychainError.unreadableCredential
                }
                if let destination {
                    guard destination == bytes, Self.preparedTarget(record, matches: pairing) else {
                        throw PairingKeychainError.conflictingCredentials
                    }
                } else if try readLegacy() != nil {
                    throw PairingKeychainError.conflictingCredentials
                }
                if record.localMarker != nil && record.preparedCredentialFingerprint == nil {
                    throw PairingKeychainError.unreadableCredential
                }
            }

            let markerNeedsRotation = record.candidate?.rekeyFingerprint == pairing.fingerprint
                && record.completedPortableBaseline.map { record.localMarker != $0.marker } == true
            let marker = markerNeedsRotation ? UUID().uuidString : (record.localMarker ?? UUID().uuidString)
            let revision = PairingCredentialRevision(from: pairing)
            record.localMarker = marker
            record.preparedCredentialFingerprint = revision.fingerprint
            record.preparedCredentialRevision = revision.revision
            record.preparedJournalIdentity = journalMarkConfirmationIdentity(for: pairing)
            record.preparedCredentialSourceProvenance = record.candidate?.rekeyFingerprint == pairing.fingerprint
                ? "carried-rekey"
                : "pairing-ceremony"
            if record.legacyCleanupPending { try verifyLegacyCleanupSource(record: record) }
            try saveCarriedPairingRecord(record)

            try writeDestination(bytes)
            guard try readDestination() == bytes else { throw PairingKeychainError.verificationFailed }
            try completeBaseline(for: pairing, marker: marker, record: record)
            if record.legacyCleanupPending {
                do {
                    try cleanLegacySource(record: try loadCarriedPairingRecord())
                    guard try readLegacy() == nil else { throw PairingKeychainError.verificationFailed }
                    try setCleanupPending(false, record: try loadCarriedPairingRecord())
                } catch PairingKeychainError.conflictingCredentials {
                    throw PairingKeychainError.conflictingCredentials
                } catch {
                    // The portable baseline makes the login keychain authoritative.
                }
            }
        }
    }

    func delete() throws {
        try lock.withLock {
            try items.deleteDestination()
        }
    }

    func loadCarriedPairingRecord() throws -> CarriedPairingRecord {
        try lock.withLock {
            let markerData = try readDeviceItem(account: "marker")
            let recordData = try readDeviceItem(account: "record")
            var record: CarriedPairingRecord
            if let recordData {
                do { record = try JSONDecoder().decode(CarriedPairingRecord.self, from: recordData) }
                catch { throw PairingKeychainError.unreadableCredential }
            } else {
                record = .empty
            }
            if let markerData {
                guard let marker = String(data: markerData, encoding: .utf8), !marker.isEmpty else {
                    throw PairingKeychainError.unreadableCredential
                }
                record.localMarker = marker
            } else if !record.initialMovePrepared {
                record.localMarker = nil
            }
            if let baselineData = try readPortableBaseline() {
                do { record.completedPortableBaseline = try JSONDecoder().decode(CarriedPairingBaseline.self, from: baselineData) }
                catch { throw PairingKeychainError.unreadableCredential }
                // A missing device-only item cannot be supplied by the marker
                // cached in the device record, even during interrupted cleanup.
                if markerData == nil { record.localMarker = nil }
            }
            return record
        }
    }

    func saveCarriedPairingRecord(_ record: CarriedPairingRecord) throws {
        try lock.withLock {
            var deviceRecord = record
            deviceRecord.completedPortableBaseline = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(deviceRecord)
            try writeDeviceItem(account: "record", data: data)
            if let marker = record.localMarker {
                try writeDeviceItem(account: "marker", data: Data(marker.utf8))
            } else {
                try deleteDeviceItem(account: "marker")
            }
            if let baseline = record.completedPortableBaseline {
                try writePortableBaseline(encoder.encode(baseline))
            } else {
                try deletePortableBaseline()
            }
        }
    }

    private func completeBaseline(for pairing: StoredPairing, marker: String, record original: CarriedPairingRecord) throws {
        var record = original
        record.localMarker = marker
        let credential = PairingCredentialRevision(from: pairing)
        record.preparedCredentialFingerprint = credential.fingerprint
        record.preparedCredentialRevision = credential.revision
        record.preparedJournalIdentity = journalMarkConfirmationIdentity(for: pairing)
        try saveCarriedPairingRecord(record)
        record.completedPortableBaseline = Self.baseline(
            for: pairing,
            marker: marker,
            sourceProvenance: record.preparedCredentialSourceProvenance ?? "user-login-keychain"
        )
        try saveCarriedPairingRecord(record)
        record.initialMovePrepared = false
        record.preparedCredentialFingerprint = nil
        record.preparedCredentialRevision = nil
        record.preparedJournalIdentity = nil
        record.preparedCredentialSourceProvenance = nil
        try saveCarriedPairingRecord(record)
    }

    private static func preparedTarget(_ record: CarriedPairingRecord, matches pairing: StoredPairing) -> Bool {
        let credential = PairingCredentialRevision(from: pairing)
        return record.preparedCredentialFingerprint == credential.fingerprint
            && record.preparedCredentialRevision == credential.revision
            && record.preparedJournalIdentity == journalMarkConfirmationIdentity(for: pairing)
    }

    private static func baseline(
        for pairing: StoredPairing,
        marker: String,
        sourceProvenance: String
    ) -> CarriedPairingBaseline {
        let credential = PairingCredentialRevision(from: pairing)
        return CarriedPairingBaseline(
            journalIdentity: journalMarkConfirmationIdentity(for: pairing),
            fingerprint: credential.fingerprint,
            credentialRevision: credential.revision,
            marker: marker,
            sourceProvenance: sourceProvenance,
            destinationProvenance: SPLPairingKeychain.destinationProvenance
        )
    }

    private func setCleanupPending(_ pending: Bool, record: CarriedPairingRecord) throws {
        var updated = record
        Self.setCleanupPending(pending, source: nil, record: &updated)
        try saveCarriedPairingRecord(updated)
    }

    private static let legacySourceProvenance = "data-protection-keychain:\(SPLPairingKeychain.accessGroup)/\(SPLPairingKeychain.service)/\(SPLPairingKeychain.account)"

    private static func setCleanupPending(_ pending: Bool, source: Data?, record: inout CarriedPairingRecord) {
        record.legacyCleanupPending = pending
        if pending, let source {
            record.legacyCleanupSourceProvenance = legacySourceProvenance
            record.legacyCleanupDestinationProvenance = SPLPairingKeychain.destinationProvenance
            record.legacyCleanupCredentialDigest = SHA256Digest.hex(source)
        } else {
            record.legacyCleanupSourceProvenance = nil
            record.legacyCleanupDestinationProvenance = nil
            record.legacyCleanupCredentialDigest = nil
        }
    }

    private func encode(_ pairing: StoredPairing) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { return try encoder.encode(pairing) }
        catch { throw PairingKeychainError.unreadableCredential }
    }

    private func decode(_ data: Data) throws -> StoredPairing {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(StoredPairing.self, from: data) }
        catch { throw PairingKeychainError.unreadableCredential }
    }

    private func readPortableBaseline() throws -> Data? {
        try items.readPortableBaseline()
    }

    private func writePortableBaseline(_ data: Data) throws {
        try items.writePortableBaseline(data)
        guard try items.readPortableBaseline() == data else { throw PairingKeychainError.conflictingCredentials }
    }

    private func deletePortableBaseline() throws {
        try items.deletePortableBaseline()
    }

    private func readDestination() throws -> Data? {
        try items.readDestination()
    }

    private func writeDestination(_ data: Data) throws {
        try items.writeDestination(data)
    }

    private func readLegacy() throws -> Data? {
        try items.readLegacy()
    }

    private func cleanLegacySource() throws {
        try items.deleteLegacy()
    }

    private func cleanLegacySource(record: CarriedPairingRecord) throws {
        try verifyLegacyCleanupSource(record: record)
        try cleanLegacySource()
    }

    private func verifyLegacyCleanupSource(record: CarriedPairingRecord) throws {
        guard record.legacyCleanupPending,
              record.legacyCleanupSourceProvenance == Self.legacySourceProvenance,
              record.legacyCleanupDestinationProvenance == SPLPairingKeychain.destinationProvenance,
              let expectedDigest = record.legacyCleanupCredentialDigest else {
            throw PairingKeychainError.unreadableCredential
        }
        if let source = try readLegacy(), SHA256Digest.hex(source) != expectedDigest {
            throw PairingKeychainError.conflictingCredentials
        }
    }

    private func readDeviceItem(account: String) throws -> Data? {
        try items.readDeviceItem(account: account)
    }

    private func writeDeviceItem(account: String, data: Data) throws {
        try items.writeDeviceItem(account: account, data: data)
    }

    private func deleteDeviceItem(account: String) throws {
        try items.deleteDeviceItem(account: account)
    }
}

/// The physical keychain items behind the pairing store, one method per item.
/// Production reads and writes Security items; tests supply memory, so the
/// store's state machine is covered without touching a keychain.
protocol PairingKeychainItems: Sendable {
    func readDestination() throws -> Data?
    func writeDestination(_ data: Data) throws
    func deleteDestination() throws
    func readPortableBaseline() throws -> Data?
    func writePortableBaseline(_ data: Data) throws
    func deletePortableBaseline() throws
    func readLegacy() throws -> Data?
    func deleteLegacy() throws
    func readDeviceItem(account: String) throws -> Data?
    func writeDeviceItem(account: String, data: Data) throws
    func deleteDeviceItem(account: String) throws
}

/// Security-framework items. The credential and the adopted baseline are two
/// nonsynchronizing items in the user's login keychain file, written through an
/// explicit `kSecUseKeychain` destination with the app-bound access object, so
/// Migration Assistant and Time Machine carry them together. The device marker,
/// the pending candidate and the device record are Data Protection items with
/// `AfterFirstUnlockThisDeviceOnly`; nothing here is iCloud-synchronizable.
final class SecurityPairingKeychainItems: PairingKeychainItems, @unchecked Sendable {
    private let keychainURL: URL

    init(
        keychainURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db")
    ) {
        self.keychainURL = keychainURL
    }

    // MARK: Queries

    static func destinationIdentityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SPLPairingKeychain.service,
            kSecAttrAccount as String: SPLPairingKeychain.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    static func portableBaselineIdentityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SPLPairingKeychain.migrationService,
            kSecAttrAccount as String: SPLPairingKeychain.portableBaselineAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    static func legacyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SPLPairingKeychain.service,
            kSecAttrAccount as String: SPLPairingKeychain.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
            kSecAttrAccessGroup as String: SPLPairingKeychain.accessGroup
        ]
    }

    static func deviceQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SPLPairingKeychain.migrationService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: SPLPairingKeychain.accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any
        ]
    }

    static let deviceItemAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    private func openedKeychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainOpen(keychainURL.path, &keychain)
        guard status == errSecSuccess, let keychain else { throw PairingKeychainError.status(status) }
        return keychain
    }

    private func searchQuery(_ identity: [String: Any]) throws -> [String: Any] {
        var query = identity
        query[kSecMatchSearchList as String] = [try openedKeychain()] as CFArray
        return query
    }

    private func addQuery(_ identity: [String: Any]) throws -> [String: Any] {
        var query = identity
        query[kSecUseKeychain as String] = try openedKeychain()
        return query
    }

    // MARK: Login keychain items

    func readDestination() throws -> Data? {
        try readLoginItem(Self.destinationIdentityQuery())
    }

    func writeDestination(_ data: Data) throws {
        try writeLoginItem(Self.destinationIdentityQuery(), data: data)
    }

    func deleteDestination() throws {
        try deleteLoginItem(Self.destinationIdentityQuery())
    }

    func readPortableBaseline() throws -> Data? {
        try readLoginItem(Self.portableBaselineIdentityQuery())
    }

    func writePortableBaseline(_ data: Data) throws {
        try writeLoginItem(Self.portableBaselineIdentityQuery(), data: data)
    }

    func deletePortableBaseline() throws {
        try deleteLoginItem(Self.portableBaselineIdentityQuery())
    }

    private func readLoginItem(_ identity: [String: Any]) throws -> Data? {
        var query = try searchQuery(identity)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try copyData(query)
    }

    private func writeLoginItem(_ identity: [String: Any], data: Data) throws {
        let access = try destinationAccess()
        let query = try searchQuery(identity)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccess as String: access
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PairingKeychainError.status(update) }
        var add = try addQuery(identity)
        add[kSecValueData as String] = data
        add[kSecAttrAccess as String] = access
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw PairingKeychainError.status(status) }
        if status == errSecDuplicateItem {
            guard try readLoginItem(identity) == data else { throw PairingKeychainError.conflictingCredentials }
        }
    }

    private func deleteLoginItem(_ identity: [String: Any]) throws {
        let status = SecItemDelete(try searchQuery(identity) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingKeychainError.status(status)
        }
    }

    private func destinationAccess() throws -> SecAccess {
        var code: SecCode?
        let codeStatus = SecCodeCopySelf(SecCSFlags(), &code)
        guard codeStatus == errSecSuccess, let code else {
            throw PairingKeychainError.status(codeStatus)
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            SPLPairingKeychain.designatedRequirement as CFString,
            SecCSFlags(),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw PairingKeychainError.status(requirementStatus)
        }
        let validationStatus = SecCodeCheckValidity(code, SecCSFlags(), requirement)
        guard validationStatus == errSecSuccess else {
            throw PairingKeychainError.status(validationStatus)
        }

        // Supplying this access object explicitly restricts sensitive item
        // operations to the calling app. For signed macOS code, the keychain
        // records the app's designated requirement, so updates with the same
        // Developer ID identity retain access without a cdhash ACL. Never omit
        // kSecAttrAccess or continue with an implicit item ACL.
        var access: SecAccess?
        let accessStatus = SecAccessCreate("Solstone pairing credential" as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw PairingKeychainError.status(accessStatus)
        }
        return access
    }

    // MARK: Data Protection items

    func readLegacy() throws -> Data? {
        var query = Self.legacyQuery()
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try copyData(query)
    }

    func deleteLegacy() throws {
        let status = SecItemDelete(Self.legacyQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingKeychainError.status(status) }
    }

    func readDeviceItem(account: String) throws -> Data? {
        var query = Self.deviceQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return try copyData(query)
    }

    func writeDeviceItem(account: String, data: Data) throws {
        let query = Self.deviceQuery(account: account)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.deviceItemAccessibility
        ]
        let update = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PairingKeychainError.status(update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = Self.deviceItemAccessibility
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingKeychainError.status(status) }
    }

    func deleteDeviceItem(account: String) throws {
        let status = SecItemDelete(Self.deviceQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingKeychainError.status(status) }
    }

    private func copyData(_ query: [String: Any]) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw PairingKeychainError.unreadableCredential }
            return data
        case errSecItemNotFound: return nil
        default: throw PairingKeychainError.status(status)
        }
    }
}
