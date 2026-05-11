// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security

#if !os(macOS)
extension InnerTLS {
    private static let identityKeychainLabelPrefix = "app.solstone.swift.spl.identity."

    static func makeIdentityKeychainLabel() -> String {
        identityKeychainLabelPrefix + UUID().uuidString
    }

    static func assembleIdentityViaKeychain(
        leaf: SecCertificate,
        key: SecKey,
        label: String
    ) throws -> SecIdentity {
        cleanupKeychainIdentity(label: label)

        let certStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: leaf,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard certStatus == errSecSuccess else {
            cleanupKeychainIdentity(label: label)
            throw InnerTLSError.identityAssemblyFailed
        }

        let keyStatus = SecItemAdd([
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecAttrLabel as String: label,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard keyStatus == errSecSuccess else {
            cleanupKeychainIdentity(label: label)
            throw InnerTLSError.identityAssemblyFailed
        }

        var result: CFTypeRef?
        let copyStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard copyStatus == errSecSuccess, let identity = result as! SecIdentity? else {
            cleanupKeychainIdentity(label: label)
            throw InnerTLSError.identityAssemblyFailed
        }
        return identity
    }

    static func cleanupKeychainIdentity(label: String) {
        for itemClass in [kSecClassCertificate, kSecClassKey] {
            SecItemDelete([
                kSecClass as String: itemClass,
                kSecAttrLabel as String: label,
            ] as CFDictionary)
        }
    }

    public static func purgeOrphanedIdentities() {
        for itemClass in [kSecClassCertificate, kSecClassKey] {
            purgeOrphanedItems(itemClass: itemClass)
        }
    }

    private static func purgeOrphanedItems(itemClass: CFString) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: itemClass,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return
        }

        for item in items {
            guard let label = item[kSecAttrLabel as String] as? String,
                  label.hasPrefix(identityKeychainLabelPrefix) else {
                continue
            }
            cleanupKeychainIdentity(label: label)
        }
    }
}
#endif
