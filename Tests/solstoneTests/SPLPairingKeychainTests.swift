// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security
import Testing
@testable import solstone

struct SPLPairingKeychainTests {
    @Test func storeUsesTheDataProtectionKeychainOnly() {
        #expect(SPLPairingKeychain.store() is SPLPairingStore)
    }

    @Test func policyLiteralsMatchEntitlementsAppPlist() throws {
        let production = SPLPairingKeychain.productionPolicy
        #expect(production.service == SPLPairingKeychain.service)
        #expect(production.account == SPLPairingKeychain.account)
        #expect(production.accessGroup == SPLPairingKeychain.accessGroup)
        #expect(production.useDataProtectionKeychain)
        #expect(production.accessibility == .afterFirstUnlockThisDeviceOnly)
        #expect(SPLPairingKeychain.service == "app.solstone.observer.spl")
        #expect(SPLPairingKeychain.account == "spl-pairing-bundle")
        #expect(SPLPairingKeychain.accessGroup == "7QCG8V4M6H.app.solstone.observer.spl")

        let accessGroup = try #require(production.accessGroup)
        let entitlementGroups = try entitlementsAppKeychainAccessGroups()
        #expect(entitlementGroups.contains(accessGroup))
    }

    @Test func recordItemIsANonsynchronizingDeviceOnlyDataProtectionItem() {
        let query = SPLPairingKeychain.recordQuery()
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessGroup as String] as? String == SPLPairingKeychain.accessGroup)
        #expect(query[kSecAttrService as String] as? String == SPLPairingKeychain.recordService)
        #expect(SPLPairingKeychain.recordAccessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
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
