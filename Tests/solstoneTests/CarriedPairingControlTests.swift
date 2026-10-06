// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Carried pairing control decoding")
struct CarriedPairingControlTests {
    private let cid = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let operationID = "123e4567-e89b-42d3-a456-426614174000"

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

    @Test func rekeyEnvelopeBindsOperationProtocolStateAndCurrentCID() {
        let oldPairing = pairing(fingerprint: cid)
        let candidate = CarriedPairingCandidate(
            operationID: operationID,
            csrPEM: "candidate-csr",
            privateKeyPEM: "candidate-key",
            previousFingerprint: cid,
            previousRevision: "revision-a",
            previousInstanceID: oldPairing.instanceID
        )
        let valid = CarriedPairingRekeyResponse(
            protocolVersion: 1,
            operationID: operationID,
            state: "pending",
            previousCID: cid,
            cid: cid,
            pairing: CarriedPairingPairingReply(
                clientCert: "certificate",
                caChain: [],
                instanceID: oldPairing.instanceID,
                homeLabel: "test-home",
                fingerprint: cid,
                localEndpoints: nil,
                relayAccess: nil
            )
        )

        #expect(URLSessionCarriedPairingControlClient.rekeyEnvelopeMatches(
            valid,
            candidate: candidate,
            oldPairing: oldPairing
        ))

        var invalid = valid
        invalid = CarriedPairingRekeyResponse(protocolVersion: 2, operationID: valid.operationID, state: valid.state,
            previousCID: valid.previousCID, cid: valid.cid, pairing: valid.pairing)
        #expect(!URLSessionCarriedPairingControlClient.rekeyEnvelopeMatches(invalid, candidate: candidate, oldPairing: oldPairing))
        invalid = CarriedPairingRekeyResponse(protocolVersion: 1, operationID: "different-operation", state: valid.state,
            previousCID: valid.previousCID, cid: valid.cid, pairing: valid.pairing)
        #expect(!URLSessionCarriedPairingControlClient.rekeyEnvelopeMatches(invalid, candidate: candidate, oldPairing: oldPairing))
        invalid = CarriedPairingRekeyResponse(protocolVersion: 1, operationID: valid.operationID, state: "new_device",
            previousCID: valid.previousCID, cid: valid.cid, pairing: valid.pairing)
        #expect(!URLSessionCarriedPairingControlClient.rekeyEnvelopeMatches(invalid, candidate: candidate, oldPairing: oldPairing))
        invalid = CarriedPairingRekeyResponse(protocolVersion: 1, operationID: valid.operationID, state: valid.state,
            previousCID: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            cid: valid.cid, pairing: valid.pairing)
        #expect(!URLSessionCarriedPairingControlClient.rekeyEnvelopeMatches(invalid, candidate: candidate, oldPairing: oldPairing))
        invalid = CarriedPairingRekeyResponse(protocolVersion: 1, operationID: valid.operationID, state: valid.state,
            previousCID: valid.previousCID, cid: "sha256:bad", pairing: valid.pairing)
        #expect(!URLSessionCarriedPairingControlClient.rekeyEnvelopeMatches(invalid, candidate: candidate, oldPairing: oldPairing))
    }

    @Test func rekeyResponseRejectsUnexpectedEnvelopeKeys() throws {
        let valid = #"{"protocol_version":1,"operation_id":"123e4567-e89b-42d3-a456-426614174000","state":"pending","previous_cid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","cid":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pairing":{"client_cert":"certificate","ca_chain":[],"instance_id":"instance","home_label":"home","fingerprint":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#
        let withUnknownKey = valid.replacingOccurrences(of: #""pairing":{"#, with: #""unexpected":true,"pairing":{"#)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CarriedPairingRekeyResponse.self, from: Data(withUnknownKey.utf8))
        }
    }
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
