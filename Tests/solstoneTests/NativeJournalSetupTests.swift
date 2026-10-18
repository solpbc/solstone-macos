// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import MacTestSupport
import Testing

@Suite("Native journal setup ritual", .serialized)
struct NativeJournalSetupTests {
    @Test(arguments: [false, true])
    func selectedMarkIsLockedBeforeFinalize(tokenRequired: Bool) async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: try markResponse(locked: false, proposalID: tokenRequired ? "selected-proposal" : nil))
        store.enqueue(body: try markResponse(locked: true))
        store.enqueue(body: #"{"success":true,"redirect":"/app/home","warnings":[]}"#)

        let result = try await establishNativeJournalSession(client: client(store))

        #expect(result.success)
        #expect(store.snapshotRequests().map { $0.url?.path } == ["/init/mark", "/init/mark/lock", "/init/finalize"])
        if tokenRequired {
            let body = try #require(store.requestBodies[1])
            let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
            #expect(object == ["proposal_id": "selected-proposal"])
        } else {
            #expect(store.requestBodies[1] == nil)
        }
    }

    @Test func staleCommitStopsTheActualSequenceBeforeFinalize() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: try markResponse(locked: false, proposalID: "selected-proposal"))
        store.enqueue(statusCode: 409, body: #"{"error":"stale","reason_code":"proposal_conflict"}"#)
        store.enqueue(body: #"{"success":true,"redirect":"/app/home","warnings":[]}"#)
        do {
            _ = try await establishNativeJournalSession(client: client(store))
            Issue.record("expected stale proposal refusal")
        } catch let error as JournalInitClientError {
            #expect(error == .serverError(409))
        }
        #expect(store.snapshotRequests().map { $0.url?.path } == ["/init/mark", "/init/mark/lock"])
    }

    @Test(arguments: [false, true])
    func invalidLockSuccessCannotFinalize(changedMark: Bool) async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: try markResponse(locked: false, proposalID: "selected-proposal"))
        let selected = JournalMark.uiTestSample
        let replacement = JournalMark(icon1: selected.icon1, icon2: selected.icon2, words: ["different", "mark"])
        store.enqueue(body: try markResponse(locked: changedMark, mark: changedMark ? replacement : selected))
        store.enqueue(body: #"{"success":true,"redirect":"/app/home","warnings":[]}"#)
        do {
            _ = try await establishNativeJournalSession(client: client(store))
            Issue.record("expected lock validation refusal")
        } catch let error as NativeJournalSetupError {
            #expect(error == (changedMark ? .markChanged : .markNotLocked))
        }
        #expect(store.snapshotRequests().map { $0.url?.path } == ["/init/mark", "/init/mark/lock"])
    }

    private func client(_ store: ObserverURLProtocolStore) -> JournalInitClient {
        JournalInitClient(baseURL: "http://127.0.0.1:54321", sessionConfiguration: observerURLProtocolConfiguration(store: store))
    }

    private func markResponse(locked: Bool, proposalID: String? = nil, mark: JournalMark = .uiTestSample) throws -> String {
        var object: [String: Any] = [
            "mark": try JSONSerialization.jsonObject(with: JSONEncoder().encode(mark)),
            "locked": locked,
        ]
        if let proposalID { object["proposal_id"] = proposalID }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
