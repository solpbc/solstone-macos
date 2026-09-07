// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SPLTunnel
import Testing
@testable import solstone

@Suite("Journal Relay Access Tests")
struct JournalRelayAccessTests {
    static func makeJWT(
        claims: [String: Any],
        header: [String: Any] = ["alg": "none", "typ": "JWT"]
    ) -> String {
        let headerData = try! JSONSerialization.data(withJSONObject: header)
        let payloadData = try! JSONSerialization.data(withJSONObject: claims)
        let headerB64 = headerData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let payloadB64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "\(headerB64).\(payloadB64).signature"
    }

    private static func makeReadyJSON(
        protocolVersion: Int = 2,
        status: String = "ready",
        relayOrigin: String = "https://relay.solstone.test",
        instanceID: String = "test-instance",
        deviceToken: String,
        expiresAt: String = "2023-11-14T23:13:20Z",
        extraKey: String? = nil
    ) -> Data {
        var dict: [String: Any] = [
            "protocol_version": protocolVersion,
            "status": status,
            "relay_origin": relayOrigin,
            "instance_id": instanceID,
            "device_token": deviceToken,
            "expires_at": expiresAt
        ]
        if let extraKey {
            dict[extraKey] = true
        }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    @Test("Valid ready response succeeds with RelayAccessValidation.decode")
    func testValidReadyResponse() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let exp = 1700003600
        let iat = 1700000000
        let claims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": iat,
            "exp": exp,
            "jti": "jwt-1"
        ]
        let token = Self.makeJWT(claims: claims)
        let data = Self.makeReadyJSON(deviceToken: token)

        let validated = try RelayAccessValidation.decode(
            data,
            expectedInstanceID: "test-instance",
            now: now
        )

