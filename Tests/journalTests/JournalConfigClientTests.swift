// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import journal

@Suite("JournalConfigClient")
struct JournalConfigClientTests {
    @Test func fetchConfigBuildsExpectedRequestAndDecodesJournalName() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"journal":{"name":"home base"},"other":true}"#)
        let client = JournalConfigClient(
            baseURL: "http://127.0.0.1:5015",
            sessionConfiguration: observerURLProtocolConfiguration(store: store)
        )

        let config = try await client.fetchConfig()
        let request = try #require(store.snapshotRequests().first)

        #expect(config.journal.name == "home base")
        #expect(request.url?.absoluteString == "http://127.0.0.1:5015/app/settings/api/config")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func updateJournalNameSendsSectionBodyAndDecodesReturnedConfig() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"success":true,"config":{"journal":{"name":"new name"}}}"#)
        let client = JournalConfigClient(
            baseURL: "http://127.0.0.1:5015/",
            sessionConfiguration: observerURLProtocolConfiguration(store: store)
        )

        let config = try await client.updateJournalName("new name")
        let request = try #require(store.snapshotRequests().first)
        let body = try #require(store.requestBodies.first ?? nil)
        let bodyObject = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let data = bodyObject?["data"] as? [String: Any]

        #expect(config.journal.name == "new name")
        #expect(request.url?.absoluteString == "http://127.0.0.1:5015/app/settings/api/config")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(bodyObject?["section"] as? String == "journal")
        #expect(data?["name"] as? String == "new name")
    }

    @Test func nonSuccessStatusThrowsServerError() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 503, body: #"{"error":"down"}"#)
        let client = JournalConfigClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))

        do {
            _ = try await client.fetchConfig()
            Issue.record("expected server error")
        } catch let error as JournalConfigClientError {
            #expect(error == .serverError(503))
        }
    }
}
