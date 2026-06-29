// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

internal enum BundledJournalEndpoint {
    static func isBundledServiceURL(_ serverURL: String?) -> Bool {
        guard let serverURL,
              let candidate = URL(string: serverURL),
              let host = candidate.host?.lowercased(),
              let port = candidate.port,
              let bundledPort = URL(string: ServiceMode.bundledServiceURL)?.port else {
            return false
        }
        return (host == "localhost" || host == "127.0.0.1") && port == bundledPort
    }
}