        guard case .ready(let ready) = validated else {
            Issue.record("Expected .ready validation outcome")
            return
        }
        #expect(ready.instanceID == "test-instance")
        #expect(ready.relayOrigin == URL(string: "https://relay.solstone.test")!)
        #expect(ready.deviceToken == token)
    }

    @Test("Status not_configured decodes as notConfigured")
    func testNotConfiguredResponse() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let json = #"{"protocol_version": 2, "status": "not_configured"}"#
        let validated = try RelayAccessValidation.decode(
            Data(json.utf8),
            expectedInstanceID: "test-instance",
            now: now
        )

        guard case .notConfigured = validated else {
            Issue.record("Expected .notConfigured validation outcome")
            return
        }
    }

    @Test("Protocol version mismatch throws")
    func testProtocolVersionMismatch() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let token = Self.makeJWT(claims: ["ver": 2, "instance_id": "test-instance", "iat": 1700000000, "exp": 1700003600])
        let data = Self.makeReadyJSON(protocolVersion: 1, deviceToken: token)

        #expect(throws: (any Error).self) {
            _ = try RelayAccessValidation.decode(data, expectedInstanceID: "test-instance", now: now)
        }
    }

    @Test("Instance mismatch throws")
    func testInstanceMismatch() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let token = Self.makeJWT(claims: ["ver": 2, "instance_id": "other-instance", "iat": 1700000000, "exp": 1700003600])
        let data = Self.makeReadyJSON(instanceID: "other-instance", deviceToken: token)

        #expect(throws: (any Error).self) {
            _ = try RelayAccessValidation.decode(data, expectedInstanceID: "test-instance", now: now)
        }
    }

    @Test("Invalid relay origin throws")
    func testInvalidRelayOrigin() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let token = Self.makeJWT(claims: ["ver": 2, "instance_id": "test-instance", "iat": 1700000000, "exp": 1700003600])
        let origins = ["http://relay.solstone.test", "ftp://relay", "https://", "", "not-a-url"]
        for origin in origins {
            let data = Self.makeReadyJSON(relayOrigin: origin, deviceToken: token)
            #expect(throws: (any Error).self) {
                _ = try RelayAccessValidation.decode(data, expectedInstanceID: "test-instance", now: now)
            }
        }
    }

    @Test("Extra JWT claims are rejected")
    func testExtraJWTClaimsRejected() throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let claims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": 1700000000,
            "exp": 1700003600,
            "jti": "jwt-1",
            "device_fp": "unexpected-claim"
        ]
        let token = Self.makeJWT(claims: claims)
        let data = Self.makeReadyJSON(deviceToken: token)

        #expect(throws: (any Error).self) {
            _ = try RelayAccessValidation.decode(data, expectedInstanceID: "test-instance", now: now)
        }
    }

    @Test("Expired token is rejected")
    func testExpiredTokenRejected() throws {
        let now = Date(timeIntervalSince1970: 1700005000)
        let claims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": 1700000000,
            "exp": 1700003600,
            "jti": "jwt-1"
        ]
        let token = Self.makeJWT(claims: claims)
        let data = Self.makeReadyJSON(deviceToken: token)

        #expect(throws: (any Error).self) {
            _ = try RelayAccessValidation.decode(data, expectedInstanceID: "test-instance", now: now)
        }
    }

    private func makeTestSession(store: ObserverURLProtocolStore) -> URLSession {
        let config = observerURLProtocolConfiguration(store: store)
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: JournalVersionRedirectDelegate(), delegateQueue: nil)
    }

    @MainActor
    private func makeOwnerHarness(
        store: ObserverURLProtocolStore,
        credStore: PairingCredentialStore,
        initialPairing: StoredPairing,
        sessions: SessionRecorder,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> (TunnelLifecycleOwner, URLSession) {
        store.registerRoute(path: "/app/network/api/clients/self", statusCode: 404)
        store.registerRoute(path: "/api/system/status", statusCode: 404)
        _ = try? credStore.load()
        let session = makeTestSession(store: store)
        let transportFactory: @MainActor @Sendable () -> any TunnelTransporting = {
            SPLTunnelTransport(
                clientInfo: SPLClientInfo(userAgent: "solstone-macos/test"),
                makeSession: { pairing, info, policy in
                    let s = FakeTunnelReconnectingSession(
                        connectedVia: URL(string: "https://new-relay.solstone.test")!.relayConnectedVia,
                        pairing: pairing,
                        clientInfo: info,
                        policy: policy
                    )
                    sessions.append(s)
                    return s
                }
            )
        }
        let owner = TunnelLifecycleOwner(
            credentialStore: credStore,
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(initialPairing)]).seam,
            makeTransport: transportFactory,
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            now: now,
            loopbackSession: session
        )
        return (owner, session)
    }

    @Test("Real adapter: ready persists new origin/token and replaceLiveTransport connects on new transport")
    @MainActor
    func testRealAdapterReadyPersistsAndReplacesLiveTransport() async throws {
        let store = ObserverURLProtocolStore()
        let sessions = SessionRecorder()

        let now = Date()
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + 3600
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAtStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(exp)))

        let claims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": iat,
            "exp": exp,
            "jti": "jwt-new"
        ]
        let token = Self.makeJWT(claims: claims)
        let readyJson = """
        {
            "protocol_version": 2,
            "status": "ready",
            "relay_origin": "https://new-relay.solstone.test",
            "instance_id": "test-instance",
            "device_token": "\(token)",
            "expires_at": "\(expiresAtStr)"
        }
        """
        store.enqueue(statusCode: 200, body: readyJson)

        let initialPairing = pairing(
            instanceID: "test-instance",
            deviceToken: "old-token",
            relayEndpoint: "https://old-relay.solstone.test"
        )
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)
        _ = try? credStore.load()
        let (initialPGen, initialAGen) = credStore.currentGenerations()

        let (owner, _) = makeOwnerHarness(
            store: store,
            credStore: credStore,
            initialPairing: initialPairing,
            sessions: sessions
        )

        owner.start()
        try await waitUntil { sessions.count >= 2 }
        let session0 = sessions[0]
        let session1 = sessions[1]

        try await waitUntil { await session1.recordedEndpoints.count >= 1 }

        let s1Endpoints = await session1.recordedEndpoints.last ?? []
        let hasExpectedRelay = s1Endpoints.contains { ep in
            if case .relay(let url, _, let tok) = ep {
                return url == URL(string: "https://new-relay.solstone.test") && tok == token
            }
            return false
        }
        #expect(hasExpectedRelay)
        let s1Pairing = session1.pairing
        #expect(s1Pairing?.clientCertPEM == initialPairing.clientCertPEM)

        let s0ConnectsBefore = await session0.connectCallCount
        await session1.requestReconnect()
        #expect(await session1.connectCallCount == 2)
        #expect(await session0.connectCallCount == s0ConnectsBefore)

        let (finalPGen, finalAGen) = credStore.currentGenerations()
        #expect(finalPGen == initialPGen)
        #expect(finalAGen == initialAGen + 1)
        #expect(pairingStore.currentPairing?.relayEndpoint == "https://new-relay.solstone.test")

        await owner.stop()
    }

    @Test("Real adapter: exact not_configured triggers live-disable and persists .unavailable")
    @MainActor
    func testRealAdapterNotConfiguredExact() async throws {
        let store = ObserverURLProtocolStore()
        let sessions = SessionRecorder()

        store.enqueue(statusCode: 200, body: #"{"protocol_version": 2, "status": "not_configured"}"#)

        let initialPairing = pairing(
            instanceID: "test-instance",
            deviceToken: "old-token",
            relayEndpoint: "https://old-relay.solstone.test"
        )
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)
        _ = try? credStore.load()
        let (initialPGen, _) = credStore.currentGenerations()

        let (owner, _) = makeOwnerHarness(
            store: store,
            credStore: credStore,
            initialPairing: initialPairing,
            sessions: sessions
        )

        owner.start()
        try await waitUntil { sessions.count >= 2 }
        let session1 = sessions[1]
        try await waitUntil { await session1.recordedEndpoints.count >= 1 }
        try await waitUntil { pairingStore.currentPairing?.relayEnrollment == .unavailable }

        let s1Endpoints = await session1.recordedEndpoints.last ?? []
        #expect(!s1Endpoints.contains(where: {
            if case .relay = $0 { return true }
            return false
        }))
        #expect(s1Endpoints.contains(where: {
            if case .lan = $0 { return true }
            return false
        }))

        let current = pairingStore.currentPairing
        #expect(current?.relayEnrollment == .unavailable)
        let (finalPGen, _) = credStore.currentGenerations()
        #expect(finalPGen == initialPGen)

        await owner.stop()
    }

    @Test("Real adapter: not_configured failed clear keeps live disabled and pendingDurableClear")
    @MainActor
    func testRealAdapterNotConfiguredFailedClear() async throws {
        let store = ObserverURLProtocolStore()
        let sessions = SessionRecorder()

        store.enqueue(statusCode: 200, body: #"{"protocol_version": 2, "status": "not_configured"}"#)

        let initialPairing = pairing(
            instanceID: "test-instance",
            deviceToken: "old-token",
            relayEndpoint: "https://old-relay.solstone.test"
        )
        let pairingStore = PairingStore(
            pairing: initialPairing,
            saveError: SPLKeychainError.saveFailed(status: -1)
        )
        let credStore = PairingCredentialStore(store: pairingStore)

        let (owner, _) = makeOwnerHarness(
            store: store,
            credStore: credStore,
            initialPairing: initialPairing,
            sessions: sessions
        )

        owner.start()
        try await waitUntil { sessions.count >= 2 }
        let session1 = sessions[1]
        try await waitUntil { await session1.recordedEndpoints.count >= 1 }
        try await waitUntil { owner.pendingDurableClear != nil }

        let s1Endpoints = await session1.recordedEndpoints.last ?? []
        #expect(!s1Endpoints.contains(where: {
            if case .relay = $0 { return true }
            return false
        }))

        #expect(pairingStore.currentPairing?.relayEnrollment != .unavailable)
        #expect(owner.pendingDurableClear != nil)

        await owner.stop()
    }

    @Test("Real adapter: not_configured no-LAN disconnects and state is not available")
    @MainActor
    func testRealAdapterNotConfiguredNoLAN() async throws {
        let store = ObserverURLProtocolStore()
        let sessions = SessionRecorder()

        store.enqueue(statusCode: 200, body: #"{"protocol_version": 2, "status": "not_configured"}"#)

        let initialPairing = pairing(
            instanceID: "test-instance",
            deviceToken: "old-token",
            relayEndpoint: "https://old-relay.solstone.test",
            localEndpoints: []
        )
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)

        let (owner, _) = makeOwnerHarness(
            store: store,
            credStore: credStore,
            initialPairing: initialPairing,
            sessions: sessions
        )

        owner.start()
        try await waitUntil { sessions.count >= 1 }
        try await waitUntil { owner.relayAccessStatus == .unavailable }
        try await waitUntil { owner.state == TunnelLifecycleState.disconnected }
        #expect(owner.state == TunnelLifecycleState.disconnected)

        await owner.stop()
    }

    @Test("Real adapter: extra keys on not_configured keeps cache and endpoints")
    @MainActor
    func testRealAdapterNotConfiguredExtraKeysIgnored() async throws {
        let store = ObserverURLProtocolStore()
        let sessions = SessionRecorder()

        store.enqueue(statusCode: 200, body: #"{"protocol_version": 2, "status": "not_configured", "extra": true}"#)

        let initialPairing = pairing(
            instanceID: "test-instance",
            deviceToken: "old-token",
            relayEndpoint: "https://old-relay.solstone.test"
        )
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)

        let (owner, _) = makeOwnerHarness(
            store: store,
            credStore: credStore,
            initialPairing: initialPairing,
            sessions: sessions
        )

        owner.start()
        try await waitUntil { sessions.count >= 1 }
        await store.waitForRequestCount(1, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(100))

        #expect(sessions.count == 1) // No replacement connect triggered
        #expect(pairingStore.currentPairing?.relayEnrollment != .unavailable)

        await owner.stop()
    }

    @Test("Real adapter: optional persist saveError leaves store intact and does not fail fatally")
    @MainActor
    func testRealAdapterOptionalPersistSaveErrorLeavesStoreIntact() async throws {
        let store = ObserverURLProtocolStore()
        let sessions = SessionRecorder()

        let now = Date()
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + 3600
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAtStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(exp)))

        let claims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": iat,
            "exp": exp,
            "jti": "jwt-save-err"
        ]
        let token = Self.makeJWT(claims: claims)
        let readyJson = """
        {
            "protocol_version": 2,
            "status": "ready",
            "relay_origin": "https://new-relay.solstone.test",
            "instance_id": "test-instance",
            "device_token": "\(token)",
            "expires_at": "\(expiresAtStr)"
        }
        """
        store.enqueue(statusCode: 200, body: readyJson)

        let initialPairing = pairing(
            instanceID: "test-instance",
            deviceToken: "old-token",
            relayEndpoint: "https://old-relay.solstone.test"
        )
        let pairingStore = PairingStore(
            pairing: initialPairing,
            saveError: SPLKeychainError.saveFailed(status: -1)
        )
        let credStore = PairingCredentialStore(store: pairingStore)

        let (owner, _) = makeOwnerHarness(
            store: store,
            credStore: credStore,
            initialPairing: initialPairing,
            sessions: sessions
        )

        owner.start()
        try await waitUntil { sessions.count >= 1 }
        await store.waitForRequestCount(1, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(100))

        #expect(sessions.count == 1) // No replacement connect since save failed
        #expect(pairingStore.currentPairing?.relayEndpoint == "https://old-relay.solstone.test")

        await owner.stop()
    }

    @Test("Real adapter: iat at skew boundary (now + 60s) is accepted")
    @MainActor
    func testRealAdapterIatAtSkewBoundaryAccepted() async throws {
        let now = Date()
        let nowUnix = Int(now.timeIntervalSince1970)
        let exp = nowUnix + 3600
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAtStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(exp)))

        let validSkewClaims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": nowUnix + 60, // exactly the +60s skew window boundary
            "exp": exp,
            "jti": "jwt-skew-ok"
        ]
        let validSkewToken = Self.makeJWT(claims: validSkewClaims)
        let validJson = """
        {
            "protocol_version": 2,
            "status": "ready",
            "relay_origin": "https://new-relay.solstone.test",
            "instance_id": "test-instance",
            "device_token": "\(validSkewToken)",
            "expires_at": "\(expiresAtStr)"
        }
        """
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 200, body: validJson)
        let sessions = SessionRecorder()
        let initialPairing = pairing(instanceID: "test-instance", deviceToken: "old-token", relayEndpoint: "https://old-relay.solstone.test")
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)
        let (owner, _) = makeOwnerHarness(store: store, credStore: credStore, initialPairing: initialPairing, sessions: sessions, now: { now })
        let initialAGen = credStore.accessMutationGeneration

        owner.start()
        try await waitUntil { sessions.count >= 2 }
        #expect(pairingStore.currentPairing?.relayEndpoint == "https://new-relay.solstone.test")
        #expect(credStore.accessMutationGeneration == initialAGen + 1)
        await owner.stop()
    }

    @Test("Real adapter: iat just beyond skew boundary (now + 61s) is rejected")
    @MainActor
    func testRealAdapterIatBeyondSkewBoundaryRejected() async throws {
        let now = Date()
        let nowUnix = Int(now.timeIntervalSince1970)
        let exp = nowUnix + 3600
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAtStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(exp)))

        let futureClaims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": nowUnix + 61, // just beyond the +60s skew window
            "exp": exp,
            "jti": "jwt-future"
        ]
        let futureToken = Self.makeJWT(claims: futureClaims)
        let futureJson = """
        {
            "protocol_version": 2,
            "status": "ready",
            "relay_origin": "https://new-relay.solstone.test",
            "instance_id": "test-instance",
            "device_token": "\(futureToken)",
            "expires_at": "\(expiresAtStr)"
        }
        """
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 200, body: futureJson)
        let sessions = SessionRecorder()
        let initialPairing = pairing(instanceID: "test-instance", deviceToken: "old-token", relayEndpoint: "https://old-relay.solstone.test")
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)
        let (owner, _) = makeOwnerHarness(store: store, credStore: credStore, initialPairing: initialPairing, sessions: sessions, now: { now })
        let initialAGen = credStore.accessMutationGeneration

        owner.start()
        try await waitUntil { sessions.count >= 1 }
        await store.waitForRequestCount(1, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(sessions.count == 1) // Unchanged
        #expect(pairingStore.currentPairing?.relayEndpoint == "https://old-relay.solstone.test")
        #expect(credStore.accessMutationGeneration == initialAGen)
        await owner.stop()
    }

    @Test("Real adapter: malformed JWT claims, empty segments, and expiry mismatch rejected")
    @MainActor
    func testRealAdapterMalformedJWTAndExpiryMismatchRejected() async throws {
        let now = Date()
        let nowUnix = Int(now.timeIntervalSince1970)
        let exp = nowUnix + 3600
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAtStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(exp)))

        let baseClaims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": nowUnix,
            "exp": exp,
            "jti": "jwt-valid"
        ]

        var malformedTokens: [String] = []
        // Boolean iat
        var c1 = baseClaims; c1["iat"] = true; malformedTokens.append(Self.makeJWT(claims: c1))
        // Fraction iat
        var c2 = baseClaims; c2["iat"] = Double(nowUnix) + 0.5; malformedTokens.append(Self.makeJWT(claims: c2))
        // Fraction exp
        var c3 = baseClaims; c3["exp"] = Double(exp) + 0.5; malformedTokens.append(Self.makeJWT(claims: c3))
        // Empty jti
        var c4 = baseClaims; c4["jti"] = ""; malformedTokens.append(Self.makeJWT(claims: c4))
        // Empty segment / invalid JWT format
        malformedTokens.append("eyJhbGciOiJub25lIn0..signature")

        for token in malformedTokens {
            let malformedJson = """
            {
                "protocol_version": 2,
                "status": "ready",
                "relay_origin": "https://new-relay.solstone.test",
                "instance_id": "test-instance",
                "device_token": "\(token)",
                "expires_at": "\(expiresAtStr)"
            }
            """
            let store = ObserverURLProtocolStore()
            store.enqueue(statusCode: 200, body: malformedJson)
            let sessions = SessionRecorder()
            let initialPairing = pairing(instanceID: "test-instance", deviceToken: "old-token", relayEndpoint: "https://old-relay.solstone.test")
            let pStore = PairingStore(pairing: initialPairing)
            let cStore = PairingCredentialStore(store: pStore)
            let (owner, _) = makeOwnerHarness(store: store, credStore: cStore, initialPairing: initialPairing, sessions: sessions)
            let initialAGen = cStore.accessMutationGeneration
            owner.start()
            try await waitUntil { sessions.count >= 1 }
            await store.waitForRequestCount(1, timeout: .seconds(2))
            try await Task.sleep(for: .milliseconds(50))
            #expect(sessions.count == 1)
            #expect(pStore.currentPairing?.relayEndpoint == "https://old-relay.solstone.test")
            #expect(cStore.accessMutationGeneration == initialAGen)
            await owner.stop()
        }

        // RFC3339 expiry mismatch vs JWT exp
        let validToken = Self.makeJWT(claims: baseClaims)
        let mismatchExpiryJson = """
        {
            "protocol_version": 2,
            "status": "ready",
            "relay_origin": "https://new-relay.solstone.test",
            "instance_id": "test-instance",
            "device_token": "\(validToken)",
            "expires_at": "2030-01-01T00:00:00Z"
        }
        """
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 200, body: mismatchExpiryJson)
        let sessions = SessionRecorder()
        let initialPairing = pairing(instanceID: "test-instance", deviceToken: "old-token", relayEndpoint: "https://old-relay.solstone.test")
        let pStore = PairingStore(pairing: initialPairing)
        let cStore = PairingCredentialStore(store: pStore)
        let (owner, _) = makeOwnerHarness(store: store, credStore: cStore, initialPairing: initialPairing, sessions: sessions)
        let initialAGen = cStore.accessMutationGeneration
        owner.start()
        try await waitUntil { sessions.count >= 1 }
        await store.waitForRequestCount(1, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(sessions.count == 1)
        #expect(pStore.currentPairing?.relayEndpoint == "https://old-relay.solstone.test")
        #expect(cStore.accessMutationGeneration == initialAGen)
        await owner.stop()
    }

    @Test("Real adapter: invalid relay origins are rejected")
    @MainActor
    func testRealAdapterInvalidOriginsRejected() async throws {
        let now = Date()
        let nowUnix = Int(now.timeIntervalSince1970)
        let exp = nowUnix + 3600
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAtStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(exp)))

        let claims: [String: Any] = [
            "iss": "sol-relay",
            "sub": "instance:test-instance",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": "test-instance",
            "iat": nowUnix,
            "exp": exp,
            "jti": "jwt-valid"
        ]
        let token = Self.makeJWT(claims: claims)

        let invalidOrigins = [
            "http://relay.solstone.test",
            "https://user:pass@relay.solstone.test",
            "https://relay.solstone.test/path",
            "https://relay.solstone.test?query=1",
            "https://relay.solstone.test#frag"
        ]
        for origin in invalidOrigins {
            let invalidOriginJson = """
            {
                "protocol_version": 2,
                "status": "ready",
                "relay_origin": "\(origin)",
                "instance_id": "test-instance",
                "device_token": "\(token)",
                "expires_at": "\(expiresAtStr)"
            }
            """
            let store = ObserverURLProtocolStore()
            store.enqueue(statusCode: 200, body: invalidOriginJson)
            let sessions = SessionRecorder()
            let initialPairing = pairing(instanceID: "test-instance", deviceToken: "old-token", relayEndpoint: "https://old-relay.solstone.test")
            let pStore = PairingStore(pairing: initialPairing)
            let cStore = PairingCredentialStore(store: pStore)
            let (owner, _) = makeOwnerHarness(store: store, credStore: cStore, initialPairing: initialPairing, sessions: sessions)
            owner.start()
            try await waitUntil { sessions.count >= 1 }
            await store.waitForRequestCount(1, timeout: .seconds(2))
            try await Task.sleep(for: .milliseconds(50))
            #expect(sessions.count == 1)
            #expect(pStore.currentPairing?.relayEndpoint == "https://old-relay.solstone.test")
            await owner.stop()
        }
    }

    @Test("Thin helper: RelayAccessValidation.normalizedOrigin HTTPS-only")
    func testNormalizedOriginDirect() throws {
        #expect(try RelayAccessValidation.normalizedOrigin(URL(string: "https://relay.solstone.test")!).absoluteString == "https://relay.solstone.test")
        #expect(try RelayAccessValidation.normalizedOrigin(URL(string: "https://relay.solstone.test:443")!).absoluteString == "https://relay.solstone.test")
        #expect(try RelayAccessValidation.normalizedOrigin(URL(string: "https://relay.solstone.test:8443")!).absoluteString == "https://relay.solstone.test:8443")

        for invalid in ["http://relay.solstone.test", "https://user:pass@relay.solstone.test", "https://relay.solstone.test/path", "https://relay.solstone.test?query=1", "https://relay.solstone.test#frag"] {
            let url = try #require(URL(string: invalid))
            #expect(throws: (any Error).self) {
                try RelayAccessValidation.normalizedOrigin(url)
            }
        }
    }

    @Test("Thin helper: validateV2Token iat at boundary vs beyond")
    func testValidateV2TokenDirect() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let exp = 5000
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expiresAt = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(exp)))

        let token60 = Self.makeJWT(claims: [
            "iss": "sol-relay", "sub": "instance:test-instance", "aud": "spl-relay",
            "scope": "session.dial", "ver": 2, "instance_id": "test-instance",
            "iat": 1060, "exp": exp, "jti": "jti-60"
        ])
        try RelayAccessValidation.validateV2Token(token60, expectedInstanceID: "test-instance", expiresAt: expiresAt, now: now)

        let token61 = Self.makeJWT(claims: [
            "iss": "sol-relay", "sub": "instance:test-instance", "aud": "spl-relay",
            "scope": "session.dial", "ver": 2, "instance_id": "test-instance",
            "iat": 1061, "exp": exp, "jti": "jti-61"
        ])
        #expect(throws: (any Error).self) {
            try RelayAccessValidation.validateV2Token(token61, expectedInstanceID: "test-instance", expiresAt: expiresAt, now: now)
        }
    }
}


