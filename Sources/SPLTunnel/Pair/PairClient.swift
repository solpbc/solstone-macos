// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Crypto
import os

private let pairLog = Logger(subsystem: "app.solstone.observer.spl", category: "pair")

public struct PairClient: Sendable {
    private let session: URLSession?

    public init(session: URLSession? = nil) {
        self.session = session
    }

    public func pair(pairURL: PairURL, deviceLabel: String, relayEndpoint: URL) async throws -> StoredPairing {
        let generated = try Self.generatePairingMaterial(deviceLabel: deviceLabel)
        switch pairURL.kind {
        case .direct:
            return try await pairDirect(
                pairURL: pairURL,
                generated: generated,
                deviceLabel: deviceLabel,
                relayEndpoint: relayEndpoint
            )
        case .relay:
            return try await pairViaRelay(
                pairURL: pairURL,
                generated: generated,
                deviceLabel: deviceLabel,
                defaultRelayEndpoint: relayEndpoint
            )
        }
    }

    private func pairDirect(
        pairURL: PairURL,
        generated: PairingMaterial,
        deviceLabel: String,
        relayEndpoint: URL
    ) async throws -> StoredPairing {
        let lanResponse = try await postLAN(pairURL: pairURL, csrPEM: generated.csrPEM, deviceLabel: deviceLabel)
        let relayEnrollment = await optionalRelayEnrollment(relayEndpoint: relayEndpoint, lanResponse: lanResponse)
        return try Self.makeStoredPairing(
            lanResponse: lanResponse,
            generated: generated,
            relayEndpoint: relayEndpoint,
            relayEnrollment: relayEnrollment
        )
    }

    private func pairViaRelay(
        pairURL: PairURL,
        generated: PairingMaterial,
        deviceLabel: String,
        defaultRelayEndpoint: URL
    ) async throws -> StoredPairing {
        guard pairURL.sBytes.count == 8 else {
            throw PairError.relayResponseInvalid(status: nil)
        }

        let relayEndpoint = pairURL.relayOrigin ?? defaultRelayEndpoint
        let rk = try Self.derivePairWindowRK(sBytes: pairURL.sBytes)
        let transport = try await DialClient.dialPairRelay(
            endpoint: relayEndpoint,
            rk: rk
        )
        let lanResponse = try await Self.postPairThroughTunnel(
            transport: transport,
            caPin: pairURL.caPin,
            path: "/app/network/pair?token=\(CertChain.hex(pairURL.sBytes))",
            csrPEM: generated.csrPEM,
            deviceLabel: deviceLabel
        )
        let relayEnrollment = await optionalRelayEnrollment(relayEndpoint: relayEndpoint, lanResponse: lanResponse)
        return try Self.makeStoredPairing(
            lanResponse: lanResponse,
            generated: generated,
            relayEndpoint: relayEndpoint,
            relayEnrollment: relayEnrollment
        )
    }

