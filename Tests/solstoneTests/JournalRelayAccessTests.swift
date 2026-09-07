// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SPLTunnel
import Testing
@testable import solstone

@Suite("Journal Relay Access Tests")
struct JournalRelayAccessTests {
    private static func makeJWT(
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

    @Test("Valid ready response succeeds")
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

        let validated = try JournalRelayAccessValidator.validateReadyResponse(
            protocolVersion: 2,
            status: "ready",
            relayOrigin: "https://relay.solstone.test",
            instanceID: "test-instance",
            deviceToken: token,
            expiresAtString: "2023-11-14T23:13:20Z", // matches 1700003600
            pairedInstanceID: "test-instance",
            now: now
        )

        #expect(validated.instanceID == "test-instance")
        #expect(validated.relayOrigin == "https://relay.solstone.test")
        #expect(validated.deviceToken == token)
    }

    @Test("Protocol version mismatch throws")
    func testProtocolVersionMismatch() throws {
        #expect(throws: JournalRelayAccessValidationError.invalidProtocolVersion) {
            _ = try JournalRelayAccessValidator.validateReadyResponse(
                protocolVersion: 1,
                status: "ready",
                relayOrigin: "https://relay.solstone.test",
                instanceID: "test-instance",
                deviceToken: "tok",
                expiresAtString: "2023-11-14T23:13:20Z",
                pairedInstanceID: "test-instance"
            )
        }
    }

    @Test("Instance mismatch throws")
    func testInstanceMismatch() throws {
        #expect(throws: JournalRelayAccessValidationError.instanceMismatch) {
            _ = try JournalRelayAccessValidator.validateReadyResponse(
                protocolVersion: 2,
                status: "ready",
                relayOrigin: "https://relay.solstone.test",
                instanceID: "different-instance",
                deviceToken: "tok",
                expiresAtString: "2023-11-14T23:13:20Z",
                pairedInstanceID: "test-instance"
            )
        }
    }

    @Test("Invalid relay origin throws")
    func testInvalidRelayOrigin() throws {
        let origins = ["http://relay.solstone.test", "ftp://relay", "https://", "", "not-a-url"]
        for origin in origins {
            #expect(throws: JournalRelayAccessValidationError.invalidRelayOrigin) {
                _ = try JournalRelayAccessValidator.validateReadyResponse(
                    protocolVersion: 2,
                    status: "ready",
                    relayOrigin: origin,
                    instanceID: "test-instance",
                    deviceToken: "tok",
                    expiresAtString: "2023-11-14T23:13:20Z",
                    pairedInstanceID: "test-instance"
                )
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

        #expect(throws: JournalRelayAccessValidationError.unexpectedJWTClaims) {
            _ = try JournalRelayAccessValidator.validateReadyResponse(
                protocolVersion: 2,
                status: "ready",
                relayOrigin: "https://relay.solstone.test",
                instanceID: "test-instance",
                deviceToken: token,
                expiresAtString: "2023-11-14T23:13:20Z",
                pairedInstanceID: "test-instance",
                now: now
            )
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

        #expect(throws: JournalRelayAccessValidationError.expiredOrUnusable) {
            _ = try JournalRelayAccessValidator.validateReadyResponse(
                protocolVersion: 2,
                status: "ready",
                relayOrigin: "https://relay.solstone.test",
                instanceID: "test-instance",
                deviceToken: token,
                expiresAtString: "2023-11-14T23:13:20Z",
                pairedInstanceID: "test-instance",
                now: now
            )
        }
    }

    private func makeTestSession(store: ObserverURLProtocolStore) -> URLSession {
        let config = observerURLProtocolConfiguration(store: store)
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: JournalVersionRedirectDelegate(), delegateQueue: nil)
    }

    @Test("Real adapter: exact not_configured triggers live-disable and persists .unavailable")
    func testRealAdapterNotConfiguredExact() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        // Exact not_configured wire contract
        store.enqueue(statusCode: 200, body: #"{"protocol_version": 2, "status": "not_configured"}"#)

        let initialPairing = pairing(instanceID: "test-instance")
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)

        final class OutcomeBox: @unchecked Sendable {
            var outcomes: [JournalRelayAccessSequencer.AccessUpdateOutcome] = []
        }
        let box = OutcomeBox()

        let sequencer = JournalRelayAccessSequencer(
            credentialStore: credStore,
            session: session,
            onOutcome: { outcome in
                box.outcomes.append(outcome)
            }
        )

        let (pGen, aGen) = credStore.currentGenerations()
        let target = JournalRelayAccessSequencer.TargetConnection(
            localPort: 9999,
            instanceID: "test-instance",
            pairingGeneration: pGen,
            accessMutationGeneration: aGen
        )

        await sequencer.enqueue(target: target)
        await store.waitForRequestCount(1, timeout: .seconds(2))
        for _ in 0..<50 {
            if await !sequencer.isBusy && box.outcomes.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(box.outcomes.count == 2)
        if case .notConfiguredLiveDisabled = box.outcomes.first {
            // First outcome is live disable
        } else {
            Issue.record("Expected first outcome to be .notConfiguredLiveDisabled")
        }

        if box.outcomes.count > 1, case .durableClearPersisted = box.outcomes[1] {
            // Second outcome is durableClearPersisted
        } else {
            Issue.record("Expected second outcome to be .durableClearPersisted")
        }

        let current = pairingStore.currentPairing
        #expect(current?.relayEnrollment == .unavailable)
        #expect(current?.localEndpoints.count == 1) // LAN preserved
    }

    @Test("Real adapter: extra keys on not_configured keeps cache")
    func testRealAdapterNotConfiguredExtraKeysIgnored() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        // Malformed with extra keys
        store.enqueue(statusCode: 200, body: #"{"protocol_version": 2, "status": "not_configured", "extra": true}"#)

        let initialPairing = pairing(instanceID: "test-instance")
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)

        final class OutcomeBox: @unchecked Sendable {
            var outcomes: [JournalRelayAccessSequencer.AccessUpdateOutcome] = []
        }
        let box = OutcomeBox()

        let sequencer = JournalRelayAccessSequencer(
            credentialStore: credStore,
            session: session,
            onOutcome: { outcome in
                box.outcomes.append(outcome)
            }
        )

        let (pGen, aGen) = credStore.currentGenerations()
        let target = JournalRelayAccessSequencer.TargetConnection(
            localPort: 9999,
            instanceID: "test-instance",
            pairingGeneration: pGen,
            accessMutationGeneration: aGen
        )

        await sequencer.enqueue(target: target)
        await store.waitForRequestCount(1, timeout: .seconds(2))
        for _ in 0..<50 {
            if await !sequencer.isBusy { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(box.outcomes.isEmpty)
        let current = pairingStore.currentPairing
        #expect(current?.relayEnrollment != .unavailable) // Cache preserved
    }

    @Test("Real adapter: ready persists new origin/token and replaceLiveTransport connects on new transport")
    @MainActor
    func testRealAdapterReadyPersistsAndReplacesLiveTransport() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

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

        final class OutcomeBox: @unchecked Sendable {
            var outcomes: [JournalRelayAccessSequencer.AccessUpdateOutcome] = []
        }
        let box = OutcomeBox()

        let sequencer = JournalRelayAccessSequencer(
            credentialStore: credStore,
            session: session,
            onOutcome: { outcome in
                box.outcomes.append(outcome)
            }
        )

        let (pGen, aGen) = credStore.currentGenerations()
        let target = JournalRelayAccessSequencer.TargetConnection(
            localPort: 9999,
            instanceID: "test-instance",
            pairingGeneration: pGen,
            accessMutationGeneration: aGen
        )

        await sequencer.enqueue(target: target)
        await store.waitForRequestCount(1, timeout: .seconds(2))
        for _ in 0..<50 {
            if await !sequencer.isBusy && !box.outcomes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(box.outcomes.count == 1)
        guard case .ready(let updatedPairing) = box.outcomes.first else {
            Issue.record("Expected .ready outcome")
            return
        }

        #expect(updatedPairing.relayEndpoint == "https://new-relay.solstone.test")
        if case .enrolled(let devTok, _) = updatedPairing.relayEnrollment {
            #expect(devTok == token)
        } else {
            Issue.record("Expected .enrolled relayEnrollment")
        }
        #expect(pairingStore.currentPairing?.relayEndpoint == "https://new-relay.solstone.test")

        // Test replacement connect on owner
        let transport1 = FakeTunnelTransport(connection: .init(localPort: 11111, via: .relay))
        let transport2 = FakeTunnelTransport(connection: .init(localPort: 22222, via: .relay))
        let owner = TunnelLifecycleOwner(
            credentialStore: credStore,
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(updatedPairing)]).seam,
            makeTransport: FakeTransportFactory([transport1, transport2]).make,
            pathMonitoringSource: NoopPathMonitoringSource()
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 11111, via: .relay) }

        await owner.replaceLiveTransport(with: updatedPairing)
        try await waitUntil { owner.state == .connected(localPort: 22222, via: .relay) }

        #expect(transport1.disconnectCount >= 1)
        #expect(transport1.requestReconnectCount == 0) // Not reconnecting old transport
        #expect(transport2.connectAttempts == 1)
        #expect(transport2.connectedPairings.last?.relayEndpoint == "https://new-relay.solstone.test")
        if case .enrolled(let devTok, _) = transport2.connectedPairings.last?.relayEnrollment {
            #expect(devTok == token)
        } else {
            Issue.record("Expected .enrolled relayEnrollment on connected pairing")
        }

        await owner.stop()
    }

    @Test("Real adapter: optional persist saveError leaves store intact and does not fail fatally")
    func testRealAdapterOptionalPersistSaveErrorLeavesStoreIntact() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

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

        final class OutcomeBox: @unchecked Sendable {
            var outcomes: [JournalRelayAccessSequencer.AccessUpdateOutcome] = []
        }
        let box = OutcomeBox()

        let sequencer = JournalRelayAccessSequencer(
            credentialStore: credStore,
            session: session,
            onOutcome: { outcome in
                box.outcomes.append(outcome)
            }
        )

        let (pGen, aGen) = credStore.currentGenerations()
        let target = JournalRelayAccessSequencer.TargetConnection(
            localPort: 9999,
            instanceID: "test-instance",
            pairingGeneration: pGen,
            accessMutationGeneration: aGen
        )

        await sequencer.enqueue(target: target)
        await store.waitForRequestCount(1, timeout: .seconds(2))
        for _ in 0..<50 {
            if await !sequencer.isBusy { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(box.outcomes.isEmpty)
        #expect(pairingStore.currentPairing?.relayEndpoint == "https://old-relay.solstone.test")
    }
}
