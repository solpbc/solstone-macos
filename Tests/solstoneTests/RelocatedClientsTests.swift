// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntimeTestSupport
import Testing

@Suite("RelocatedClients", .serialized)
struct RelocatedClientsTests {
    @Test func observerRegistrationHappyPathPostsPinnedRequestAndDecodesFullResponse() async throws {
        let fullResponse = #"{"key":"observer-key","prefix":"captures","name":"observer-name","ingest_url":"https://journal.example/app/observer/ingest","protocol_version":1}"#
        let responsePayload = try jsonObject(fullResponse)
        #expect(Set(responsePayload.keys) == ["key", "prefix", "name", "ingest_url", "protocol_version"])
        #expect(responsePayload["key"] as? String == "observer-key")
        #expect(responsePayload["prefix"] as? String == "captures")
        #expect(responsePayload["name"] as? String == "observer-name")
        #expect(responsePayload["ingest_url"] as? String == "https://journal.example/app/observer/ingest")
        #expect(responsePayload["protocol_version"] as? Int == 1)

        let (client, store, session) = makeRegistrationClient()
        defer { session.invalidateAndCancel() }
        store.enqueue(body: fullResponse)

        let descriptor = ObserverRegistrationDescriptor(
            platform: "darwin",
            hostname: "observer-mac",
            streamType: "desktop",
            version: "1.2.3"
        )
        let result = await client.register(
            baseURL: "http://journal.example///",
            descriptor: descriptor
        )

        let registration = try requireRegistrationSuccess(result)
        #expect(registration.key == "observer-key")
        #expect(registration.streamName == "observer-name")

        let request = try #require(store.snapshotRequests().first)
        #expect(request.url?.absoluteString == "http://journal.example/app/observer/register")
        #expect(request.url?.path == "/app/observer/register")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 5)

        let body = try #require(store.requestBodies.first.flatMap { $0 })
        let requestPayload = try jsonObject(body)
        #expect(Set(requestPayload.keys) == ["platform", "hostname", "stream_type", "version"])
        #expect(requestPayload["platform"] as? String == "darwin")
        #expect(requestPayload["hostname"] as? String == "observer-mac")
        #expect(requestPayload["stream_type"] as? String == "desktop")
        #expect(requestPayload["version"] as? String == "1.2.3")
    }

    @Test func observerRegistrationToleratesMinimalResponse() async throws {
        let (client, store, session) = makeRegistrationClient()
        defer { session.invalidateAndCancel() }
        store.enqueue(body: #"{"key":"observer-key","name":"observer-name"}"#)

        let result = await client.register(
            baseURL: "http://journal.example",
            descriptor: ObserverRegistrationDescriptor(
                platform: "darwin",
                hostname: "observer-mac",
                streamType: "desktop",
                version: "1.2.3"
            )
        )

        let registration = try requireRegistrationSuccess(result)
        #expect(registration == ObserverRegistration(key: "observer-key", streamName: "observer-name"))
    }

    @Test func observerRegistrationReportsHTTPFailureKind() async throws {
        let (client, store, session) = makeRegistrationClient()
        defer { session.invalidateAndCancel() }
        store.enqueue(statusCode: 503, body: #"{"error":"unavailable"}"#)

        let failure = try await registrationFailure(from: client)

        #expect(failure.kind == .httpStatus(503))
    }

    @Test func observerRegistrationReportsEmptyKeyFailureKind() async throws {
        let (client, store, session) = makeRegistrationClient()
        defer { session.invalidateAndCancel() }
        store.enqueue(body: #"{"key":"  ","name":"observer-name"}"#)

        let failure = try await registrationFailure(from: client)

        #expect(failure.kind == .emptyKey)
    }

    @Test func observerRegistrationReportsEmptyNameFailureKind() async throws {
        let (client, store, session) = makeRegistrationClient()
        defer { session.invalidateAndCancel() }
        store.enqueue(body: #"{"key":"observer-key","name":"  "}"#)

        let failure = try await registrationFailure(from: client)

        #expect(failure.kind == .emptyName)
    }

    @Test func observerRegistrationReportsDecodeFailureKind() async throws {
        let (client, store, session) = makeRegistrationClient()
        defer { session.invalidateAndCancel() }
        store.enqueue(body: #"{"key":"observer-key","name":"#)

        let failure = try await registrationFailure(from: client)

        #expect(failure.kind == .decode)
    }

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

private func makeRegistrationClient() -> (
    ObserverRegistrationClient,
    ObserverURLProtocolStore,
    URLSession
) {
    let store = ObserverURLProtocolStore()
    let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
    return (ObserverRegistrationClient(session: session), store, session)
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

private func registrationFailure(
    from client: ObserverRegistrationClient
) async throws -> ObserverRegistrationFailure {
    let result = await client.register(
        baseURL: "http://journal.example",
        descriptor: ObserverRegistrationDescriptor(
            platform: "darwin",
            hostname: "observer-mac",
            streamType: "desktop",
            version: "1.2.3"
        )
    )
    return try requireRegistrationFailure(result)
}

private func requireRegistrationSuccess(
    _ result: Result<ObserverRegistration, ObserverRegistrationFailure>
) throws -> ObserverRegistration {
    switch result {
    case let .success(registration):
        return registration
    case let .failure(failure):
        throw failure
    }
}

private func requireRegistrationFailure(
    _ result: Result<ObserverRegistration, ObserverRegistrationFailure>
) throws -> ObserverRegistrationFailure {
    switch result {
    case let .success(registration):
        throw RelocatedClientsTestError.unexpectedSuccess(registration)
    case let .failure(failure):
        return failure
    }
}

private func jsonObject(_ body: String) throws -> [String: Any] {
    let data = Data(body.utf8)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private enum RelocatedClientsTestError: Error {
    case unexpectedSuccess(ObserverRegistration)
}
