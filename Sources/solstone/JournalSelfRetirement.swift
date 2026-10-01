// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import SPLTunnel
import os

private let pairingLog = Logger(subsystem: SolstoneLogSubsystem.observerSPL, category: "pairing")

public struct JournalSelfRetirement: Sendable {
    public enum Outcome: Equatable, Sendable {
        case retired
        case notTold
    }

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport
    private let timeout: Duration

    public init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        timeout: Duration = .seconds(10)
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func retire(pairing: StoredPairing, localPort: Int) async -> Outcome {
        let certificates: [SecCertificate]
        do {
            certificates = try CertChain.certificates(fromPEM: pairing.clientCertPEM)
        } catch {
            pairingLog.error("journal client retirement cert parse failed: \(String(describing: type(of: error)), privacy: .public)")
            return .notTold
        }

        guard let firstCert = certificates.first else {
            pairingLog.error("journal client retirement cert chain empty")
            return .notTold
        }

        let cid = CertChain.sha256Fingerprint(of: firstCert)
        let urlString = "http://127.0.0.1:\(localPort)/app/network/api/clients/sha256%3A\(cid)"
        guard let url = URL(string: urlString) else {
            pairingLog.error("journal client retirement invalid url")
            return .notTold
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.attachLoopbackCapability()
        let outgoingRequest = request

        do {
            let (_, response) = try await BoundedLoopbackClient.withTaskDeadline(timeout) {
                try await transport(outgoingRequest)
            }

            guard let http = response as? HTTPURLResponse else {
                pairingLog.error("journal client retirement non-http response: \(String(describing: type(of: response)), privacy: .public)")
                return .notTold
            }

            switch http.statusCode {
            case 200, 204, 404:
                return .retired
            default:
                pairingLog.error("journal client retirement failed status: \(http.statusCode, privacy: .public)")
                return .notTold
            }
        } catch {
            pairingLog.error("journal client retirement failed: \(String(describing: type(of: error)), privacy: .public)")
            return .notTold
        }
    }
}
