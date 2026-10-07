// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security
import Testing
@testable import solstone

struct SPLPairingKeychainTests {
    @Test func selectedStorePinsTheUserLoginKeychainBackend() {
        #expect(SPLPairingKeychain.store() is SPLLoginKeychainStore)
        #expect(SPLPairingKeychain.migrationService == "app.solstone.observer.spl.migration")
    }

    @Test func portableItemsAreNonsynchronizingLoginKeychainItems() {
        for query in [
            SecurityPairingKeychainItems.destinationIdentityQuery(),
            SecurityPairingKeychainItems.portableBaselineIdentityQuery()
        ] {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecUseDataProtectionKeychain as String] == nil)
            #expect(query[kSecAttrAccessGroup as String] == nil)
        }
        #expect(SecurityPairingKeychainItems.destinationIdentityQuery()[kSecAttrService as String] as? String == SPLPairingKeychain.service)
        #expect(SecurityPairingKeychainItems.portableBaselineIdentityQuery()[kSecAttrService as String] as? String == SPLPairingKeychain.migrationService)
    }

    @Test func deviceItemsAreNonsynchronizingDeviceOnlyDataProtectionItems() {
        for query in [
            SecurityPairingKeychainItems.deviceQuery(account: "marker"),
            SecurityPairingKeychainItems.deviceQuery(account: "record"),
            SecurityPairingKeychainItems.legacyQuery()
        ] {
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecAttrAccessGroup as String] as? String == SPLPairingKeychain.accessGroup)
        }
        #expect(SecurityPairingKeychainItems.deviceItemAccessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    @Test func loginItemUpdatesChangeTheSecretNeverTheAccessList() {
        // Passing an access object on update is a change-ACL operation, and
        // macOS asks for the login keychain password for every one of those.
        let attributes = SecurityPairingKeychainItems.loginItemUpdateAttributes(data: Data([1, 2, 3]))
        #expect(attributes.keys.sorted() == [kSecValueData as String])
        #expect(attributes[kSecAttrAccess as String] == nil)
        #expect(attributes[kSecValueData as String] as? Data == Data([1, 2, 3]))
    }

    @Test func aLockedLoginKeychainIsNotTreatedAsUnlocked() {
        let unlocked = SecKeychainStatus(kSecUnlockStateStatus)
        let readable = SecKeychainStatus(kSecReadPermStatus)
        let writable = SecKeychainStatus(kSecWritePermStatus)
        #expect(SecurityPairingKeychainItems.isUnlocked(unlocked | readable | writable))
        #expect(SecurityPairingKeychainItems.isUnlocked(unlocked))
        #expect(!SecurityPairingKeychainItems.isUnlocked(readable | writable))
        #expect(!SecurityPairingKeychainItems.isUnlocked(0))
    }

    @Test func policyLiteralsMatchEntitlementsAppPlist() throws {
        #expect(SPLPairingKeychain.service == "app.solstone.observer.spl")
        #expect(SPLPairingKeychain.account == "spl-pairing-bundle")
        #expect(SPLPairingKeychain.accessGroup == "7QCG8V4M6H.app.solstone.observer.spl")

        let accessGroup = SPLPairingKeychain.accessGroup
        let entitlementGroups = try entitlementsAppKeychainAccessGroups()
        #expect(entitlementGroups.contains(accessGroup))
    }

    private func entitlementsAppKeychainAccessGroups() throws -> [String] {
        let plistURL = try entitlementsAppPlistURL()
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dictionary = try #require(plist as? [String: Any])
        return try #require(dictionary["keychain-access-groups"] as? [String])
    }

    private func entitlementsAppPlistURL() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        var directory = fileURL.deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Sources/solstone/entitlements-app.plist")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }

        throw EntitlementsAppPlistLookupError.notFound
    }

    private enum EntitlementsAppPlistLookupError: Error {
        case notFound
    }
}
