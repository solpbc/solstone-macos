// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum SPLPairingDefaults {
    public static let relayEndpoint = "https://spl-relay-staging.jer-3f2.workers.dev"

    public static var relayEndpointURL: URL {
        URL(string: relayEndpoint)!
    }

    public static var deviceLabel: String {
        ProcessInfo.processInfo.hostName
    }
}
