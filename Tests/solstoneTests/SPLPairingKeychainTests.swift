// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

struct SPLPairingKeychainTests {
    @Test func selectedStorePinsTheUserLoginKeychainBackend() {
        #expect(SPLPairingKeychain.store() is SPLLoginKeychainStore)
        #expect(SPLPairingKeychain.migrationService == "app.solstone.observer.spl.migration")
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
