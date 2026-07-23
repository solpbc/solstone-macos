// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum TunnelAddressClassifier {
    static func isIPv6ULA(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized.hasPrefix("fc") || normalized.hasPrefix("fd")
    }

    static func isRFC1918IPv4Literal(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (10, _), (172, 16...31), (192, 168):
            return true
        default:
            return false
        }
    }
}