    private func postLAN(pairURL: PairURL, csrPEM: String, deviceLabel: String) async throws -> LANPairResponse {
        guard let candidate = pairURL.candidates.first else {
            throw PairError.lanRequestFailed(underlying: nil)
        }
        let request = try Self.makeLANRequest(
            host: candidate.address,
            port: candidate.port,
            nonceBytes: pairURL.nonceBytes,
            csrPEM: csrPEM,
            deviceLabel: deviceLabel
        )
        let session: URLSession
        if let injected = self.session {
            session = injected
        } else {
            let delegate = PinningDelegate(expectedFingerprintBytes: pairURL.caFingerprintBytes)
            session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if (error as? URLError)?.code == .cancelled {
                throw PairError.lanCAFingerprintMismatch
            }
            throw PairError.lanRequestFailed(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PairError.lanResponseInvalid(status: nil)
        }

        return try Self.decodePairResponse(status: http.statusCode, body: data)
    }

    private func postRelay(relayEndpoint: URL, lanResponse: LANPairResponse) async throws -> RelayEnrollResponse {
        let request = try Self.makeRelayRequest(relayEndpoint: relayEndpoint, response: lanResponse, userAgent: Self.userAgent())
        let relaySession = session ?? URLSession.shared

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await relaySession.data(for: request)
        } catch {
            throw PairError.relayRequestFailed(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PairError.relayResponseInvalid(status: nil)
        }

        switch http.statusCode {
        case 200:
            do {
                return try Self.decodeRelayResponse(data: data)
            } catch {
                throw PairError.relayResponseInvalid(status: http.statusCode)
            }
        case 401, 403, 409:
            throw PairError.attestationRejected(status: http.statusCode)
        case 400, 404:
            throw PairError.relayResponseInvalid(status: http.statusCode)
        case 503:
            throw PairError.relayRequestFailed(underlying: nil)
        case 500...599:
            throw PairError.relayRequestFailed(underlying: nil)
        default:
            throw PairError.relayResponseInvalid(status: http.statusCode)
        }
    }

    private func optionalRelayEnrollment(relayEndpoint: URL, lanResponse: LANPairResponse) async -> RelayEnrollment {
        do {
            let relayResponse = try await postRelay(relayEndpoint: relayEndpoint, lanResponse: lanResponse)
            return .enrolled(deviceToken: relayResponse.deviceToken, expiresAt: relayResponse.expiresAt)
        } catch {
            pairLog.error("relay enrollment failed: \(String(describing: error), privacy: .public)")
            return .unavailable
        }
    }

    static func postPairThroughTunnel(
        transport: any ByteTransport,
        caPin: PairingCAPin,
        path: String,
        csrPEM: String,
        deviceLabel: String
    ) async throws -> LANPairResponse {
        let tls: InnerTLS
        let caSPKIDER: [UInt8]
        do {
            let pairingTLS = try await InnerTLS.connectPairingViaTransport(transport: transport, caPin: caPin)
            tls = pairingTLS.tls
            caSPKIDER = pairingTLS.caSPKIDER
        } catch InnerTLSError.peerNotPinned {
            throw PairError.lanCAFingerprintMismatch
        } catch InnerTLSError.caFingerprintMismatch {
            throw PairError.lanCAFingerprintMismatch
        }
        let mux = Multiplexer(sink: { data in
            try await tls.send(data)
        }, role: .dialer)
        let pump = Task {
            do {
                for try await chunk in tls.inbound {
                    try await mux.feedInbound(chunk)
                }
                await mux.tearDown(reason: .transportFailure)
            } catch {
                await mux.tearDown(reason: .transportFailure)
            }
        }

        do {
            let requestBody = try Self.encodePairRequestBody(csrPEM: csrPEM, deviceLabel: deviceLabel)
            let stream = try await mux.openStream()
            try await stream.write(Self.buildHTTPRequest(method: "POST", path: path, body: requestBody))
            try await stream.close()

            var responseData = Data()
            for try await chunk in stream.inbound {
                responseData.append(chunk)
            }
            let response = try Self.parseHTTPResponse(responseData)
            let lanResponse = try Self.decodePairResponse(status: response.status, body: response.body)
            try Self.verifyRelayPairResponse(lanResponse, caSPKIDER: caSPKIDER)
            await cleanupPairingTunnel(tls: tls, mux: mux, pump: pump)
            return lanResponse
        } catch {
            await cleanupPairingTunnel(tls: tls, mux: mux, pump: pump)
            throw error
        }
    }

    static func makeLANRequest(
        host: String,
        port: UInt16,
        nonceBytes: [UInt8],
        csrPEM: String,
        deviceLabel: String
    ) throws -> URLRequest {
        // Dotted-quad IPv4 plus UInt16 port and fixed path are parser-controlled.
        let url = URL(string: "https://\(host):\(port)/app/network/pair")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LANPairRequest(
            nonce: CertChain.hex(nonceBytes),
            csr: csrPEM,
            deviceLabel: deviceLabel
        ))
        return request
    }

