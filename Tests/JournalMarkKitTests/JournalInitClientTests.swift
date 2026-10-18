// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MacTestSupport
import Testing
@testable import JournalMarkKit

@Suite("JournalInitClient", .serialized)
struct JournalInitClientTests {
    @Test func getMarkBuildsExpectedRequestAndDecodesValidatedMark() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: Self.markResponse(locked: false))
        let client = Self.client(store: store, baseURL: "http://127.0.0.1:5015/")

        let response = try await client.getMark()
        let request = try #require(store.snapshotRequests().first)

        #expect(response.mark.words == ["afoot", "unfixed"])
        #expect(response.locked == false)
        #expect(response.proposalID == nil)
        #expect(request.url?.absoluteString == "http://127.0.0.1:5015/init/mark")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 5)
    }

    @Test func regenerateAndLockUsePostWithoutBodyAndDecodeLockedState() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: Self.markResponse(locked: false))
        store.enqueue(body: Self.markResponse(locked: true))
        let client = Self.client(store: store)

        let regenerated = try await client.regenerateMark()
        let locked = try await client.lockMark()
        let requests = store.snapshotRequests()

        #expect(regenerated.locked == false)
        #expect(locked.locked == true)
        #expect(requests.map { $0.url?.path } == ["/init/mark/regenerate", "/init/mark/lock"])
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(store.requestBodies == [nil, nil])
    }

    @Test func finalizeSendsEmptyJSONBodyAndDecodesWarnings() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"success":true,"redirect":"/","warnings":["secure listener unavailable"]}"#)
        let client = Self.client(store: store)

        let response = try await client.finalize()
        let request = try #require(store.snapshotRequests().first)
        let body = try #require(store.requestBodies.first ?? nil)
        let bodyObject = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])

        #expect(response == JournalInitFinalizeResponse(
            success: true,
            redirect: "/",
            warnings: ["secure listener unavailable"]
        ))
        #expect(request.url?.path == "/init/finalize")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(bodyObject.isEmpty)
    }

    @Test func lockSendsExactlyTheDisplayedProposalAsJSON() async throws {
        let store = ObserverURLProtocolStore()
        let proposalID = "shown-\"proposal\\identity"
        store.enqueue(body: Self.json([
            "mark": Self.markObject(), "locked": false, "proposal_id": proposalID,
        ]))
        store.enqueue(body: Self.markResponse(locked: true))
        let client = Self.client(store: store)

        let displayed = try await client.getMark()
        #expect(displayed.proposalID == proposalID)
        let locked = try await client.lockMark(proposalID: try #require(displayed.proposalID))
        let requests = store.snapshotRequests()
        let body = try #require(store.requestBodies.last ?? nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])

        #expect(locked.locked)
        #expect(requests.count == 2)
        #expect(requests.last?.url?.path == "/init/mark/lock")
        #expect(requests.last?.httpMethod == "POST")
        #expect(requests.last?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(object == ["proposal_id": proposalID])
    }

    @Test func emptyProposalIsRefusedBeforeRequest() async throws {
        let store = ObserverURLProtocolStore()
        let client = Self.client(store: store)
        do {
            _ = try await client.lockMark(proposalID: "")
            Issue.record("expected invalidProposalID")
        } catch let error as JournalInitClientError {
            #expect(error == .invalidProposalID)
        }
        #expect(store.snapshotRequests().isEmpty)
    }

    @Test func malformedProposalIsNotCoercedOrTreatedAsLegacy() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: Self.json([
            "mark": Self.markObject(), "locked": false, "proposal_id": 42,
        ]))
        let client = Self.client(store: store)
        do {
            _ = try await client.getMark()
            Issue.record("expected proposal decoding failure")
        } catch is DecodingError {
            #expect(store.snapshotRequests().count == 1)
        }
    }

    @Test func staleProposalThrowsWithoutRefetchOrLegacyFallback() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 409, body: #"{"error":"stale","reason_code":"proposal_conflict","detail":"changed"}"#)
        let client = Self.client(store: store)
        do {
            _ = try await client.lockMark(proposalID: "displayed-proposal")
            Issue.record("expected stale proposal refusal")
        } catch let error as JournalInitClientError {
            #expect(error == .serverError(409))
        }
        #expect(store.snapshotRequests().map { $0.url?.path } == ["/init/mark/lock"])
    }

    @Test func probeSetupCompleteMapsRedirectDisabledStatuses() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 302)
        store.enqueue(statusCode: 200)
        let client = Self.client(store: store)

        let complete = try await client.probeSetupComplete()
        let incomplete = try await client.probeSetupComplete()

        #expect(complete == .complete)
        #expect(incomplete == .incomplete)
        #expect(store.snapshotRequests().map { $0.url?.path } == ["/init", "/init"])
    }

    @Test func invalidOperationForStateMapsToTypedError() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(
            statusCode: 400,
            body: #"{"error":"bad state","reason":"invalid_operation_for_state","reason_code":"invalid_operation_for_state","detail":"journal id already locked"}"#
        )
        let client = Self.client(store: store)

        do {
            _ = try await client.regenerateMark()
            Issue.record("expected invalidOperationForState")
        } catch let error as JournalInitClientError {
            #expect(error == .invalidOperationForState(detail: "journal id already locked"))
        }
    }

    @Test func identityNotLockedMapsToTypedError() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(
            statusCode: 400,
            body: #"{"error":"not locked","reason_code":"identity_not_locked","detail":"journal id must be locked before setup can finish"}"#
        )
        let client = Self.client(store: store)

        do {
            _ = try await client.finalize()
            Issue.record("expected identityNotLocked")
        } catch let error as JournalInitClientError {
            #expect(error == .identityNotLocked(detail: "journal id must be locked before setup can finish"))
        }
    }

    @Test func invalidMarkIsRejected() async throws {
        let store = ObserverURLProtocolStore()
        var mark = Self.markObject()
        var icon2 = mark["icon2"] as! [String: Any]
        icon2["rot"] = 90
        mark["icon2"] = icon2
        store.enqueue(body: Self.markResponse(locked: false, mark: mark))
        let client = Self.client(store: store)

        do {
            _ = try await client.getMark()
            Issue.record("expected invalidResponse")
        } catch let error as JournalInitClientError {
            #expect(error == .invalidResponse)
        }
    }

    private static func client(store: ObserverURLProtocolStore, baseURL: String = "http://127.0.0.1:5015") -> JournalInitClient {
        JournalInitClient(
            baseURL: baseURL,
            sessionConfiguration: observerURLProtocolConfiguration(store: store)
        )
    }

    private static func markResponse(locked: Bool, mark: [String: Any] = markObject()) -> String {
        json([
            "mark": mark,
            "locked": locked,
        ])
    }

    private static func markObject() -> [String: Any] {
        [
            "icon1": [
                "name": "bug",
                "color": ["hex": "#f59e0b"],
                "rot": 0,
                "svg": JournalMark.uiTestSample.icon1.svg,
            ],
            "icon2": [
                "name": "gem",
                "color": ["hex": "#84cc16"],
                "rot": 45,
                "svg": JournalMark.uiTestSample.icon2.svg,
            ],
            "words": ["afoot", "unfixed"],
        ]
    }

    private static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
