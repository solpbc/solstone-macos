// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal enum LoopbackHost {
    static func isLocalhost(_ serverURL: String?) -> Bool {
        guard let serverURL, let host = URL(string: serverURL)?.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1"
    }
}
