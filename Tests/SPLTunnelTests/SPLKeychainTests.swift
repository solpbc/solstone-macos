// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security
import Testing
@testable import SPLTunnel

@Suite("SPLKeychain", .serialized)
struct SPLKeychainTests {
    private let testService = "app.solstone.observer.spl.test.\(UUID().uuidString)"

    @Test func saveLoadRoundTrip() throws {
        try clean()
        defer { try? clean() }

        let pairing = fixture()
        try SPLKeychain._save(pairing, service: testService)
        let loaded = try SPLKeychain._load(service: testService)

        #expect(loaded == pairing)
    }

    @Test func deleteIsIdempotent() throws {
        try clean()
        try SPLKeychain._delete(service: testService)
        try SPLKeychain._delete(service: testService)
    }

    @Test func saveTwiceOverwrites() throws {
        try clean()
        defer { try? clean() }

        let first = fixture(instanceID: "first")
        let second = fixture(instanceID: "second")
        try SPLKeychain._save(first, service: testService)
        try SPLKeychain._save(second, service: testService)

        #expect(try SPLKeychain._load(service: testService) == second)
    }

    @Test func loadMissingReturnsNil() throws {
        try clean()
        #expect(try SPLKeychain._load(service: testService) == nil)
    }

    @Test func attributesAreExpected() throws {
        try clean()
        defer { try? clean() }

        try SPLKeychain._save(fixture(), service: testService)
        var query = SPLKeychain.baseQuery(service: testService)
        query[kSecReturnAttributes as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let attrs = try #require(result as? [String: Any])
        #expect(attrs[kSecAttrService as String] as? String == testService)
        #expect(attrs[kSecAttrAccount as String] as? String == SPLKeychain.account)
        if let accessible = attrs[kSecAttrAccessible as String] as? String {
            #expect(accessible == kSecAttrAccessibleAfterFirstUnlock as String)
        }
        if let synchronizable = attrs[kSecAttrSynchronizable as String] as? Bool {
            #expect(synchronizable == false)
        }
    }

    @Test func tearDownDeletesTestServiceItems() throws {
        try clean()
        try SPLKeychain._save(fixture(), service: testService)
        try clean()
        #expect(try SPLKeychain._load(service: testService) == nil)
    }

    @Test func encodingWritesRelayEnrollmentAndOmitsLegacyDeviceToken() throws {
        let data = try SPLKeychain.encode(fixture())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["relayEnrollment"] != nil)
        #expect(object["deviceToken"] == nil)
    }

    @Test func legacyDeviceTokenDecodesAsEnrolled() throws {
        let pairing = try SPLKeychain.decode(Self.payload(extra: ["deviceToken": "legacy-token"]))

        #expect(pairing.relayEnrollment == .enrolled(deviceToken: "legacy-token", expiresAt: nil))
    }

    @Test func missingRelayEnrollmentDecodesAsUnavailable() throws {
        let pairing = try SPLKeychain.decode(Self.payload(extra: [:]))

        #expect(pairing.relayEnrollment == .unavailable)
    }

    @Test func bothRelayEnrollmentAndLegacyDeviceTokenPrefersRelayEnrollment() throws {
        let pairing = try SPLKeychain.decode(Self.payload(extra: [
            "deviceToken": "legacy-token",
            "relayEnrollment": [
                "enrolled": [
                    "deviceToken": "current-token",
                    "expiresAt": "2036-01-01T00:00:00Z",
                ],
            ],
        ]))

        #expect(pairing.relayEnrollment == .enrolled(deviceToken: "current-token", expiresAt: "2036-01-01T00:00:00Z"))
    }

    @Test func localEndpointCodableKeepsHostWireKey() throws {
        let endpoint = LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")
        let data = try JSONEncoder().encode(endpoint)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""host""#))
        #expect(!json.contains(#""ip""#))
        #expect(try JSONDecoder().decode(LocalEndpoint.self, from: data) == endpoint)
    }

    @Test func legacyRecordWithLocalEndpointDecodesWithoutEndpointLoss() throws {
        let pairing = try SPLKeychain.decode(Self.payload(extra: [
            "deviceToken": "legacy-token",
            "localEndpoints": [
                [
                    "host": "192.168.1.10",
                    "port": 7657,
                    "scope": "lan",
                ],
            ],
        ]))

        #expect(pairing.localEndpoints == [LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")])
        #expect(pairing.relayEnrollment == .enrolled(deviceToken: "legacy-token", expiresAt: nil))
    }

    private func clean() throws {
        try SPLKeychain._delete(service: testService)
    }

    private func fixture(instanceID: String = "instance-1") -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: "living room mac",
            relayEndpoint: "https://spl.solpbc.org",
            fingerprint: "sha256:abcdef",
            clientCertPEM: "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----\n",
            clientKeyPEM: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n",
            caChainPEM: "-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----\n",
            relayEnrollment: .enrolled(deviceToken: "device-token", expiresAt: nil),
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private static func payload(extra: [String: Any]) throws -> Data {
        var payload: [String: Any] = [
            "instanceID": "instance",
            "homeLabel": "home",
            "relayEndpoint": "wss://relay.example.com",
            "fingerprint": "sha256:\(String(repeating: "a", count: 64))",
            "clientCertPEM": "cert",
            "clientKeyPEM": "key",
            "caChainPEM": "ca",
            "localEndpoints": [],
            "pairedAt": "2026-01-01T00:00:00Z",
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
