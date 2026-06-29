// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let refreshLog = Logger(subsystem: "app.solstone.observer.spl", category: "device-token")

public enum DeviceTokenRefreshResult: Sendable, Equatable {
    case refreshed(StoredPairing)
    case notNeeded(StoredPairing)
    case transientFailure(StoredPairing)
    case definitiveAuthFailure
}

public struct DeviceTokenRefresher: Sendable {
    private let session: URLSession?

    public init(session: URLSession? = nil) {
        self.session = session
    }

    public func refreshIfNeeded(pairing: StoredPairing, now: Date) async -> DeviceTokenRefreshResult {
        guard case .enrolled(let deviceToken, _) = pairing.relayEnrollment else {
            return .notNeeded(pairing)
        }
        guard DeviceTokenClaims.needsRefresh(token: deviceToken, now: now) else {
            return .notNeeded(pairing)
        }
        return await refreshNow(pairing: pairing)
    }

    public func refreshNow(pairing: StoredPairing) async -> DeviceTokenRefreshResult {
        guard case .enrolled(let deviceToken, _) = pairing.relayEnrollment else {
            return .notNeeded(pairing)
        }
        guard let relayEndpoint = URL(string: pairing.relayEndpoint) else {
            refreshLog.error("device token refresh skipped: invalid relay endpoint")
            return .transientFailure(pairing)
        }

        let request: URLRequest
        do {
            request = try Self.makeRefreshRequest(
                relayEndpoint: relayEndpoint,
                deviceToken: deviceToken,
                userAgent: PairClient.userAgent()
            )
        } catch {
            refreshLog.error("device token refresh request build failed: \(String(describing: error), privacy: .public)")
            return .transientFailure(pairing)
        }

        let relaySession = session ?? URLSession.shared
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await relaySession.data(for: request)
        } catch {
            refreshLog.error("device token refresh network failed: \(String(describing: error), privacy: .public)")
            return .transientFailure(pairing)
        }

        guard let http = response as? HTTPURLResponse else {
            refreshLog.error("device token refresh failed: non-http response")
            return .transientFailure(pairing)
        }

        switch http.statusCode {
        case 200:
            do {
                let relayResponse = try PairClient.decodeRelayResponse(data: data)
                return .refreshed(pairing.updatingRelayEnrollment(
                    deviceToken: relayResponse.deviceToken,
                    expiresAt: relayResponse.expiresAt
                ))
            } catch {
                refreshLog.error("device token refresh decode failed")
                return .transientFailure(pairing)
            }
        case 401:
            if Self.errorReason(from: data) == "expired" {
                return .definitiveAuthFailure
            }
            return .transientFailure(pairing)
        case 403, 404:
            return .definitiveAuthFailure
        case 500...599:
            return .transientFailure(pairing)
        default:
            return .transientFailure(pairing)
        }
    }

    static func makeRefreshRequest(
        relayEndpoint: URL,
        deviceToken: String,
        userAgent: String = PairClient.userAgent()
    ) throws -> URLRequest {
        var request = URLRequest(url: try PairClient.controlURL(relayEndpoint, path: "token/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(RelayRefreshRequest(deviceToken: deviceToken))
        return request
    }

    private static func errorReason(from data: Data) -> String? {
        try? JSONDecoder().decode(RelayErrorResponse.self, from: data).reason
    }
}

private struct RelayRefreshRequest: Encodable {
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
    }
}

private struct RelayErrorResponse: Decodable {
    let reason: String?
}

private extension StoredPairing {
    func updatingRelayEnrollment(deviceToken: String, expiresAt: String?) -> StoredPairing {
        StoredPairing(
            instanceID: instanceID,
            homeLabel: homeLabel,
            relayEndpoint: relayEndpoint,
            fingerprint: fingerprint,
            clientCertPEM: clientCertPEM,
            clientKeyPEM: clientKeyPEM,
            caChainPEM: caChainPEM,
            relayEnrollment: .enrolled(deviceToken: deviceToken, expiresAt: expiresAt),
            localEndpoints: localEndpoints,
            pairedAt: pairedAt
        )
    }
}
