// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing

@Suite("ObserverURLProtocol isolation")
struct ObserverURLProtocolIsolationTests {
    @Test func storesAreBoundPerSessionAndResetDoesNotBleed() async throws {
        let storeA = ObserverURLProtocolStore()
        let storeB = ObserverURLProtocolStore()
        let sessionA = URLSession(configuration: observerURLProtocolConfiguration(store: storeA))
        let sessionB = URLSession(configuration: observerURLProtocolConfiguration(store: storeB))
        defer {
            sessionA.invalidateAndCancel()
            sessionB.invalidateAndCancel()
        }

        let urlA = try #require(URL(string: "http://store-a.test/app/devices/ingest"))
        let urlB = try #require(URL(string: "http://store-b.test/app/devices/ingest/segments/20260703"))

        storeB.enqueue(statusCode: 200, body: #"{"store":"b"}"#)

        async let resultB = sessionB.data(from: urlB)

        await storeB.waitForRequestCount(1, timeout: .seconds(1))
        let requestsBBeforeReset = storeB.snapshotRequests()
        #expect(requestsBBeforeReset.count == 1)
        #expect(requestsBBeforeReset.first?.url == urlB)
        #expect(requestsBBeforeReset.first?.value(forHTTPHeaderField: "X-Solstone-Test-Store") == storeB.token)

        storeA.reset()
        storeA.enqueue(statusCode: 200, body: #"{"store":"a"}"#)

        async let resultA = sessionA.data(from: urlA)

        let requestsBAfterReset = storeB.snapshotRequests()
        #expect(requestsBAfterReset.count == 1)
        #expect(requestsBAfterReset.first?.url == urlB)
        #expect(requestsBAfterReset.first?.value(forHTTPHeaderField: "X-Solstone-Test-Store") == storeB.token)

        let (dataA, responseA) = try await resultA
        let (dataB, responseB) = try await resultB
        let httpA = try #require(responseA as? HTTPURLResponse)
        let httpB = try #require(responseB as? HTTPURLResponse)

        #expect(httpA.statusCode == 200)
        #expect(httpB.statusCode == 200)
        #expect(String(data: dataA, encoding: .utf8) == #"{"store":"a"}"#)
        #expect(String(data: dataB, encoding: .utf8) == #"{"store":"b"}"#)

        let requestsA = storeA.snapshotRequests()
        let requestsB = storeB.snapshotRequests()
        #expect(requestsA.count == 1)
        #expect(requestsB.count == 1)
        #expect(requestsA.first?.url == urlA)
        #expect(requestsB.first?.url == urlB)
        #expect(requestsA.first?.value(forHTTPHeaderField: "X-Solstone-Test-Store") == storeA.token)
        #expect(requestsB.first?.value(forHTTPHeaderField: "X-Solstone-Test-Store") == storeB.token)
    }
}
