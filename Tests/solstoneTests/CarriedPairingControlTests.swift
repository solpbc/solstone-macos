// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Carried pairing control decoding")
struct CarriedPairingControlTests {
    private let cid = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    @Test func migrationStateRequiresNullableFieldsAndAllowsFreshPairTerminalState() throws {
        let none = #"{"protocol_version":1,"rekey_operation_id":null,"previous_cid":null,"state":"none","replaced_cid":null}"#
        let replacement = #"{"protocol_version":1,"rekey_operation_id":null,"previous_cid":null,"state":"replaced_device","replaced_cid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#

        #expect(try JSONDecoder().decode(CarriedPairingMigrationReply.self, from: Data(none.utf8)).state == "none")
        #expect(try JSONDecoder().decode(CarriedPairingMigrationReply.self, from: Data(replacement.utf8)).replacedCID == cid)

        for field in ["rekey_operation_id", "previous_cid", "replaced_cid"] {
            let missingNullableField = none.replacingOccurrences(of: ",\"\(field)\":null", with: "")
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CarriedPairingMigrationReply.self, from: Data(missingNullableField.utf8))
            }
        }
    }

    @Test func migrationStateRejectsInvalidOperationAndCID() {
        let invalidOperation = #"{"protocol_version":1,"rekey_operation_id":"not-a-uuid","previous_cid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"pending","replaced_cid":null}"#
        let invalidCID = #"{"protocol_version":1,"rekey_operation_id":"123e4567-e89b-42d3-a456-426614174000","previous_cid":"sha256:bad","state":"pending","replaced_cid":null}"#

        for fixture in [invalidOperation, invalidCID] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CarriedPairingMigrationReply.self, from: Data(fixture.utf8))
            }
        }
    }

    @Test func migrationAndDecisionRepliesRejectUnknownResponseKeys() {
        let migration = #"{"protocol_version":1,"rekey_operation_id":null,"previous_cid":null,"state":"none","replaced_cid":null,"extra":true}"#
        let decision = #"{"protocol_version":1,"operation_id":"123e4567-e89b-42d3-a456-426614174000","state":"same_device","previous_cid":null,"cid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","replaced_cid":null,"display_label":"Laptop","extra":true}"#

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CarriedPairingMigrationReply.self, from: Data(migration.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CarriedPairingDecisionReply.self, from: Data(decision.utf8))
        }
    }

    @Test func http409IsAnOutcomeConflictThatRequiresReconciliation() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CarriedPairingConflictURLProtocol.self]
        let client = URLSessionCarriedPairingControlClient(session: URLSession(configuration: configuration))

        do {
            _ = try await client.migrationState(localPort: 1234)
            Issue.record("expected HTTP 409 to remain an unknown conflict")
        } catch let error as CarriedPairingControlError {
            #expect(error == .conflict)
        } catch {
            Issue.record("unexpected error for HTTP 409")
        }
    }

    @Test func decisionReplyRequiresExplicitNullableFieldsAndValidatedCurrentCID() throws {
        let valid = #"{"protocol_version":1,"operation_id":"123e4567-e89b-42d3-a456-426614174000","state":"same_device","previous_cid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","cid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","replaced_cid":null,"display_label":"Laptop"}"#
        #expect(try JSONDecoder().decode(CarriedPairingDecisionReply.self, from: Data(valid.utf8)).cid == cid)

        let invalidCID = #"{"protocol_version":1,"operation_id":"123e4567-e89b-42d3-a456-426614174000","state":"same_device","previous_cid":null,"cid":"sha256:bad","replaced_cid":null,"display_label":"Laptop"}"#

        let validObject = try #require(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        for field in ["previous_cid", "replaced_cid"] {
            var missingObject = validObject
            missingObject.removeValue(forKey: field)
            let missingNullableField = try JSONSerialization.data(withJSONObject: missingObject)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CarriedPairingDecisionReply.self, from: missingNullableField)
            }
        }
        for fixture in [invalidCID] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CarriedPairingDecisionReply.self, from: Data(fixture.utf8))
            }
        }
    }
}

@Suite("Carried pairing control response classes", .serialized)
struct CarriedPairingControlResponseClassTests {
    private func client() -> URLSessionCarriedPairingControlClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CarriedPairingScriptedURLProtocol.self]
        return URLSessionCarriedPairingControlClient(session: URLSession(configuration: configuration))
    }

    private func migrationStateError(status: Int, body: String?) async -> CarriedPairingControlError? {
        CarriedPairingScriptedURLProtocol.script(status: status, body: body.map { Data($0.utf8) } ?? Data())
        do {
            _ = try await client().migrationState(localPort: 1234)
            return nil
        } catch let error as CarriedPairingControlError {
            return error
        } catch {
            return nil
        }
    }

    @Test func onlyThePinnedRefusalEnvelopeIsADefiniteRefusal() async {
        #expect(await migrationStateError(status: 400, body: #"{"reason_code":"migration_request_invalid"}"#) == .refused)
        #expect(await migrationStateError(status: 400, body: #"{"reason_code":"migration_protocol_unsupported"}"#) == .unsupported)
        #expect(await migrationStateError(status: 400, body: #"{"reason_code":"migration_forbidden"}"#) == .unavailable)
        #expect(await migrationStateError(status: 400, body: nil) == .unavailable)
        #expect(await migrationStateError(status: 403, body: nil) == .unavailable)
        #expect(await migrationStateError(status: 410, body: nil) == .unavailable)
        #expect(await migrationStateError(status: 404, body: nil) == .unsupported)
        #expect(await migrationStateError(status: 405, body: nil) == .unsupported)
        #expect(await migrationStateError(status: 404, body: #"{"reason_code":"paired_device_not_found"}"#) == .unavailable)
        #expect(await migrationStateError(status: 409, body: nil) == .conflict)
        #expect(await migrationStateError(status: 503, body: nil) == .unavailable)
    }
}

private final class CarriedPairingScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scriptedStatus = 500
    nonisolated(unsafe) private static var scriptedBody = Data()

    static func script(status: Int, body: Data) {
        lock.withLock {
            scriptedStatus = status
            scriptedBody = body
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock { (Self.scriptedStatus, Self.scriptedBody) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CarriedPairingConflictURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 409,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
