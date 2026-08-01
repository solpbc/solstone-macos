// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import solstone

@Suite("Same-machine pair-start client", .serialized)
struct SameMachinePairStartClientTests {
    @Test func startPostsSameMachineJSONBoolean() async throws {
        let store = ObserverURLProtocolStore()
        let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
        defer { session.invalidateAndCancel() }
        store.enqueue(body: pairStartResponseBody(pairLink: loopbackDirectPairLink))
        let client = SameMachinePairStartClient(session: session)

        let result = await client.start(baseURL: "http://127.0.0.1:5015/", deviceLabel: "test mac")
        let response = try requirePairStartSuccess(result)

        #expect(response.pairLink == loopbackDirectPairLink)
        let request = try #require(store.snapshotRequests().first)
        #expect(request.url?.path == "/app/network/pair-start")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(store.requestBodies.first.flatMap { $0 })
        let payload = try sameMachineJSONObject(body)
        #expect(Set(payload.keys) == ["device_label", "same_machine"])
        #expect(payload["device_label"] as? String == "test mac")
        let sameMachine = try #require(payload["same_machine"] as? Bool)
        #expect(sameMachine)
    }
}

func pairStartResponseBody(pairLink: String) -> String {
    """
    {"nonce":"nonce-1","pair_link":"\(pairLink)","expires_in":300,"device_label":"test mac","ca_fingerprint":"ca-fingerprint"}
    """
}

func requirePairStartSuccess(
    _ result: Result<SameMachinePairStartResponse, SameMachinePairStartFailure>
) throws -> SameMachinePairStartResponse {
    switch result {
    case .success(let response):
        return response
    case .failure(let failure):
        throw failure
    }
}

private func sameMachineJSONObject(_ body: String) throws -> [String: Any] {
    let data = try #require(body.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// 0x04 direct: 127.0.0.1:5015.
let loopbackDirectPairLink = "https://go.solstone.app/p#0G0QY000049SE000000000000000000000000001040G2081040G2081040G2081"

// 0x04 direct: 192.168.1.42:7070.
let lanDirectPairLink = "https://go.solstone.app/p#0G0W1A0158DSW48H248H248H248H248H248H249248H248H248H248H248H248H2"

// 0x05 direct: 127.0.0.1:5015, then 127.0.0.2:5015.
let multiLoopbackDirectPairLink = "https://go.solstone.app/p#0M0G44WQFW0000BZ00004000000000000000000000000001040G2081040G2081040G2081"

let relayPairWindowLink = "https://go.solstone.app/p#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"
