// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum CarriedPairingControlError: Error, Equatable {
    case unavailable
    case unsupported
    case invalidResponse
    case refused
    case conflict
}

private struct CarriedPairingCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: CarriedPairingCodingKey.self)
    guard let unknown = values.allKeys.first(where: { !allowed.contains($0.stringValue) }) else { return }
    throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath + [unknown],
        debugDescription: "Unexpected response key"
    ))
}

private func decodeRequiredNullable<Value: Decodable, Key: CodingKey>(
    _ type: Value.Type,
    from values: KeyedDecodingContainer<Key>,
    forKey key: Key,
    decoder: Decoder
) throws -> Value? {
    guard values.contains(key) else {
        throw DecodingError.keyNotFound(key, .init(
            codingPath: decoder.codingPath,
            debugDescription: "Missing required response key"
        ))
    }
    return try values.decodeNil(forKey: key) ? nil : values.decode(type, forKey: key)
}

struct CarriedPairingMigrationReply: Decodable, Sendable, Equatable {
    let protocolVersion: Int
    let rekeyOperationID: String?
    let previousCID: String?
    let state: String
    let replacedCID: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol_version"
        case rekeyOperationID = "rekey_operation_id"
        case previousCID = "previous_cid"
        case state
        case replacedCID = "replaced_cid"
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        rekeyOperationID = try decodeRequiredNullable(String.self, from: values, forKey: .rekeyOperationID, decoder: decoder)
        previousCID = try decodeRequiredNullable(String.self, from: values, forKey: .previousCID, decoder: decoder)
        state = try values.decode(String.self, forKey: .state)
        replacedCID = try decodeRequiredNullable(String.self, from: values, forKey: .replacedCID, decoder: decoder)
        let validStates = ["none", "pending", "new_device", "same_device", "replaced_device"]
        guard validStates.contains(state),
              rekeyOperationID.map({ UUID(uuidString: $0) != nil }) ?? true,
              previousCID.map(URLSessionCarriedPairingControlClient.validCID) ?? true,
              replacedCID.map(URLSessionCarriedPairingControlClient.validCID) ?? true,
              (state == "none"
                ? rekeyOperationID == nil && previousCID == nil && replacedCID == nil
                : state == "pending"
                    ? rekeyOperationID != nil && previousCID != nil
                    : (rekeyOperationID == nil ? previousCID == nil : previousCID != nil)),
              (state != "replaced_device" || replacedCID != nil) else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: values, debugDescription: "Invalid migration state response")
        }
    }
}

struct CarriedPairingDecisionReply: Decodable, Sendable, Equatable {
    let protocolVersion: Int
    let operationID: String
    let state: String
    let previousCID: String?
    let cid: String
    let replacedCID: String?
    let displayLabel: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case state
        case previousCID = "previous_cid"
        case cid
        case replacedCID = "replaced_cid"
        case displayLabel = "display_label"
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        operationID = try values.decode(String.self, forKey: .operationID)
        state = try values.decode(String.self, forKey: .state)
        previousCID = try decodeRequiredNullable(String.self, from: values, forKey: .previousCID, decoder: decoder)
        cid = try values.decode(String.self, forKey: .cid)
        replacedCID = try decodeRequiredNullable(String.self, from: values, forKey: .replacedCID, decoder: decoder)
        displayLabel = try values.decode(String.self, forKey: .displayLabel)
        let validStates = ["none", "pending", "new_device", "same_device", "replaced_device"]
        guard UUID(uuidString: operationID) != nil,
              validStates.contains(state),
              previousCID.map(URLSessionCarriedPairingControlClient.validCID) ?? true,
              URLSessionCarriedPairingControlClient.validCID(cid),
              replacedCID.map(URLSessionCarriedPairingControlClient.validCID) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: values, debugDescription: "Invalid migration decision response")
        }
    }
}

struct CarriedPairingClientRow: Decodable, Sendable, Equatable {
    let cid: String
    let displayLabel: String

    enum CodingKeys: String, CodingKey {
        case cid
        case displayLabel = "display_label"
    }
}

