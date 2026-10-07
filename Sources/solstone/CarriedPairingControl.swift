// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security
import SPLTunnel

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

struct CarriedPairingRekeyResponse: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let operationID: String
    let state: String
    let previousCID: String
    let cid: String
    let pairing: CarriedPairingPairingReply

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case state
        case previousCID = "previous_cid"
        case cid
        case pairing
    }

    init(
        protocolVersion: Int,
        operationID: String,
        state: String,
        previousCID: String,
        cid: String,
        pairing: CarriedPairingPairingReply
    ) {
        self.protocolVersion = protocolVersion
        self.operationID = operationID
        self.state = state
        self.previousCID = previousCID
        self.cid = cid
        self.pairing = pairing
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        operationID = try values.decode(String.self, forKey: .operationID)
        state = try values.decode(String.self, forKey: .state)
        previousCID = try values.decode(String.self, forKey: .previousCID)
        cid = try values.decode(String.self, forKey: .cid)
        pairing = try values.decode(CarriedPairingPairingReply.self, forKey: .pairing)
    }
}

struct CarriedPairingPairingReply: Codable, Sendable, Equatable {
    let clientCert: String
    let caChain: [String]
    let instanceID: String
    let homeLabel: String
    let fingerprint: String
    let localEndpoints: [LocalEndpoint]?
    let relayAccess: CarriedPairingRelayReply?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case clientCert = "client_cert"
        case caChain = "ca_chain"
        case instanceID = "instance_id"
        case homeLabel = "home_label"
        case fingerprint
        case localEndpoints = "local_endpoints"
        case relayAccess = "relay_access"
    }
}

struct CarriedPairingRelayReply: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let status: String
    let relayOrigin: String
    let instanceID: String
    let deviceToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case status
        case relayOrigin = "relay_origin"
        case instanceID = "instance_id"
        case deviceToken = "device_token"
        case expiresAt = "expires_at"
    }
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

struct CarriedPairingRekeyRequest: Encodable, Sendable {
    let protocolVersion = 1
    let operationID: String
    let csr: String
    let deviceLabel: String
    let clientLabel: String
    let platform = "macos"

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case csr
        case deviceLabel = "device_label"
        case clientLabel = "client_label"
        case platform
    }
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
    func rekey(localPort: Int, oldPairing: StoredPairing, candidate: CarriedPairingCandidate, deviceLabel: String) async throws -> CarriedPairingRekeyResponse
    func migrationState(localPort: Int) async throws -> CarriedPairingMigrationReply
    func decide(localPort: Int, decision: CarriedPairingDecision) async throws -> CarriedPairingDecisionReply
    func clients(localPort: Int) async throws -> [CarriedPairingClientRow]
}

struct URLSessionCarriedPairingControlClient: CarriedPairingControlRequesting {
    private let session: URLSession

    init(session: URLSession = BoundedLoopbackClient.sharedSession) {
        self.session = session
    }

    func rekey(localPort: Int, oldPairing: StoredPairing, candidate: CarriedPairingCandidate, deviceLabel: String) async throws -> CarriedPairingRekeyResponse {
        let requestBody = CarriedPairingRekeyRequest(
            operationID: candidate.operationID,
            csr: candidate.csrPEM,
            deviceLabel: Self.validatedDeviceLabel(deviceLabel),
            clientLabel: SPLRuntime.clientInfo.userAgent
        )
        let reply: CarriedPairingRekeyResponse = try await send(
            localPort: localPort,
            path: "/app/network/api/clients/self/rekey",
            method: "POST",
            body: try JSONEncoder().encode(requestBody)
        )
        guard Self.rekeyEnvelopeMatches(reply, candidate: candidate, oldPairing: oldPairing),
              let pairing = try? Self.pairing(from: reply.pairing, privateKeyPEM: candidate.privateKeyPEM),
              pairing.fingerprint == reply.cid else { throw CarriedPairingControlError.invalidResponse }
        return reply
    }

    func migrationState(localPort: Int) async throws -> CarriedPairingMigrationReply {
        let reply: CarriedPairingMigrationReply = try await send(localPort: localPort, path: "/app/network/api/clients/self/migration", method: "GET", body: nil)
        guard reply.protocolVersion == 1 else { throw CarriedPairingControlError.invalidResponse }
        return reply
    }

