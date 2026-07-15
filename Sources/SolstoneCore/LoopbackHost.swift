// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum LoopbackHost {
    public static func isLoopbackURL(_ serverURL: String?) -> Bool {
        guard let serverURL,
              let candidate = URL(string: serverURL) else {
            return false
        }
        return isLoopbackHost(candidate.host)
    }

    public static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized == "localhost" || normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
            return true
        }

        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]),
              first == 127 else {
            return false
        }
        return octets.allSatisfy { octet in
            guard let value = Int(octet) else { return false }
            return 0...255 ~= value
        }
    }
}

public enum BundledJournalEndpoint {
    public static func isBundledServiceURL(_ serverURL: String?) -> Bool {
        guard let serverURL,
              let candidate = URL(string: serverURL),
              let port = candidate.port,
              let bundledPort = URL(string: ServiceMode.bundledServiceURL)?.port else {
            return false
        }
        return LoopbackHost.isLoopbackHost(candidate.host) && port == bundledPort
    }
}