    static func encodePairRequestBody(csrPEM: String, deviceLabel: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(TunnelPairRequest(csr: csrPEM, deviceLabel: deviceLabel))
    }

    static func derivePairWindowRK(sBytes: [UInt8]) throws -> [UInt8] {
        guard sBytes.count == 8 else {
            throw PairError.relayResponseInvalid(status: nil)
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(sBytes)),
            salt: Data(count: 32),
            info: Data("spl-pair-window-v1".utf8),
            outputByteCount: 16
        )
        return key.withUnsafeBytes { Array($0) }
    }

    static func verifyRelayPairResponse(_ response: LANPairResponse, caSPKIDER: [UInt8]) throws {
        let responseCAP256SPKI = try responseCAP256SPKI(response.caChain)
        guard responseCAP256SPKI == caSPKIDER else {
            throw PairError.relayInstanceMismatch
        }
        let expected = CertChain.jidFromSPKI(responseCAP256SPKI)
        guard response.instanceID == expected else {
            throw PairError.relayInstanceMismatch
        }
    }

    private static func responseCAP256SPKI(_ caChain: [String]) throws -> [UInt8] {
        do {
            let certificates = try CertChain.certificates(fromPEM: joinPEMChain(caChain))
            guard let caCertificate = certificates.first else {
                throw PairError.relayInstanceMismatch
            }
            return try CertChain.canonicalP256SubjectPublicKeyInfoDER(certificate: caCertificate)
        } catch let error as PairError {
            throw error
        } catch {
            throw PairError.relayInstanceMismatch
        }
    }

    static func makeRelayRequest(relayEndpoint: URL, response: LANPairResponse, userAgent: String) throws -> URLRequest {
        var request = URLRequest(url: try controlURL(relayEndpoint, path: "enroll/device"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(RelayEnrollRequest(
            instanceID: response.instanceID,
            homeAttestation: response.homeAttestation
        ))
        return request
    }

    static func buildHTTPRequest(method: String, path: String, body: Data) -> Data {
        var request = Data()
        let head = [
            "\(method) \(path) HTTP/1.1",
            "Host: spl.local",
            "User-Agent: \(userAgent())",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        request.append(Data(head.utf8))
        request.append(body)
        return request
    }

    static func decodeLANResponse(data: Data) throws -> LANPairResponse {
        try JSONDecoder().decode(LANPairResponse.self, from: data)
    }

    static func decodeRelayResponse(data: Data) throws -> RelayEnrollResponse {
        try JSONDecoder().decode(RelayEnrollResponse.self, from: data)
    }

    static func controlURL(_ base: URL, path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else {
            throw PairError.relayResponseInvalid(status: nil)
        }

        switch scheme {
        case "https", "http":
            components.scheme = scheme
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            throw PairError.relayResponseInvalid(status: nil)
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        var mergedItems = components.queryItems ?? []
        mergedItems.append(contentsOf: queryItems)
        components.queryItems = mergedItems.isEmpty ? nil : mergedItems

        guard let url = components.url else {
            throw PairError.relayResponseInvalid(status: nil)
        }
        return url
    }

    static func parseHTTPResponse(_ data: Data) throws -> PairHTTPResponse {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker),
              let headerText = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else {
            throw PairError.lanResponseInvalid(status: nil)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw PairError.lanResponseInvalid(status: nil)
        }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2,
              let status = Int(statusParts[1]) else {
            throw PairError.lanResponseInvalid(status: nil)
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var body = Data(data[range.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunkedBody(body)
        } else if let rawLength = headers["content-length"],
                  let length = Int(rawLength),
                  body.count > length {
            body = Data(body.prefix(length))
        }
        return PairHTTPResponse(status: status, headers: headers, body: body)
    }

    static func userAgent() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
        return "solstone-macos/\(version)"
    }

    private static func generatePairingMaterial(deviceLabel: String) throws -> PairingMaterial {
        do {
            let generated = try CryptoCSR.generate(deviceLabel: deviceLabel)
            return PairingMaterial(csrPEM: generated.csrPEM, privateKeyPEM: generated.privateKeyPEM)
        } catch {
            throw PairError.csrBuildFailed
        }
    }

    private static func decodePairResponse(status: Int, body: Data) throws -> LANPairResponse {
        switch status {
        case 200:
            do {
                return try decodeLANResponse(data: body)
            } catch {
                throw PairError.lanResponseInvalid(status: status)
            }
        case 400, 401, 404:
            throw PairError.lanResponseInvalid(status: status)
        case 410:
            throw PairError.nonceExpired
        case 500...599:
            throw PairError.lanRequestFailed(underlying: nil)
        default:
            throw PairError.lanResponseInvalid(status: status)
        }
    }

    private static func makeStoredPairing(
        lanResponse: LANPairResponse,
        generated: PairingMaterial,
        relayEndpoint: URL,
        relayEnrollment: RelayEnrollment
    ) throws -> StoredPairing {
        let certificates = try? CertChain.certificates(fromPEM: lanResponse.clientCert)
        guard let clientCertificate = certificates?.first else {
            throw PairError.lanResponseInvalid(status: nil)
        }

        return StoredPairing(
            instanceID: lanResponse.instanceID,
            homeLabel: lanResponse.homeLabel,
            relayEndpoint: relayEndpoint.absoluteString,
            fingerprint: "sha256:\(CertChain.sha256Fingerprint(of: clientCertificate))",
            clientCertPEM: lanResponse.clientCert,
            clientKeyPEM: generated.privateKeyPEM,
            caChainPEM: joinPEMChain(lanResponse.caChain),
            relayEnrollment: relayEnrollment,
            localEndpoints: lanResponse.localEndpoints,
            pairedAt: Date()
        )
    }

    private static func cleanupPairingTunnel(tls: InnerTLS, mux: Multiplexer, pump: Task<Void, Never>) async {
        pump.cancel()
        await mux.tearDown(reason: .normalShutdown)
        await tls.close()
    }

    private static func decodeChunkedBody(_ body: Data) throws -> Data {
        let crlf = Data("\r\n".utf8)
        var cursor = body.startIndex
        var decoded = Data()

        while cursor < body.endIndex {
            guard let lineRange = body[cursor...].range(of: crlf),
                  let line = String(data: body[cursor..<lineRange.lowerBound], encoding: .utf8) else {
                throw PairError.lanResponseInvalid(status: nil)
            }
            let sizeToken = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw PairError.lanResponseInvalid(status: nil)
            }
            cursor = lineRange.upperBound
            if size == 0 {
                return decoded
            }
            guard cursor + size <= body.endIndex else {
                throw PairError.lanResponseInvalid(status: nil)
            }
            decoded.append(body[cursor..<(cursor + size)])
            cursor += size
            guard cursor + crlf.count <= body.endIndex,
                  Data(body[cursor..<(cursor + crlf.count)]) == crlf else {
                throw PairError.lanResponseInvalid(status: nil)
            }
            cursor += crlf.count
        }

        throw PairError.lanResponseInvalid(status: nil)
    }

    private static func joinPEMChain(_ chain: [String]) -> String {
        chain.map { pem in
            pem.hasSuffix("\n") ? pem : "\(pem)\n"
        }.joined()
    }
}

struct PairingMaterial: Sendable {
    let csrPEM: String
    let privateKeyPEM: String
}

struct PairHTTPResponse: Equatable, Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

struct LANPairRequest: Encodable {
    let nonce: String
    let csr: String
    let deviceLabel: String

    enum CodingKeys: String, CodingKey {
        case nonce
        case csr
        case deviceLabel = "device_label"
    }
}

struct TunnelPairRequest: Encodable {
    let csr: String
    let deviceLabel: String

    enum CodingKeys: String, CodingKey {
        case csr
        case deviceLabel = "device_label"
    }
}

struct LANPairResponse: Decodable {
    let instanceID: String
    let homeLabel: String
    let clientCert: String
    let caChain: [String]
    let homeAttestation: String
    let fingerprint: String?
    let localEndpoints: [LocalEndpoint]

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case homeLabel = "home_label"
        case clientCert = "client_cert"
        case caChain = "ca_chain"
        case homeAttestation = "home_attestation"
        case fingerprint
        case localEndpoints = "local_endpoints"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceID = try container.decode(String.self, forKey: .instanceID)
        homeLabel = try container.decode(String.self, forKey: .homeLabel)
        clientCert = try container.decode(String.self, forKey: .clientCert)
        caChain = try container.decode([String].self, forKey: .caChain)
        homeAttestation = try container.decode(String.self, forKey: .homeAttestation)
        fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint)
        localEndpoints = try container.decodeIfPresent([LocalEndpoint].self, forKey: .localEndpoints) ?? []
    }
}