struct CarriedPairingClientList: Decodable, Sendable, Equatable {
    let clients: [CarriedPairingClientRow]
}

struct CarriedPairingDecisionRequest: Encodable, Sendable {
    let protocolVersion = 1
    let operationID: String
    let choice: CarriedPairingChoice
    let replacesCID: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case choice
        case replacesCID = "replaces_cid"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(operationID, forKey: .operationID)
        try values.encode(choice, forKey: .choice)
        try values.encodeIfPresent(replacesCID, forKey: .replacesCID)
    }
}

protocol CarriedPairingControlRequesting: Sendable {
    func migrationState(localPort: Int) async throws -> CarriedPairingMigrationReply
    func decide(localPort: Int, decision: CarriedPairingDecision) async throws -> CarriedPairingDecisionReply
    func clients(localPort: Int) async throws -> [CarriedPairingClientRow]
}

struct URLSessionCarriedPairingControlClient: CarriedPairingControlRequesting {
    private let session: URLSession

    init(session: URLSession = BoundedLoopbackClient.sharedSession) {
        self.session = session
    }

    func migrationState(localPort: Int) async throws -> CarriedPairingMigrationReply {
        let reply: CarriedPairingMigrationReply = try await send(localPort: localPort, path: "/app/network/api/clients/self/migration", method: "GET", body: nil)
        guard reply.protocolVersion == 1 else { throw CarriedPairingControlError.invalidResponse }
        return reply
    }

    func decide(localPort: Int, decision: CarriedPairingDecision) async throws -> CarriedPairingDecisionReply {
        let reply: CarriedPairingDecisionReply = try await send(
            localPort: localPort,
            path: "/app/network/api/clients/self/migration",
            method: "PUT",
            body: try JSONEncoder().encode(CarriedPairingDecisionRequest(
                operationID: decision.decisionID,
                choice: decision.choice,
                replacesCID: decision.replacesCID
            ))
        )
        guard reply.protocolVersion == 1, reply.operationID == decision.decisionID else {
            throw CarriedPairingControlError.invalidResponse
        }
        return reply
    }

    func clients(localPort: Int) async throws -> [CarriedPairingClientRow] {
        let reply: CarriedPairingClientList = try await send(localPort: localPort, path: "/app/network/api/clients", method: "GET", body: nil)
        var ids: Set<Data> = []
        for client in reply.clients {
            guard Self.validCID(client.cid), !client.displayLabel.isEmpty,
                  ids.insert(Data(client.cid.utf8)).inserted else { throw CarriedPairingControlError.invalidResponse }
        }
        return reply.clients
    }

    private func send<Response: Decodable>(localPort: Int, path: String, method: String, body: Data?) async throws -> Response {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)\(path)") else {
            throw CarriedPairingControlError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        request.timeoutInterval = 15
        request.attachLoopbackCapability()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CarriedPairingControlError.invalidResponse }
            guard 200..<300 ~= http.statusCode else {
                throw Self.controlError(status: http.statusCode, body: data)
            }
            do { return try JSONDecoder().decode(Response.self, from: data) }
            catch { throw CarriedPairingControlError.invalidResponse }
        } catch let error as CarriedPairingControlError {
            throw error
        } catch {
            throw CarriedPairingControlError.unavailable
        }
    }

    private struct ReasonEnvelope: Decodable {
        let reasonCode: String?

        enum CodingKeys: String, CodingKey {
            case reasonCode = "reason_code"
        }
    }

    /// Only the pinned refusal envelope is a definite refusal. A missing route
    /// without a migration reason is an older journal, 409 is an outcome to
    /// reconcile, and every other answer is unknown: the pairing is kept and
    /// the step retries later.
    static func controlError(status: Int, body: Data) -> CarriedPairingControlError {
        let reason = (try? JSONDecoder().decode(ReasonEnvelope.self, from: body))?.reasonCode
        switch (status, reason) {
        case (400, "migration_protocol_unsupported"): return .unsupported
        case (400, "migration_request_invalid"): return .refused
        case (404, nil), (405, nil): return .unsupported
        case (409, _): return .conflict
        default: return .unavailable
        }
    }

    static func validCID(_ value: String) -> Bool {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
