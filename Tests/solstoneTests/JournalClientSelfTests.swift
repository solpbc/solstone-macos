// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SPLTunnel
import Testing
@testable import solstone

@Suite("Journal Client Self Tests")
struct JournalClientSelfTests {
    private func makeTestSession(store: ObserverURLProtocolStore) -> URLSession {
        let config = observerURLProtocolConfiguration(store: store)
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: JournalVersionRedirectDelegate(), delegateQueue: nil)
    }

    @Test("Snapshot field sanitization: UTF-8 byte boundary, control chars, whitespace")
    func testSnapshotFieldSanitization() {
        // Name limit: 80 bytes
        let validName = "My Mac"
        #expect(ClientSelfReportedSnapshot.sanitizeField(validName, maxBytes: 80) == "My Mac")

        let whitespaceName = "   My Mac   "
        #expect(ClientSelfReportedSnapshot.sanitizeField(whitespaceName, maxBytes: 80) == "My Mac")

        let controlCharName = "My\u{0000}Mac"
        #expect(ClientSelfReportedSnapshot.sanitizeField(controlCharName, maxBytes: 80) == nil)

        let newlineName = "My\nMac"
        #expect(ClientSelfReportedSnapshot.sanitizeField(newlineName, maxBytes: 80) == nil)

        // 80 'a's vs 81 'a's
        let exact80 = String(repeating: "a", count: 80)
        let over80 = String(repeating: "a", count: 81)
        #expect(ClientSelfReportedSnapshot.sanitizeField(exact80, maxBytes: 80) == exact80)
        #expect(ClientSelfReportedSnapshot.sanitizeField(over80, maxBytes: 80) == nil)

        // Non-ASCII UTF-8 multibyte characters (e.g. '€' is 3 bytes)
        let twentySevenEuros = String(repeating: "€", count: 27) // 81 bytes
        #expect(ClientSelfReportedSnapshot.sanitizeField(twentySevenEuros, maxBytes: 80) == nil)
        let twentySixEuros = String(repeating: "€", count: 26) // 78 bytes
        #expect(ClientSelfReportedSnapshot.sanitizeField(twentySixEuros, maxBytes: 80) == twentySixEuros)

        // Multibyte 41 'é' is 82 bytes (each é is 2 bytes)
        let fortyOneE = String(repeating: "é", count: 41)
        #expect(ClientSelfReportedSnapshot.sanitizeField(fortyOneE, maxBytes: 80) == nil)

        // Other fields limit: 64 bytes
        let exact64 = String(repeating: "b", count: 64)
        let over64 = String(repeating: "b", count: 65)
        #expect(ClientSelfReportedSnapshot.sanitizeField(exact64, maxBytes: 64) == exact64)
        #expect(ClientSelfReportedSnapshot.sanitizeField(over64, maxBytes: 64) == nil)
    }

    @Test("Snapshot sampling preserves host localizedName comment semantics")
    func testSnapshotSampling() {
        let snapshot = ClientSelfReportedSnapshot.sampleCurrent()
        #expect(snapshot.platform == "macos")
        #expect(snapshot.deviceType == "desktop")
        #expect(snapshot.appID != nil)
    }

    @Test("BoundedLoopbackClient session config connectionProxyDictionary empty")
    func testBoundedLoopbackClientConfig() {
        let config = BoundedLoopbackClient.makeSessionConfiguration()
        #expect(config.connectionProxyDictionary?.isEmpty == true)
    }

    @Test("PUT body exact keys, nulls encoded, owner_label never sent in PUT")
    func testPutBodyContractAndNullEncoding() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        // GET response with server owner_label
        let getBody = #"{"protocol_version": 1, "revision": 3, "journal": {"name": "Test Journal", "version": "0.9.1", "owner_label": "Alice"}}"#
        let putResponseBody = #"{"protocol_version": 1, "revision": 4, "journal": {"name": "Test Journal", "version": "0.9.1", "owner_label": "Alice"}}"#

        store.enqueue(statusCode: 200, body: getBody)
        store.enqueue(statusCode: 200, body: putResponseBody)

        let target = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_123",
            pairingGeneration: 1,
            metadataGeneration: 1
        )

        final class CallbackBox: @unchecked Sendable {
            var updatedIdentity: String?
            var updatedVersion: String?
            var updatedName: String?
            var updateCount = 0
        }
        let box = CallbackBox()

        let sequencer = JournalClientSelfSequencer(
            session: session,
            onJournalMetadataUpdated: { identity, gen, version, name in
                box.updatedIdentity = identity
                box.updatedVersion = version
                box.updatedName = name
                box.updateCount += 1
            }
        )

        // Snapshot with nil name
        let snapshot = ClientSelfReportedSnapshot(
            name: nil,
            platform: "macos",
            deviceType: "desktop",
            appID: "app.solstone.observer",
            appVersion: "1.0"
        )

        await sequencer.enqueue(target: target, snapshot: snapshot)
        await store.waitForRequestCount(2, timeout: .seconds(2))

        let requests = store.snapshotRequests()
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[1].httpMethod == "PUT")

        let putBody = store.requestBodies[1]
        let putBodyString = try #require(putBody)

        // Verify JSON string contains explicit null for name
        #expect(putBodyString.contains(#""name":null"#) || putBodyString.contains(#""name": null"#))

        // Verify JSON keys structure
        let putJson = try #require(try JSONSerialization.jsonObject(with: Data(putBodyString.utf8)) as? [String: Any])
        #expect(Set(putJson.keys) == Set(["protocol_version", "expected_revision", "reported"]))
        #expect(putJson["protocol_version"] as? Int == 1)
        #expect(putJson["expected_revision"] as? Int == 3)

        let reported = try #require(putJson["reported"] as? [String: Any])
        #expect(Set(reported.keys) == Set(["name", "platform", "device_type", "app_id", "app_version"]))
        #expect(reported["name"] is NSNull)
        #expect(reported["platform"] as? String == "macos")

        // Ensure owner_label was never in the PUT body
        #expect(!putBodyString.contains("owner_label"))

        #expect(box.updatedIdentity == "inst_123")
        #expect(box.updatedVersion == "0.9.1")
        #expect(box.updatedName == "Test Journal")
    }

    @Test("409 conflict retries once with newest coalesced snapshot")
    func test409RetriesOnceWithNewestSnapshot() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        // 1. Initial GET -> 200 (revision 1)
        let get1 = #"{"protocol_version": 1, "revision": 1, "journal": {"name": "J1", "version": "1.0", "owner_label": null}}"#
        store.enqueue(statusCode: 200, body: get1)
        // 2. First PUT -> 409 Conflict
        store.enqueue(statusCode: 409, body: #"{"error": "conflict"}"#)
        // 3. Retry GET -> 200 (revision 2)
        let get2 = #"{"protocol_version": 1, "revision": 2, "journal": {"name": "J1", "version": "1.0", "owner_label": null}}"#
        store.enqueue(statusCode: 200, body: get2)
        // 4. Retry PUT -> 200 (revision 3)
        let put2 = #"{"protocol_version": 1, "revision": 3, "journal": {"name": "J1", "version": "1.0", "owner_label": null}}"#
        store.enqueue(statusCode: 200, body: put2)

        let target = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_123",
            pairingGeneration: 1,
            metadataGeneration: 1
        )

        let sequencer = JournalClientSelfSequencer(
            session: session,
            onJournalMetadataUpdated: { _, _, _, _ in }
        )

        let initialSnapshot = ClientSelfReportedSnapshot(name: "Initial Name")
        await sequencer.enqueue(target: target, snapshot: initialSnapshot)

        await store.waitForRequestCount(4, timeout: .seconds(2))

        let requests = store.snapshotRequests()
        #expect(requests.count == 4)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[1].httpMethod == "PUT")
        #expect(requests[2].httpMethod == "GET")
        #expect(requests[3].httpMethod == "PUT")

        let put1Body = try #require(store.requestBodies[1])
        let put1Json = try #require(try JSONSerialization.jsonObject(with: Data(put1Body.utf8)) as? [String: Any])
        #expect(put1Json["expected_revision"] as? Int == 1)

        let put2Body = try #require(store.requestBodies[3])
        let put2Json = try #require(try JSONSerialization.jsonObject(with: Data(put2Body.utf8)) as? [String: Any])
        #expect(put2Json["expected_revision"] as? Int == 2)
    }

    @Test("404 clients/self triggers status fallback fetch and retains last known")
    func test404StatusFallback() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        // GET /app/network/api/clients/self returns 404
        store.enqueue(statusCode: 404, body: "Not Found")
        // Follow-up fallback GET /api/system/status returns 200 with version
        store.enqueue(statusCode: 200, body: #"{"version": {"current": "0.8.0"}}"#)

        final class CallbackBox: @unchecked Sendable {
            var updatedVersion: String?
            var updatedName: String?
            var updateCount = 0
        }
        let box = CallbackBox()

        let sequencer = JournalClientSelfSequencer(
            session: session,
            onJournalMetadataUpdated: { _, _, ver, name in
                box.updatedVersion = ver
                box.updatedName = name
                box.updateCount += 1
            }
        )

        let target = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_123",
            pairingGeneration: 1,
            metadataGeneration: 1
        )

        await sequencer.enqueue(target: target)
        await store.waitForRequestCount(2, timeout: .seconds(2))

        // No PUT request was made
        let requests = store.snapshotRequests()
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url?.path == "/app/network/api/clients/self")
        #expect(requests[1].httpMethod == "GET")
        #expect(requests[1].url?.path == "/api/system/status")

        #expect(box.updatedVersion == "0.8.0")
        #expect(box.updatedName == nil)
        #expect(box.updateCount == 1)
    }

    @Test("Corrupt/unsupported GET does not wipe last-known")
    func testCorruptGetIgnored() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        store.enqueue(statusCode: 200, body: "NOT_JSON_GARBAGE")

        final class CallbackBox: @unchecked Sendable {
            var updateCount = 0
        }
        let box = CallbackBox()

        let sequencer = JournalClientSelfSequencer(
            session: session,
            onJournalMetadataUpdated: { _, _, _, _ in
                box.updateCount += 1
            }
        )

        let target = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_123",
            pairingGeneration: 1,
            metadataGeneration: 1
        )

        await sequencer.enqueue(target: target)
        await store.waitForRequestCount(1, timeout: .seconds(2))

        #expect(box.updateCount == 0)
        #expect(store.snapshotRequests().count == 1)
    }

    @Test("Oversized response >64 KiB rejected")
    func testOversizedResponseRejected() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        let hugeBody = String(repeating: "x", count: 65 * 1024)
        store.enqueue(statusCode: 200, body: hugeBody)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:9999/app/network/api/clients/self")!)
        req.httpMethod = "GET"

        await #expect(throws: BoundedLoopbackClientError.self) {
            _ = try await BoundedLoopbackClient.execute(request: req, session: session)
        }
    }

    @Test("Redirect 302/301 results in exactly one request and no follow-up")
    func testRedirectRejection() async throws {
        TestRedirectURLProtocol.reset()
        let config = BoundedLoopbackClient.makeSessionConfiguration(
            additionalProtocolClasses: [TestRedirectURLProtocol.self]
        )
        let session = URLSession(
            configuration: config,
            delegate: JournalVersionRedirectDelegate(),
            delegateQueue: nil
        )

        var req = URLRequest(url: URL(string: "http://127.0.0.1:9999/app/network/api/clients/self")!)
        req.httpMethod = "GET"

        do {
            let (_, response) = try await BoundedLoopbackClient.execute(
                request: req,
                session: session,
                deadline: .milliseconds(200)
            )
            #expect(response.statusCode == 302)
        } catch {
            // Refusing redirect without response body is also valid
        }
        #expect(TestRedirectURLProtocol.requestCount == 1)
        #expect(TestRedirectURLProtocol.requestedURLs == [URL(string: "http://127.0.0.1:9999/app/network/api/clients/self")!])
        #expect(!TestRedirectURLProtocol.requestedURLs.contains(where: { $0.host == "off-channel.example" }))
    }

    @Test("Hanging deadline releases slot (isBusy becomes false), later enqueue runs, late completion fenced")
    @MainActor
    func testHangingDeadlineSlotReleaseAndFence() async throws {
        TestHangingURLProtocol.reset()
        let config = BoundedLoopbackClient.makeSessionConfiguration(
            additionalProtocolClasses: [TestHangingURLProtocol.self]
        )
        let hangingSession = URLSession(
            configuration: config,
            delegate: JournalVersionRedirectDelegate(),
            delegateQueue: nil
        )

        final class CallbackBox: @unchecked Sendable {
            var updateGens: [UInt64] = []
        }
        let box = CallbackBox()

        let jv = JournalVersionMetadata()
        jv.setIdentity("inst_123")

        let sequencer = JournalClientSelfSequencer(
            session: hangingSession,
            deadline: .milliseconds(100),
            onJournalMetadataUpdated: { identity, gen, version, name in
                box.updateGens.append(gen)
                await MainActor.run {
                    jv.applyDirectly(identity: identity, generation: gen, version: version, name: name, markCurrent: true)
                }
            }
        )

        let target1 = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_123",
            pairingGeneration: 1,
            metadataGeneration: jv.currentGeneration()
        )

        await sequencer.enqueue(target: target1)
        #expect(await sequencer.isBusy == true)

        // Wait for timeout
        try await Task.sleep(for: .milliseconds(300))
        #expect(await sequencer.isBusy == false)
        #expect(box.updateGens.isEmpty)

        // Later enqueue against normal session runs and succeeds
        let normalStore = ObserverURLProtocolStore()
        let normalSession = makeTestSession(store: normalStore)
        let getBody = #"{"protocol_version": 1, "revision": 1, "journal": {"name": "New J", "version": "2.0", "owner_label": null}}"#
        let putBody = #"{"protocol_version": 1, "revision": 2, "journal": {"name": "New J", "version": "2.0", "owner_label": null}}"#
        normalStore.enqueue(statusCode: 200, body: getBody)
        normalStore.enqueue(statusCode: 200, body: putBody)

        let normalSequencer = JournalClientSelfSequencer(
            session: normalSession,
            onJournalMetadataUpdated: { identity, gen, version, name in
                box.updateGens.append(gen)
                await MainActor.run {
                    jv.applyDirectly(identity: identity, generation: gen, version: version, name: name, markCurrent: true)
                }
            }
        )

        jv.disconnected()
        let gen2 = jv.currentGeneration()
        let target2 = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_123",
            pairingGeneration: 1,
            metadataGeneration: gen2
        )

        await normalSequencer.enqueue(target: target2)
        await normalStore.waitForRequestCount(2, timeout: .seconds(2))

        #expect(!box.updateGens.isEmpty)
        #expect(box.updateGens.allSatisfy { $0 == gen2 })
        #expect(jv.version == "2.0")
        #expect(jv.journalName == "New J")

        // Test generation fence: late completion with older generation cannot overwrite
        jv.applyDirectly(identity: "inst_123", generation: target1.metadataGeneration, version: "0.1", name: "Old", markCurrent: true)
        #expect(jv.version == "2.0")
        #expect(jv.journalName == "New J")
    }

    @Test("Job budget shared across GET + PUT + 409 reread pipeline")
    func testJobBudgetSharedAcrossPipeline() async throws {
        // Exceeding budget: 3 requests of 100ms > 200ms deadline
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)
        let getBody = #"{"protocol_version": 1, "revision": 1, "journal": {"name": "J", "version": "1.0", "owner_label": null}}"#
        let rereadBody = #"{"protocol_version": 1, "revision": 2, "journal": {"name": "J", "version": "1.0", "owner_label": null}}"#

        store.enqueue(statusCode: 200, body: getBody, delay: .milliseconds(100))
        store.enqueue(statusCode: 409, body: "", delay: .milliseconds(100))
        store.enqueue(statusCode: 200, body: rereadBody, delay: .milliseconds(100))
        store.enqueue(statusCode: 200, body: rereadBody, delay: .milliseconds(100))

        final class CallbackBox: @unchecked Sendable {
            var updateCount = 0
            var completed = false
        }
        let box = CallbackBox()

        let sequencer = JournalClientSelfSequencer(
            session: session,
            deadline: .milliseconds(200),
            onJournalMetadataUpdated: { _, _, _, _ in
                box.updateCount += 1
            }
        )

        let target = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_1",
            pairingGeneration: 1,
            metadataGeneration: 1
        )

        await sequencer.enqueue(target: target)
        try await Task.sleep(for: .milliseconds(400))

        #expect(await sequencer.isBusy == false)
        // Deadline expired, 4th request was not dispatched
        #expect(store.snapshotRequests().count <= 3)

        // Completing within budget: 4 requests of 20ms = 80ms < 500ms deadline
        let store2 = ObserverURLProtocolStore()
        let session2 = makeTestSession(store: store2)
        store2.enqueue(statusCode: 200, body: getBody, delay: .milliseconds(20))
        store2.enqueue(statusCode: 409, body: "", delay: .milliseconds(20))
        store2.enqueue(statusCode: 200, body: rereadBody, delay: .milliseconds(20))
        store2.enqueue(statusCode: 200, body: rereadBody, delay: .milliseconds(20))

        let box2 = CallbackBox()
        let sequencer2 = JournalClientSelfSequencer(
            session: session2,
            deadline: .milliseconds(500),
            onJournalMetadataUpdated: { _, _, _, _ in
                box2.updateCount += 1
            }
        )

        await sequencer2.enqueue(target: target)
        await store2.waitForRequestCount(4, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))

        #expect(await sequencer2.isBusy == false)
        #expect(box2.updateCount >= 1)
    }

    @Test("Oversized legacy fallback (>64 KiB) rejected without publishing metadata")
    func testOversizedLegacyFallbackRejected() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        // 404 on /clients/self triggers legacy fallback to /api/system/status
        store.enqueue(statusCode: 404, body: "Not found")
        let oversizedBody = "{\"version\": \"1.0\", \"padding\": \"" + String(repeating: "x", count: 65536) + "\"}"
        store.enqueue(statusCode: 200, body: oversizedBody)

        final class CallbackBox: @unchecked Sendable {
            var updateCount = 0
        }
        let box = CallbackBox()

        let sequencer = JournalClientSelfSequencer(
            session: session,
            onJournalMetadataUpdated: { _, _, _, _ in
                box.updateCount += 1
            }
        )

        let target = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_1",
            pairingGeneration: 1,
            metadataGeneration: 1
        )

        await sequencer.enqueue(target: target)
        await store.waitForRequestCount(2, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))

        #expect(await sequencer.isBusy == false)
        #expect(box.updateCount == 0)
    }

    @Test("Malformed PUT 200 does not overwrite valid GET metadata")
    func testMalformedPut200DoesNotOverwriteValidatedGet() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        let validGet = #"{"protocol_version": 1, "revision": 1, "journal": {"name": "Valid J", "version": "1.0", "owner_label": null}}"#
        // Malformed protocol_version 2 in PUT 200
        let badPut = #"{"protocol_version": 2, "revision": 2, "journal": {"name": "Bad J", "version": "2.0", "owner_label": null}}"#

        store.enqueue(statusCode: 200, body: validGet)
        store.enqueue(statusCode: 200, body: badPut)

        final class CallbackBox: @unchecked Sendable {
            var publishedNames: [String?] = []
            var publishedVersions: [String?] = []
        }
        let box = CallbackBox()

        let sequencer = JournalClientSelfSequencer(
            session: session,
            onJournalMetadataUpdated: { _, _, version, name in
                box.publishedNames.append(name)
                box.publishedVersions.append(version)
            }
        )

        let target = JournalClientSelfSequencer.TargetConnection(
            localPort: 9999,
            identity: "inst_1",
            pairingGeneration: 1,
            metadataGeneration: 1
        )

        await sequencer.enqueue(target: target)
        await store.waitForRequestCount(2, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))

        #expect(box.publishedNames == ["Valid J"])
        #expect(box.publishedVersions == ["1.0"])
    }

    @Test("Target B during Target A 409 reread GET cancels A and publishes B")
    func testTargetBDuringA409Reread() async throws {
        let store = ObserverURLProtocolStore()
        let session = makeTestSession(store: store)

        let getA = #"{"protocol_version": 1, "revision": 1, "journal": {"name": "JA", "version": "1.0", "owner_label": null}}"#
        let rereadA = #"{"protocol_version": 1, "revision": 2, "journal": {"name": "JA", "version": "1.0", "owner_label": null}}"#
        let getB = #"{"protocol_version": 1, "revision": 1, "journal": {"name": "JB", "version": "2.0", "owner_label": null}}"#
        let putB = #"{"protocol_version": 1, "revision": 2, "journal": {"name": "JB", "version": "2.0", "owner_label": null}}"#

        store.enqueue(statusCode: 200, body: getA)
        store.enqueue(statusCode: 409, body: "")
        store.enqueue(statusCode: 200, body: rereadA, delay: .milliseconds(100))
        store.enqueue(statusCode: 200, body: getB)
        store.enqueue(statusCode: 200, body: putB)

        final class CallbackBox: @unchecked Sendable {
            var names: [String?] = []
        }
        let box = CallbackBox()

        let sequencer = JournalClientSelfSequencer(
            session: session,
            onJournalMetadataUpdated: { _, _, _, name in
                box.names.append(name)
            }
        )

        let targetA = JournalClientSelfSequencer.TargetConnection(
            localPort: 9001,
            identity: "inst_A",
            pairingGeneration: 1,
            metadataGeneration: 1
        )
        let targetB = JournalClientSelfSequencer.TargetConnection(
            localPort: 9002,
            identity: "inst_B",
            pairingGeneration: 2,
            metadataGeneration: 2
        )

        await sequencer.enqueue(target: targetA)
        await store.waitForRequestCount(2, timeout: .seconds(2))
        // Enqueue target B while A is reading 409
        await sequencer.enqueue(target: targetB)

        await store.waitForRequestCount(5, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))

        #expect(box.names.contains("JB"))
    }

    @Test("Access Ready during metadata GET does not suppress metadata")
    @MainActor
    func testAccessReadyDuringMetadataGet() async throws {
        let store = ObserverURLProtocolStore()
        let sessions = SessionRecorder()

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
            "jti": "jwt-ready-meta"
        ]
        let token = JournalRelayAccessTests.makeJWT(claims: claims)
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

        let metaGet = #"{"protocol_version": 1, "revision": 1, "journal": {"name": "Concurrent J", "version": "3.0", "owner_label": null}}"#
        let metaPut = #"{"protocol_version": 1, "revision": 2, "journal": {"name": "Concurrent J", "version": "3.0", "owner_label": null}}"#

        // Serve relay access ready, metadata GET, metadata PUT
        store.registerRoute(path: "/app/network/api/relay/access", statusCode: 200, body: readyJson)
        store.registerRoute(path: "/app/network/api/clients/self", method: "GET", statusCode: 200, body: metaGet)
        store.registerRoute(path: "/app/network/api/clients/self", method: "PUT", statusCode: 200, body: metaPut)

        let initialPairing = pairing(
            instanceID: "test-instance",
            deviceToken: "old-token",
            relayEndpoint: "https://old-relay.solstone.test"
        )
        let pairingStore = PairingStore(pairing: initialPairing)
        let credStore = PairingCredentialStore(store: pairingStore)
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
            loopbackSession: session
        )

        owner.start()
        try await waitUntil { sessions.count >= 2 }
        try await waitUntil { owner.journalVersion.version == "3.0" }

        #expect(owner.journalVersion.version == "3.0")
        #expect(owner.journalVersion.journalName == "Concurrent J")

        await owner.stop()
    }
}

private final class TestRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var requestedURLs: [URL] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        requestCount = 0
        requestedURLs = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        if let url = request.url {
            Self.requestedURLs.append(url)
        }
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://off-channel.example/follow"]
        )!
        let redirectRequest = URLRequest(url: URL(string: "http://off-channel.example/follow")!)
        client?.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: response)
    }

    override func stopLoading() {}
}

private final class TestHangingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var didStartLoading: (@Sendable () -> Void)?
    nonisolated(unsafe) static var didCancel: (@Sendable () -> Void)?

    static func reset() {
        didStartLoading = nil
        didCancel = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.didStartLoading?()
    }

    override func stopLoading() {
        Self.didCancel?()
    }
}