struct RelayEnrollRequest: Encodable {
    let instanceID: String
    let homeAttestation: String

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case homeAttestation = "home_attestation"
    }
}

struct RelayEnrollResponse: Decodable {
    let deviceToken: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case expiresAt = "expires_at"
    }
}

public enum PairError: Error, Equatable, LocalizedError, Sendable {
    case csrBuildFailed
    case lanRequestFailed(underlying: (any Error & Sendable)?)
    case lanCAFingerprintMismatch
    case lanResponseInvalid(status: Int?)
    case nonceExpired
    case pairingWindowClosed
    case lanCandidatesExhausted(sawCAFingerprintMismatch: Bool)
    case relayRequestFailed(underlying: (any Error & Sendable)?)
    case relayResponseInvalid(status: Int?)
    case relayInstanceMismatch
    case attestationRejected(status: Int)

    public var errorDescription: String? {
        switch self {
        case .csrBuildFailed:
            return "couldn't create the pairing request."
        case .lanRequestFailed:
            return "couldn't reach solstone on this network."
        case .lanCAFingerprintMismatch:
            return "couldn't verify this solstone."
        case .lanResponseInvalid:
            return "solstone returned an invalid pairing response."
        case .nonceExpired:
            return "this pairing code has expired. generate a new one on your solstone."
        case .pairingWindowClosed:
            return "the pairing window closed or expired."
        case .lanCandidatesExhausted:
            return "couldn't reach solstone on this network."
        case .relayRequestFailed:
            return "couldn't reach the relay."
        case .relayResponseInvalid:
            return "the relay returned an invalid pairing response."
        case .relayInstanceMismatch:
            return "the relay connected to the wrong solstone."
        case .attestationRejected:
            return "the relay rejected this pairing."
        }
    }

    public static func == (lhs: PairError, rhs: PairError) -> Bool {
        switch (lhs, rhs) {
        case (.csrBuildFailed, .csrBuildFailed),
             (.lanRequestFailed, .lanRequestFailed),
             (.lanCAFingerprintMismatch, .lanCAFingerprintMismatch),
             (.nonceExpired, .nonceExpired),
             (.pairingWindowClosed, .pairingWindowClosed),
             (.relayRequestFailed, .relayRequestFailed),
             (.relayInstanceMismatch, .relayInstanceMismatch):
            return true
        case (.lanCandidatesExhausted(let lhsSawCA), .lanCandidatesExhausted(let rhsSawCA)):
            return lhsSawCA == rhsSawCA
        case (.lanResponseInvalid(let lhsStatus), .lanResponseInvalid(let rhsStatus)):
            return lhsStatus == rhsStatus
        case (.relayResponseInvalid(let lhsStatus), .relayResponseInvalid(let rhsStatus)):
            return lhsStatus == rhsStatus
        case (.attestationRejected(let lhsStatus), .attestationRejected(let rhsStatus)):
            return lhsStatus == rhsStatus
        default:
            return false
        }
    }
}
