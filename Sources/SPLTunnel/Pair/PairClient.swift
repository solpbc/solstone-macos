// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct PairClient: Sendable {
    private let session: URLSession?

    public init(session: URLSession? = nil) {
        self.session = session
    }

    public func pair(pairURL: PairURL, deviceLabel: String, relayEndpoint: URL) async throws -> StoredPairing {
        let generated: (csrPEM: String, privateKeyPEM: String)
        do {
            generated = try CryptoCSR.generate(deviceLabel: deviceLabel)
        } catch {
            throw PairError.csrBuildFailed
        }

        let lanResponse = try await postLAN(pairURL: pairURL, csrPEM: generated.csrPEM, deviceLabel: deviceLabel)
        let relayResponse = try await postRelay(relayEndpoint: relayEndpoint, lanResponse: lanResponse)
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
            caChainPEM: Self.joinPEMChain(lanResponse.caChain),
            deviceToken: relayResponse.deviceToken,
            localEndpoints: lanResponse.localEndpoints,
            pairedAt: Date()
        )
    }

    private func postLAN(pairURL: PairURL, csrPEM: String, deviceLabel: String) async throws -> LANPairResponse {
        let request = try Self.makeLANRequest(pairURL: pairURL, csrPEM: csrPEM, deviceLabel: deviceLabel)
        let session: URLSession
        if let injected = self.session {
            session = injected
        } else {
            let delegate = PinningDelegate(expectedFingerprint: pairURL.caFingerprintHex)
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

        switch http.statusCode {
        case 200:
            do {
                return try Self.decodeLANResponse(data: data)
            } catch {
                throw PairError.lanResponseInvalid(status: http.statusCode)
            }
        case 400, 404:
            throw PairError.lanResponseInvalid(status: http.statusCode)
        case 410:
            throw PairError.nonceExpired
        case 500...599:
            throw PairError.lanRequestFailed(underlying: nil)
        default:
            throw PairError.lanResponseInvalid(status: http.statusCode)
        }
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

    static func makeLANRequest(pairURL: PairURL, csrPEM: String, deviceLabel: String) throws -> URLRequest {
        var request = URLRequest(url: pairURL.homeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LANPairRequest(
            nonce: pairURL.token,
            csr: csrPEM,
            deviceLabel: deviceLabel
        ))
        return request
    }

    static func makeRelayRequest(relayEndpoint: URL, response: LANPairResponse, userAgent: String) throws -> URLRequest {
        var request = URLRequest(url: normalizedRelayEndpoint(relayEndpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(RelayEnrollRequest(
            instanceID: response.instanceID,
            clientCert: response.clientCert,
            homeAttestation: response.homeAttestation
        ))
        return request
    }

    static func decodeLANResponse(data: Data) throws -> LANPairResponse {
        try JSONDecoder().decode(LANPairResponse.self, from: data)
    }

    static func decodeRelayResponse(data: Data) throws -> RelayEnrollResponse {
        try JSONDecoder().decode(RelayEnrollResponse.self, from: data)
    }

    static func normalizedRelayEndpoint(_ url: URL) -> URL {
        let base = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/enroll/device") ?? url
    }

    static func userAgent() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
        return "solstone-macos/\(version)"
    }

    private static func joinPEMChain(_ chain: [String]) -> String {
        chain.map { pem in
            pem.hasSuffix("\n") ? pem : "\(pem)\n"
        }.joined()
    }
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
    let clientCert: String
    let homeAttestation: String

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case clientCert = "client_cert"
        case homeAttestation = "home_attestation"
    }
}

struct RelayEnrollResponse: Decodable {
    let deviceToken: String
    let expiresAt: String

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
    case relayRequestFailed(underlying: (any Error & Sendable)?)
    case relayResponseInvalid(status: Int?)
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
        case .relayRequestFailed:
            return "couldn't reach the relay."
        case .relayResponseInvalid:
            return "the relay returned an invalid pairing response."
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
             (.relayRequestFailed, .relayRequestFailed):
            return true
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