extension JournalRelayAccessTests {
    private static var actualMetadataBody: String {
        #"{"protocol_version":1,"revision":1,"reported":null,"owner_label":null,"display_label":"Test Mac","updated_at":null,"journal":{"name":"Test Journal","version":"1.0"}}"#
    }

    private static func freshReadyBody(instanceID: String = "test-instance") -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let expiry = timestamp + 3600
        let token = makeJWT(claims: [
            "iss": "independent-issuer", "sub": "instance:\(instanceID)", "aud": "spl-relay",
            "scope": "session.dial", "ver": 2, "instance_id": instanceID,
            "iat": timestamp, "exp": expiry, "jti": UUID().uuidString
        ])
        return String(data: makeReadyJSON(
            relayOrigin: "https://new-relay.solstone.test", instanceID: instanceID,
            deviceToken: token, expiresAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(expiry)))
        ), encoding: .utf8)!
    }

    @Test("Healthy responses settle across real supervisor replacement, then external reconnect starts another burst")
    @MainActor
    func healthyRealSupervisorBurstSettles() async throws {
        let http = ObserverURLProtocolStore()
        http.registerRoute(path: "/app/network/api/relay/access", body: Self.freshReadyBody())
        http.registerRoute(path: "/app/network/api/clients/self", body: Self.actualMetadataBody)
        let initial = pairing(instanceID: "test-instance", deviceToken: "old-token")
        let disk = PairingStore(pairing: initial)
        let credentials = PairingCredentialStore(store: disk)
        let supervisors = ActualSupervisorRecorder()
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: { SPLTunnelTransport(makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }) },
            pathMonitoringSource: NoopPathMonitoringSource(), probe: { _, _ in true },
            loopbackSession: makeTestSession(store: http)
        )
        owner.start()
        do { try await waitUntil { supervisors.count >= 3 } } catch {
            Issue.record("initial burst supervisors=\(supervisors.count) children=\(supervisors.children.count) requests=\(http.snapshotRequests().map { $0.url?.path ?? "?" }) state=\(owner.state)")
            await owner.stop()
            throw error
        }
        try await waitUntil {
            let accessBusy = await owner.relayAccessSequencer.isBusy
            let metadataBusy = await owner.clientSelfSequencer.isBusy
            return !accessBusy && !metadataBusy
        }
        let firstCount = http.snapshotRequests().count
        try await Task.sleep(for: .milliseconds(150))
        #expect(http.snapshotRequests().count == firstCount)
        #expect(supervisors.count == 3)
        #expect(http.snapshotRequests().filter { $0.url?.path.hasSuffix("/relay/access") == true }.count == 2)
        let retiredChildCount = supervisors.children.count
        await supervisors[0].requestReconnect()
        try await Task.sleep(for: .milliseconds(50))
        #expect(supervisors.children.count == retiredChildCount)
        await supervisors[2].requestReconnect()
        do { try await waitUntil { supervisors.count >= 5 } } catch {
            Issue.record("external burst supervisors=\(supervisors.count) children=\(supervisors.children.count) requests=\(http.snapshotRequests().map { $0.url?.path ?? "?" }) state=\(owner.state)")
            await owner.stop()
            throw error
        }
        try await waitUntil {
            let accessBusy = await owner.relayAccessSequencer.isBusy
            let metadataBusy = await owner.clientSelfSequencer.isBusy
            return !accessBusy && !metadataBusy
        }
        #expect(supervisors.count == 5)
        for child in supervisors.children.sessions.dropFirst() {
            #expect(child.pairing?.clientCertPEM == initial.clientCertPEM)
            #expect(child.pairing?.relayEndpoint == "https://new-relay.solstone.test")
        }
        await owner.stop()
    }

    @Test("Disable retires the real supervisor before a blocked LAN candidate, even when durable clear fails", arguments: [false, true])
    @MainActor
    func disableRetiresBeforeBlockedLAN(clearFails: Bool) async throws {
        let http = ObserverURLProtocolStore()
        http.registerRoute(path: "/app/network/api/relay/access", body: #"{"protocol_version":2,"status":"not_configured"}"#)
        http.registerRoute(path: "/app/network/api/clients/self", body: Self.actualMetadataBody)
        let initial = pairing(instanceID: "test-instance", deviceToken: "old-token")
        let disk = PairingStore(pairing: initial, saveError: clearFails ? SPLKeychainError.saveFailed(status: -1) : nil)
        let credentials = PairingCredentialStore(store: disk)
        let supervisors = ActualSupervisorRecorder()
        let first = SPLTunnelTransport(makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) })
        let candidate = FakeTunnelTransport(connectionMode: .plDirect, connection: .init(localPort: 29991, via: .lan))
        candidate.armConnectGate()
        let factory = FakeTransportFactory([first, candidate])
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials, tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: factory.make, pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }, loopbackSession: makeTestSession(store: http),
            optionalJobDeadline: .seconds(1)
        )
        owner.start()
        try await waitUntil { candidate.pendingConnectCount == 1 }
        #expect(await supervisors.children[0].isDisconnected)
        await supervisors[0].requestReconnect()
        try await Task.sleep(for: .milliseconds(30))
        #expect(supervisors.children.count == 1)
        #expect(!owner.liveRelayEligible)
        #expect(clearFails ? owner.pendingDurableClear != nil : disk.currentPairing?.relayEnrollment == .unavailable)
        try await waitUntil { !(await owner.relayAccessSequencer.isBusy) }
        #expect(owner.localPort == nil)
        candidate.releaseNextConnect()
        try await waitUntil { candidate.connectInFlight == 0 && candidate.disconnectCount >= 1 }
        #expect(owner.localPort == nil)
        await owner.stop()
    }

    @Test("Stale refresh success and terminal failure cannot replace a newer HTTP Ready", arguments: [false, true], [false, true])
    @MainActor
    func staleRefreshCannotReplaceReady(proactive: Bool, terminalFailure: Bool) async throws {
        try await checkStaleRefresh(proactive: proactive, terminalFailure: terminalFailure, disable: false)
    }

    @Test("Stale refresh success and terminal failure cannot undo an HTTP disable", arguments: [false, true], [false, true])
    @MainActor
    func staleRefreshCannotUndoDisable(proactive: Bool, terminalFailure: Bool) async throws {
        try await checkStaleRefresh(proactive: proactive, terminalFailure: terminalFailure, disable: true)
    }

    @MainActor
    private func checkStaleRefresh(proactive: Bool, terminalFailure: Bool, disable: Bool) async throws {
        let http = ObserverURLProtocolStore()
        let reply = AccessHTTPReplyBarrier()
        defer { reply.release() }
        http.registerRoute(path: "/app/network/api/relay/access",
            body: disable ? #"{"protocol_version":2,"status":"not_configured"}"# : Self.freshReadyBody(),
            beforeReply: { reply.wait() })
        http.registerRoute(path: "/app/network/api/clients/self", body: Self.actualMetadataBody)
        let initial = pairing(instanceID: "test-instance", deviceToken: "old-token")
        let disk = PairingStore(pairing: initial)
        let credentials = PairingCredentialStore(store: disk)
        let barrier = AccessRefreshBarrier()
        let refresher = TunnelDeviceTokenRefreshing(
            refreshIfNeeded: { pairing, _ in proactive ? await barrier.wait() : .notNeeded(pairing) },
            refreshNow: { _ in await barrier.wait() }
        )
        let first = FakeTunnelTransport(connection: .init(localPort: 29992, via: .relay))
        let replacement = FakeTunnelTransport(connection: .init(localPort: 29993, via: .relay))
        let third = FakeTunnelTransport(connection: .init(localPort: 29994, via: .relay))
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials, tokenRefresher: refresher,
            makeTransport: FakeTransportFactory([first, replacement, third]).make,
            pathMonitoringSource: NoopPathMonitoringSource(), probe: { _, _ in true },
            loopbackSession: makeTestSession(store: http)
        )
        owner.start()
        if !proactive {
            try await waitUntil { owner.localPort != nil }
            first.emit(.failed(.authRefreshRequired))
        }
        try await waitUntil { await barrier.entered }
        reply.release()
        let revisions = credentials.currentGenerations()
        await owner.relayAccessSequencer.enqueue(target: .init(
            localPort: 29995, instanceID: initial.instanceID,
            pairingGeneration: revisions.pairingGeneration, accessMutationGeneration: revisions.accessMutationGeneration
        ))
        try await waitUntil {
            disable ? disk.currentPairing?.relayEnrollment == .unavailable : disk.currentPairing?.relayEndpoint == "https://new-relay.solstone.test"
        }
        await barrier.release(terminalFailure ? .definitiveAuthFailure : .refreshed(initial))
        try await waitUntil { await barrier.completed }
        try await waitUntil { !(await owner.relayAccessSequencer.isBusy) }
        #expect(disk.deleteCount == 0)
        #expect(disable ? disk.currentPairing?.relayEnrollment == .unavailable : disk.currentPairing?.relayEndpoint == "https://new-relay.solstone.test")
        #expect(owner.state != .error(.revoked))
        await owner.stop()
    }
}

