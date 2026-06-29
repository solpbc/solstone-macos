// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security

public struct LocalEndpoint: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int
    public let scope: String

    public init(host: String, port: Int, scope: String) {
        self.host = host
        self.port = port
        self.scope = scope
    }

    // The home's pairing response and the iOS client both key the address as
    // "ip" (iOS: `case host = "ip"`). Encode/decode the canonical "ip" key, but
    // tolerate the legacy macOS "host" key for any keychain record written by an
    // earlier build so an in-place upgrade never drops a stored pairing.
    private enum CodingKeys: String, CodingKey {
        case ip
        case host
        case port
        case scope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ip = try container.decodeIfPresent(String.self, forKey: .ip) {
            host = ip
        } else {
            host = try container.decode(String.self, forKey: .host)
        }
        port = try container.decode(Int.self, forKey: .port)
        scope = try container.decode(String.self, forKey: .scope)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .ip)
        try container.encode(port, forKey: .port)
        try container.encode(scope, forKey: .scope)
    }
}

public enum RelayEnrollment: Codable, Sendable, Equatable {
    case enrolled(deviceToken: String, expiresAt: String?)
    case unavailable

    private enum CodingKeys: String, CodingKey {
        case enrolled
        case unavailable
    }

    private enum EnrolledCodingKeys: String, CodingKey {
        case deviceToken
        case expiresAt
    }

    private struct EmptyPayload: Codable {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.enrolled) {
            let nested = try container.nestedContainer(keyedBy: EnrolledCodingKeys.self, forKey: .enrolled)
            let deviceToken = try nested.decode(String.self, forKey: .deviceToken)
            let expiresAt = try nested.decodeIfPresent(String.self, forKey: .expiresAt)
            self = .enrolled(deviceToken: deviceToken, expiresAt: expiresAt)
            return
        }
        if container.contains(.unavailable) {
            self = .unavailable
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "invalid relay enrollment")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .enrolled(let deviceToken, let expiresAt):
            var nested = container.nestedContainer(keyedBy: EnrolledCodingKeys.self, forKey: .enrolled)
            try nested.encode(deviceToken, forKey: .deviceToken)
            try nested.encodeIfPresent(expiresAt, forKey: .expiresAt)
        case .unavailable:
            try container.encode(EmptyPayload(), forKey: .unavailable)
        }
    }
}

public struct StoredPairing: Codable, Sendable, Equatable {
    public let instanceID: String
    public let homeLabel: String
    public let relayEndpoint: String
    public let fingerprint: String
    public let clientCertPEM: String
    public let clientKeyPEM: String
    public let caChainPEM: String
    public let relayEnrollment: RelayEnrollment
    public let localEndpoints: [LocalEndpoint]
    public let pairedAt: Date

    enum CodingKeys: String, CodingKey {
        case instanceID
        case homeLabel
        case relayEndpoint
        case fingerprint
        case clientCertPEM
        case clientKeyPEM
        case caChainPEM
        case relayEnrollment
        case deviceToken
        case localEndpoints
        case pairedAt
    }

    public init(
        instanceID: String,
        homeLabel: String,
        relayEndpoint: String,
        fingerprint: String,
        clientCertPEM: String,
        clientKeyPEM: String,
        caChainPEM: String,
        relayEnrollment: RelayEnrollment,
        localEndpoints: [LocalEndpoint] = [],
        pairedAt: Date
    ) {
        self.instanceID = instanceID
        self.homeLabel = homeLabel
        self.relayEndpoint = relayEndpoint
        self.fingerprint = fingerprint
        self.clientCertPEM = clientCertPEM
        self.clientKeyPEM = clientKeyPEM
        self.caChainPEM = caChainPEM
        self.relayEnrollment = relayEnrollment
        self.localEndpoints = localEndpoints
        self.pairedAt = pairedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceID = try container.decode(String.self, forKey: .instanceID)
        homeLabel = try container.decode(String.self, forKey: .homeLabel)
        relayEndpoint = try container.decode(String.self, forKey: .relayEndpoint)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        clientCertPEM = try container.decode(String.self, forKey: .clientCertPEM)
        clientKeyPEM = try container.decode(String.self, forKey: .clientKeyPEM)
        caChainPEM = try container.decode(String.self, forKey: .caChainPEM)
        if let enrollment = try container.decodeIfPresent(RelayEnrollment.self, forKey: .relayEnrollment) {
            relayEnrollment = enrollment
        } else if let legacyDeviceToken = try container.decodeIfPresent(String.self, forKey: .deviceToken) {
            relayEnrollment = .enrolled(deviceToken: legacyDeviceToken, expiresAt: nil)
        } else {
            relayEnrollment = .unavailable
        }
        localEndpoints = try container.decodeIfPresent([LocalEndpoint].self, forKey: .localEndpoints) ?? []
        pairedAt = try container.decode(Date.self, forKey: .pairedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instanceID, forKey: .instanceID)
        try container.encode(homeLabel, forKey: .homeLabel)
        try container.encode(relayEndpoint, forKey: .relayEndpoint)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(clientCertPEM, forKey: .clientCertPEM)
        try container.encode(clientKeyPEM, forKey: .clientKeyPEM)
        try container.encode(caChainPEM, forKey: .caChainPEM)
        try container.encode(relayEnrollment, forKey: .relayEnrollment)
        try container.encode(localEndpoints, forKey: .localEndpoints)
        try container.encode(pairedAt, forKey: .pairedAt)
    }
}

public enum SPLKeychainError: Error, Equatable, Sendable {
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

        let status = SecItemAdd(addAttributes(data: try encode(pairing), service: service) as CFDictionary, nil)
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

    // The SPL pairing bundle is intentionally backup-migratable (AfterFirstUnlock rather
    // than a device-only keychain class) so restoring preserves journal pairing.
    static func addAttributes(data: Data, service: String) -> [String: Any] {
        baseQuery(service: service).merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]) { _, new in new }
    }

    static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