    func decide(localPort: Int, decision: CarriedPairingDecision) async throws -> CarriedPairingDecisionReply {
        guard let choice = decision.choice else { throw CarriedPairingControlError.invalidResponse }
        let reply: CarriedPairingDecisionReply = try await send(
            localPort: localPort,
            path: "/app/network/api/clients/self/migration",
            method: "PUT",
            body: try JSONEncoder().encode(CarriedPairingDecisionRequest(
                operationID: decision.decisionID,
                choice: choice,
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

    static func pairing(from reply: CarriedPairingPairingReply, privateKeyPEM: String) throws -> StoredPairing {
        let clientCertificates = try CertChain.certificates(fromPEM: reply.clientCert)
        guard let leaf = clientCertificates.first,
              "sha256:\(CertChain.sha256Fingerprint(of: leaf))" == reply.fingerprint,
              let certificateKey = SecCertificateCopyKey(leaf) else { throw CarriedPairingControlError.invalidResponse }
        var keyError: Unmanaged<CFError>?
        guard let certificatePublicData = SecKeyCopyExternalRepresentation(certificateKey, &keyError) as Data? else {
            throw CarriedPairingControlError.invalidResponse
        }
        let privateKey: P256.Signing.PrivateKey
        do { privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM) }
        catch { throw CarriedPairingControlError.invalidResponse }
        guard privateKey.publicKey.x963Representation == certificatePublicData else {
            throw CarriedPairingControlError.invalidResponse
        }

        let caPEM = reply.caChain.joined(separator: "\n")
        let caCertificates = try CertChain.certificates(fromPEM: caPEM)
        guard let ca = caCertificates.first,
              try CertChain.jidFromSPKI(CertChain.canonicalP256SubjectPublicKeyInfoDER(certificate: ca)) == reply.instanceID else {
            throw CarriedPairingControlError.invalidResponse
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(clientCertificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust,
              SecTrustSetAnchorCertificates(trust, caCertificates as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            throw CarriedPairingControlError.invalidResponse
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            throw CarriedPairingControlError.invalidResponse
        }
        let relayEnrollment: RelayEnrollment
        if let relay = reply.relayAccess {
            guard relay.protocolVersion == 2,
                  relay.status == "ready",
                  relay.instanceID == reply.instanceID,
                  URL(string: relay.relayOrigin)?.scheme != nil,
                  !relay.deviceToken.isEmpty else { throw CarriedPairingControlError.invalidResponse }
            relayEnrollment = .enrolled(deviceToken: relay.deviceToken, expiresAt: relay.expiresAt)
        } else {
            relayEnrollment = .unavailable
        }
        return StoredPairing(
            instanceID: reply.instanceID,
            homeLabel: reply.homeLabel,
            relayEndpoint: reply.relayAccess?.relayOrigin ?? "",
            fingerprint: reply.fingerprint,
            clientCertPEM: reply.clientCert,
            clientKeyPEM: privateKeyPEM,
            caChainPEM: caPEM,
            relayEnrollment: relayEnrollment,
            localEndpoints: reply.localEndpoints ?? [],
            pairedAt: Date()
        )
    }

    /// The schema bounds `device_label` to 1...80 code points.
    static let maxDeviceLabelLength = 80

    static func validatedDeviceLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxDeviceLabelLength)))
        return bounded.isEmpty ? "solstone" : bounded
    }

    private struct ReasonEnvelope: Decodable {
        let reasonCode: String?

        enum CodingKeys: String, CodingKey {
            case reasonCode = "reason_code"
        }
    }

    /// Only the pinned refusal envelopes are definite refusals. A journal that
    /// no longer lists the old device answers 403 `migration_forbidden`; no
    /// retry can succeed, so the owner is asked to pair again rather than told
    /// the journal is unreachable. The other pinned refusals mean this device
    /// sent something the journal will never accept, with the same answer. A
    /// missing route without a migration reason is an older journal, 409 is an
    /// outcome to reconcile, and every other answer is unknown: the pairing is
    /// kept and the step retries later.
    static func controlError(status: Int, body: Data) -> CarriedPairingControlError {
        let reason = (try? JSONDecoder().decode(ReasonEnvelope.self, from: body))?.reasonCode
        switch (status, reason) {
        case (400, "migration_protocol_unsupported"): return .unsupported
        case (400, "migration_request_invalid"),
             (400, "migration_csr_invalid"),
             (400, "migration_key_not_fresh"),
             (403, "migration_forbidden"),
             (403, "migration_replay_forbidden"):
            return .refused
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

    static func rekeyEnvelopeMatches(
        _ reply: CarriedPairingRekeyResponse,
        candidate: CarriedPairingCandidate,
        oldPairing: StoredPairing
    ) -> Bool {
        reply.protocolVersion == 1
            && reply.operationID == candidate.operationID
            && reply.state == "pending"
            && candidate.previousFingerprint == oldPairing.fingerprint
            && reply.previousCID == candidate.previousFingerprint
            && Self.validCID(reply.cid)
    }
}
