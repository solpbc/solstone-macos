// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security
import Testing
@testable import SPLTunnel

/// Probes whether the DP keychain is reachable for this binary. Returns false ONLY on
/// errSecMissingEntitlement (-34018) — the unsigned/unentitled `swift test` binary under
/// `make ci`. Any other status lets the gated tests run (and fail) so a real DP regression
/// on an entitled host is still caught. Global `let` → evaluated once, cached.
let dpKeychainReachable: Bool = {
    let probeService = "app.solstone.observer.spl.dpprobe.\(UUID().uuidString)"
    let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        kSecAttrAccessGroup as String: SPLKeychain.accessGroup,
        kSecAttrService as String: probeService,
        kSecAttrAccount as String: "probe",
    ]
    var add = base
    add[kSecValueData as String] = Data("probe".utf8)
    let status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecMissingEntitlement { return false }
    SecItemDelete(base as CFDictionary)
    return true
}()

@Suite("SPLKeychain", .serialized)
struct SPLKeychainTests {
    private let testService = "app.solstone.observer.spl.test.\(UUID().uuidString)"

    @Test(.enabled(if: dpKeychainReachable)) func saveLoadRoundTrip() throws {
        try clean()
        defer { try? clean() }

        let pairing = fixture()
        try SPLKeychain._save(pairing, service: testService)
        let loaded = try SPLKeychain._load(service: testService)

        #expect(loaded == pairing)
    }

    @Test(.enabled(if: dpKeychainReachable)) func deleteIsIdempotent() throws {
        try clean()
        try SPLKeychain._delete(service: testService)
        try SPLKeychain._delete(service: testService)
    }

    @Test(.enabled(if: dpKeychainReachable)) func saveTwiceOverwrites() throws {
        try clean()
        defer { try? clean() }

        let first = fixture(instanceID: "first")
        let second = fixture(instanceID: "second")
        try SPLKeychain._save(first, service: testService)
        try SPLKeychain._save(second, service: testService)

        #expect(try SPLKeychain._load(service: testService) == second)
    }

    @Test(.enabled(if: dpKeychainReachable)) func loadMissingReturnsNil() throws {
        try clean()
        #expect(try SPLKeychain._load(service: testService) == nil)
    }

    @Test func addAttributesUseDataProtectionKeychainAndTeamAccessGroup() throws {
        let attrs = SPLKeychain.addAttributes(data: Data("x".utf8), service: "svc")
        #expect(try #require(attrs[kSecUseDataProtectionKeychain as String] as? Bool) == true)
        #expect(try #require(attrs[kSecAttrAccessGroup as String] as? String)
            == "7QCG8V4M6H.app.solstone.observer.spl")
        #expect(try #require(attrs[kSecAttrAccessible as String] as? String)
            == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        #expect(try #require(attrs[kSecAttrSynchronizable as String] as? Bool) == false)
    }

    @Test func updateAttributesContainOnlyValueData() throws {
        let attrs = SPLKeychain.updateAttributes(data: Data("x".utf8))
        #expect(try #require(attrs[kSecValueData as String] as? Data) == Data("x".utf8))
        #expect(attrs[kSecClass as String] == nil)
        #expect(attrs[kSecAttrService as String] == nil)
        #expect(attrs[kSecAttrAccount as String] == nil)
    }

    @Test(.enabled(if: dpKeychainReachable)) func tearDownDeletesTestServiceItems() throws {
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

    @Test func localEndpointEncodesCanonicalIPKeyAndDecodesBoth() throws {
        let endpoint = LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")
        // Encodes the canonical "ip" key (matches the home's pairing response + iOS).
        let data = try JSONEncoder().encode(endpoint)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""ip""#))
        #expect(!json.contains(#""host""#))
        #expect(try JSONDecoder().decode(LocalEndpoint.self, from: data) == endpoint)

        // Decodes the home's real wire shape (key "ip") — the bytes that arrive
        // in a live relay-form pairing response; decoding "host"-only would throw.
        let wire = Data(#"{"ip":"192.168.4.27","port":7657,"scope":"lan"}"#.utf8)
        #expect(try JSONDecoder().decode(LocalEndpoint.self, from: wire)
            == LocalEndpoint(host: "192.168.4.27", port: 7657, scope: "lan"))

        // Tolerates the legacy macOS keychain shape (key "host") so an in-place
        // upgrade never drops a stored pairing.
        let legacy = Data(#"{"host":"192.168.1.10","port":7657,"scope":"lan"}"#.utf8)
        #expect(try JSONDecoder().decode(LocalEndpoint.self, from: legacy) == endpoint)
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
