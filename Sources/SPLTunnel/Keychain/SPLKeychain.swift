// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security

public struct StoredPairing: Codable, Sendable, Equatable {
    public let instanceID: String
    public let homeLabel: String
    public let relayEndpoint: String
    public let fingerprint: String
    public let clientCertPEM: String
    public let clientKeyPEM: String
    public let caChainPEM: String
    public let deviceToken: String
    public let pairedAt: Date

    enum CodingKeys: String, CodingKey {
        case instanceID
        case homeLabel
        case relayEndpoint
        case fingerprint
        case clientCertPEM
        case clientKeyPEM
        case caChainPEM
        case deviceToken
        case pairedAt
    }
}

public enum SPLKeychainError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case saveFailed(status: OSStatus)
    case loadFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
}

public enum SPLKeychain {
    static let prodService = "app.solstone.observer.spl"
    static let account = "spl-pairing-bundle"

    public static func save(_ pairing: StoredPairing) throws {
        try _save(pairing, service: prodService)
    }

    public static func load() throws -> StoredPairing? {
        try _load(service: prodService)
    }

    public static func delete() throws {
        try _delete(service: prodService)
    }

    static func _save(_ pairing: StoredPairing, service: String) throws {
        try _delete(service: service)

        var query = baseQuery(service: service)
        query[kSecValueData as String] = try encode(pairing)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SPLKeychainError.saveFailed(status: status)
        }
    }

    static func _load(service: String) throws -> StoredPairing? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SPLKeychainError.loadFailed(status: errSecInternalError)
            }
            return try decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw SPLKeychainError.loadFailed(status: status)
        }
    }

    static func _delete(service: String) throws {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SPLKeychainError.deleteFailed(status: status)
        }
    }

    static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    static func encode(_ pairing: StoredPairing) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(pairing)
        } catch {
            throw SPLKeychainError.encodingFailed
        }
    }

    static func decode(_ data: Data) throws -> StoredPairing {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(StoredPairing.self, from: data)
        } catch {
            throw SPLKeychainError.decodingFailed
        }
    }
}