extension JournalRelayAccessTests {
    @Test("Late production access delivery cannot cross unpair or same-home repair", arguments: [false, true], [false, true])
    @MainActor
    func lateHTTPOutcomeCannotCrossPairing(unpair: Bool, disable: Bool) async throws {
        let http = ObserverURLProtocolStore()
        let reply = AccessHTTPReplyBarrier()
        defer { reply.release() }
        http.registerRoute(matching: { $0.url?.port == 29996 && $0.url?.path.hasSuffix("/relay/access") == true },
            body: disable ? #"{"protocol_version":2,"status":"not_configured"}"# : Self.freshReadyBody(),
            beforeReply: { reply.wait() })
        http.registerRoute(path: "/app/network/api/clients/self", body: Self.actualMetadataBody)
        let initial = pairing(instanceID: "test-instance", deviceToken: "old-token")
        let successor = pairing(instanceID: "test-instance", deviceToken: "replacement-token", relayEndpoint: "https://replacement.solstone.test")
        let disk = PairingStore(pairing: initial)
        let credentials = PairingCredentialStore(store: disk)
        let first = FakeTunnelTransport(connection: .init(localPort: 29996, via: .relay))
        let replacement = FakeTunnelTransport(connection: .init(localPort: 29997, via: .relay))
        let owner = TunnelLifecycleOwner(credentialStore: credentials, tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: FakeTransportFactory([first, replacement]).make,
            pathMonitoringSource: NoopPathMonitoringSource(), probe: { _, _ in true },
            loopbackSession: makeTestSession(store: http))
        owner.start()
        try await waitUntil { reply.entered }
        if unpair { try credentials.delete() } else { try credentials.save(successor) }
        await owner.reevaluatePairing()
        try await waitUntil { unpair ? owner.localPort == nil : owner.localPort == 29997 }
        reply.release()
        try await waitUntil { !(await owner.relayAccessSequencer.isBusy) }
        #expect(disk.currentPairing == (unpair ? nil : successor))
        #expect(unpair ? owner.localPort == nil : owner.localPort == 29997)
        #expect(replacement.disconnectCount == 0)
        await owner.stop()
    }

