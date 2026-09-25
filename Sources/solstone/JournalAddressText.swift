// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

/// How a journal address reads wherever the app shows or reports one.
///
/// Only a host and a port ever pass through here. A relay is named by its URL
/// host alone; a token, an instance ID or a relay path never reaches this type.
enum JournalAddressText {
    /// `192.168.1.20:7657`, `[fd00::1]:7657` (a `%zone` stays inside the
    /// brackets), `host.example:7657`.
    static func format(host: String, port: Int) -> String {
        var bare = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if bare.hasPrefix("["), bare.hasSuffix("]") {
            bare = String(bare.dropFirst().dropLast())
        }
        return bare.contains(":") ? "[\(bare)]:\(port)" : "\(bare):\(port)"
    }

    static func format(_ endpoint: LocalEndpoint) -> String {
        format(host: endpoint.host, port: endpoint.port)
    }

    static func relayHost(_ endpoint: URL) -> String? {
        guard let host = endpoint.host, !host.isEmpty else { return nil }
        return host
    }

    /// Distinct addresses in first-seen order.
    static func distinct(_ addresses: [String]) -> [String] {
        var seen: Set<String> = []
        return addresses.filter { seen.insert($0).inserted }
    }
}

func journalRelayValue(dialableRelayHost: String?) -> String {
    dialableRelayHost.map { UICopy.journalRelayOn(host: $0) } ?? UICopy.JOURNAL_RELAY_OFF
}

/// What a live journal connection went through.
enum JournalConnectedThrough: Sendable, Equatable {
    case address(String)
    case relay

    init(_ via: ConnectedVia) {
        switch via {
        case .lanDirect(let host, let port):
            self = .address(JournalAddressText.format(host: host, port: port))
        case .relay:
            self = .relay
        }
    }

    var text: String {
        switch self {
        case .address(let address):
            return address
        case .relay:
            return UICopy.JOURNAL_CONNECTED_THROUGH_RELAY
        }
    }
}
