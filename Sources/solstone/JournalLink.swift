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
        guard let components = URLComponents(string: address) else {
            self = .unrelated
            return
        }
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()
        let isAppLink = scheme == "solstone" && host == "open"
        let isWebLink = scheme == "https"
            && host == "go.solstone.app"
            && (components.path == "/j" || components.path.hasPrefix("/j/"))
        guard isAppLink || isWebLink else {
            self = .unrelated
            return
        }
        // A query on the HTTPS `/j` link carries nothing of ours (chat apps append
        // their own), so it is ignored. Some browsers hand the app link over as
        // `solstone://open/#…`. Validate the original fragment bytes without decoding.
        let hasAllowedPath = isWebLink
            ? components.percentEncodedPath == "/j"
            : ["", "/"].contains(components.percentEncodedPath)
        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              isWebLink || components.query == nil,
              hasAllowedPath,
              parts.count == 2
        else {
            self = .invalid
            return
        }
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
