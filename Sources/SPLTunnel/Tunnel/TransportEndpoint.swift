// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let transportLog = Logger(subsystem: "app.solstone.observer.spl", category: "transport")

public enum TransportEndpoint: Sendable, Equatable {
    case lan(host: String, port: Int, scope: String, unpinnedInterface: Bool)
    case relay(endpoint: URL, instanceID: String, deviceToken: String)

    public static func lan(host: String, port: Int, scope: String) -> TransportEndpoint {
        .lan(host: host, port: port, scope: scope, unpinnedInterface: false)
    }

    public static func candidates(for pairing: StoredPairing) -> [TransportEndpoint] {
        let local = pairing.localEndpoints.flatMap { endpoint -> [TransportEndpoint] in
            let pinned = TransportEndpoint.lan(host: endpoint.host, port: endpoint.port, scope: endpoint.scope)
            guard TunnelAddressClassifier.isRFC1918IPv4Literal(endpoint.host) else {
                return [pinned]
            }
            // RFC1918 names are ambiguous across networks. The pinned primary fails inner-TLS
            // handshake on a wrong host and falls through; this unpinned duplicate keeps VPN paths reachable.
            return [
                pinned,
                TransportEndpoint.lan(
                    host: endpoint.host,
                    port: endpoint.port,
                    scope: endpoint.scope,
                    unpinnedInterface: true
                ),
            ]
        }

        guard case .enrolled(let deviceToken, _) = pairing.relayEnrollment else {
            transportLog.debug("relay transport unavailable; using lan candidates only")
            return local
        }

        guard !deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            transportLog.debug("relay device token blank; using lan candidates only")
            return local
        }

        guard let relayEndpoint = URL(string: pairing.relayEndpoint) else {
            transportLog.error("relay endpoint invalid; using lan candidates only")
            return local
        }

        return local + [
            .relay(
                endpoint: relayEndpoint,
                instanceID: pairing.instanceID,
                deviceToken: deviceToken
            ),
        ]
    }

    var isDirect: Bool {
        if case .lan = self {
            return true
        }
        return false
    }

    var unpinnedInterface: Bool {
        guard case .lan(_, _, _, let unpinned) = self else {
            return false
        }
        return unpinned
    }

    var displayScope: String {
        guard case .lan(_, _, let scope, _) = self else {
            return ""
        }
        return scope
    }

    var logDescription: String {
        switch self {
        case .lan(let host, let port, _, _):
            let mode = unpinnedInterface ? " unpinned=true" : ""
            return "lan \(host):\(port) scope=\(displayScope)\(mode)"
        case .relay(let endpoint, _, _):
            let scheme = endpoint.scheme ?? "unknown"
            let host = endpoint.host ?? "unknown"
            let port = endpoint.port.map(String.init) ?? "default"
            return "relay \(scheme)://\(host):\(port)"
        }
    }

    var connectedVia: ConnectedVia {
        switch self {
        case .lan(let host, let port, _, _):
            .lanDirect(host: host, port: port)
        case .relay(let endpoint, _, _):
            .relay(endpoint: endpoint)
        }
    }
}

public protocol ByteTransport: Sendable {
    var transportKind: String { get }

    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func close() async
}
