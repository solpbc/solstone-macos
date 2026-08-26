// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntimeTestSupport
import Testing

@Suite("RelocatedClients", .serialized)
struct RelocatedClientsTests {
    @Test func journalNameFetcherReturnsTrimmedName() async throws {
        let (fetcher, store, session) = makeJournalNameFetcher()
        defer { session.invalidateAndCancel() }
        store.enqueue(body: #"{"journal":{"name":"  field journal  "}}"#)

        let name = await fetcher.fetch(baseURL: "http://journal.example///")

        #expect(name == "field journal")
        let request = try #require(store.snapshotRequests().first)
        #expect(request.url?.absoluteString == "http://journal.example/app/settings/api/config")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 5)
    }

    @Test func journalNameFetcherReturnsNilForAbsentOrMissingName() async {
        let (sectionAbsentFetcher, sectionAbsentStore, sectionAbsentSession) = makeJournalNameFetcher()
        defer { sectionAbsentSession.invalidateAndCancel() }
        sectionAbsentStore.enqueue(body: #"{}"#)

        let (nameMissingFetcher, nameMissingStore, nameMissingSession) = makeJournalNameFetcher()
        defer { nameMissingSession.invalidateAndCancel() }
        nameMissingStore.enqueue(body: #"{"journal":{}}"#)

        let sectionAbsent = await sectionAbsentFetcher.fetch(baseURL: "http://journal.example")
        let nameMissing = await nameMissingFetcher.fetch(baseURL: "http://journal.example")

        #expect(sectionAbsent == nil)
        #expect(nameMissing == nil)
    }

    @Test func journalNameFetcherReturnsNilForHTTPError() async {
        let (fetcher, store, session) = makeJournalNameFetcher()
        defer { session.invalidateAndCancel() }
        store.enqueue(statusCode: 500, body: #"{"error":"broken"}"#)

        let name = await fetcher.fetch(baseURL: "http://journal.example")

        #expect(name == nil)
    }
}

private func makeJournalNameFetcher() -> (
    JournalNameFetcher,
    ObserverURLProtocolStore,
    URLSession
) {
    let store = ObserverURLProtocolStore()
    let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
    return (JournalNameFetcher(session: session), store, session)
}