    @Test("Late candidate success or failure cannot replace a newer pairing", arguments: [false, true])
    @MainActor
    func lateCandidateCannotCrossPairing(fails: Bool) async throws {
        let http = ObserverURLProtocolStore()
        http.registerRoute(matching: { $0.url?.port == 29998 && $0.url?.path.hasSuffix("/relay/access") == true }, body: Self.freshReadyBody())
        http.registerRoute(path: "/app/network/api/clients/self", body: Self.actualMetadataBody)
        let initial = pairing(instanceID: "test-instance", deviceToken: "old-token")
        let successor = pairing(instanceID: "test-instance", deviceToken: "replacement-token")
        let disk = PairingStore(pairing: initial)
        let credentials = PairingCredentialStore(store: disk)
        let first = FakeTunnelTransport(connection: .init(localPort: 29998, via: .relay))
        let blocked = FakeTunnelTransport(results: [fails ? .failure(SessionError.revoked) : .success(.init(localPort: 29999, via: .relay))])
        blocked.armConnectGate()
        let replacement = FakeTunnelTransport(connection: .init(localPort: 30000, via: .relay))
        let owner = TunnelLifecycleOwner(credentialStore: credentials, tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: FakeTransportFactory([first, blocked, replacement]).make,
            pathMonitoringSource: NoopPathMonitoringSource(), probe: { _, _ in true },
            loopbackSession: makeTestSession(store: http))
        owner.start()
        try await waitUntil { blocked.pendingConnectCount == 1 }
        try credentials.save(successor)
        await owner.reevaluatePairing()
        try await waitUntil { owner.localPort == 30000 }
        blocked.releaseNextConnect()
        try await waitUntil { !(await owner.relayAccessSequencer.isBusy) }
        #expect(disk.currentPairing == successor)
        #expect(disk.deleteCount == 0)
        #expect(blocked.disconnectCount >= 1)
        #expect(replacement.disconnectCount == 0)
        #expect(owner.localPort == 30000)
        await owner.stop()
    }
}


