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
    static func store() -> PairingStoring {
        SPLPairingStore()
    }

    static let productionPolicy = KeychainPolicy(
        service: service,
        account: account,
        accessGroup: accessGroup,
        useDataProtectionKeychain: true,
        accessibility: .afterFirstUnlockThisDeviceOnly
    )

    static let service = "app.solstone.observer.spl"
    static let account = "spl-pairing-bundle"
    static let recordService = "app.solstone.observer.spl.migration"
    static let recordAccount = "record"
    // Team-prefixed Data Protection keychain access group. Access is gated by Team ID,
    // not the binary code signature, so pairing survives every Sparkle app update
    // (changed cdhash) with zero prompts. ThisDeviceOnly keeps the credential off
    // backups and Migration Assistant: a moved Mac pairs again.
    //
    // MUST stay byte-for-byte identical to `keychain-access-groups` in
    // Sources/solstone/entitlements-app.plist AND the embedded
    // Contents/embedded.provisionprofile. SPLPairingKeychainTests.policyLiteralsMatchEntitlementsAppPlist
    // guards this Swift↔entitlement
    // drift: if the three copies disagree, the signed app gets a silent
    // errSecMissingEntitlement (-34018) at runtime. Verified working in this exact
    // team-prefixed form on hardware 2026-07-02 — do not reformat or drop the team prefix.
    static let accessGroup = "7QCG8V4M6H.app.solstone.observer.spl"

    /// The record item uses the same Data Protection, device-only, nonsynchronizing
    /// policy as the credential.
    static func recordQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recordService,
            kSecAttrAccount as String: recordAccount,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any
        ]
    }

    static let recordAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
}

enum PairingKeychainError: Error, Equatable {
    case status(OSStatus)
    case unreadableRecord
}

/// The pairing credential and its device record, both in the Data Protection
/// keychain. Neither item can raise a keychain prompt.
final class SPLPairingStore: PairingStoring, @unchecked Sendable {
    private let credential = SPLKeychainStore(policy: SPLPairingKeychain.productionPolicy)

    func load() throws -> StoredPairing? { try credential.load() }
    func save(_ pairing: StoredPairing) throws { try credential.save(pairing) }
    func delete() throws { try credential.delete() }

    func loadCarriedPairingRecord() throws -> CarriedPairingRecord {
        var query = SPLPairingKeychain.recordQuery()
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let record = try? JSONDecoder().decode(CarriedPairingRecord.self, from: data) else {
                throw PairingKeychainError.unreadableRecord
            }
            return record
        case errSecItemNotFound:
            return .empty
        default:
            throw PairingKeychainError.status(status)
        }
    }

    func saveCarriedPairingRecord(_ record: CarriedPairingRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let query = SPLPairingKeychain.recordQuery()
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PairingKeychainError.status(update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = SPLPairingKeychain.recordAccessibility
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingKeychainError.status(status) }
    }
}
