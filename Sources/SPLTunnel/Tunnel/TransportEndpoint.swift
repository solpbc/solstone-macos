// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum TransportEndpoint: Sendable, Equatable {
    case lan(host: String, port: Int, scope: String)
    case relay(endpoint: URL, instanceID: String, deviceToken: String)

    public static func candidates(for pairing: StoredPairing) throws -> [TransportEndpoint] {
        let local = pairing.localEndpoints.map {
            TransportEndpoint.lan(host: $0.host, port: $0.port, scope: $0.scope)
        }
        guard let relayEndpoint = URL(string: pairing.relayEndpoint) else {
            throw SessionError.invalidRelayURL(pairing.relayEndpoint)
        }
        return local + [
            .relay(
                endpoint: relayEndpoint,
                instanceID: pairing.instanceID,
                deviceToken: pairing.deviceToken
            ),
        ]
    }

    var isDirect: Bool {
        if case .lan = self {
            return true
        }
        return false
    }

    var connectedVia: ConnectedVia {
        switch self {
        case .lan(let host, let port, _):
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