extension JournalRelayAccessTests {
    @Test("Retired production adapter cannot publish a late session connection", arguments: [false, true])
    @MainActor
    func retiredAdapterDropsLateConnection(fails: Bool) async throws {
        let session = FakeTunnelReconnectingSession(shouldThrowOnConnect: fails ? SessionError.revoked : nil)
        await session.armConnectGate()
        let transport = SPLTunnelTransport(makeSession: { _, _, _ in session })
        let stored = pairing()
        let attempt = Task { try await transport.connect(pairing: stored, candidates: TransportEndpoint.candidates(for: stored)) }
        try await waitUntil { await session.pendingConnectCount == 1 }
        await transport.disconnect()
        await session.releaseNextConnect()
        do {
            _ = try await attempt.value
            Issue.record("retired adapter published a loopback connection")
        } catch {}
        #expect(transport.connectionMode == nil)
        await transport.requestReconnect()
        #expect(await session.requestReconnectCount == 0)
        #expect(await session.disconnectCallCount >= 1)
    }

    @Test("Invalid journal text cannot partially mutate a complete metadata resource")
    func invalidJournalTextRejectsResource() throws {
        let resource = try #require(JSONSerialization.jsonObject(with: Data(Self.actualMetadataBody.utf8)) as? [String: Any])
        #expect(ClientSelfProtocol1Validator.decode(Data(Self.actualMetadataBody.utf8)) != nil)
        for journal in [["name": "valid", "version": "\u{0001}"], ["name": "bad\u{0001}", "version": "1.0"]] {
            var invalid = resource
            invalid["journal"] = journal
            let bytes = try JSONSerialization.data(withJSONObject: invalid)
            #expect(ClientSelfProtocol1Validator.decode(bytes) == nil)
        }
    }
}
