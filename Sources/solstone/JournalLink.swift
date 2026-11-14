// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal enum JournalLink: Equatable {
    case unrelated
    case invalid
    case destination(JournalWindowDestination)

    init(_ raw: String) {
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0])
        guard let components = URLComponents(string: address),
              (components.scheme?.lowercased() == "solstone" && components.host?.lowercased() == "open")
                || (components.scheme?.lowercased() == "https"
                    && components.host?.lowercased() == "go.solstone.app"
                    && components.path.hasPrefix("/j"))
        else {
            self = .unrelated
            return
        }
        let allowedAddresses = ["solstone://open", "solstone://open/", "https://go.solstone.app/j"]
        guard allowedAddresses.contains(address.lowercased()), parts.count == 2 else {
            self = .invalid
            return
        }
        // Validate the original bytes. In particular, percent escapes are not decoded.
        let token = parts[1]
        let fields = token.split(separator: "~", omittingEmptySubsequences: false)
        guard (1...2).contains(fields.count),
              (1...512).contains(fields[0].utf8.count),
              fields[0].utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 45 || byte == 95
              }),
              fields.count == 1 || (fields[1].utf8.count == 6
                && fields[1].utf8.allSatisfy({ (48...57).contains($0) })),
              let destination = JournalWindowDestination(path: "/app/open/" + token)
        else {
            self = .invalid
            return
        }
        self = .destination(destination)
    }
}
