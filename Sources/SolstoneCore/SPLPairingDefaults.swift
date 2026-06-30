// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum SPLPairingDefaults {
    // Production operated relay. A 0x06 pair link with selector 0x00 carries no
    // relay origin, so this default is the relay the client dials in that case.
    public static let relayEndpoint = "https://link.solstone.app"

    public static var relayEndpointURL: URL {
        URL(string: relayEndpoint)!
    }

    public static var deviceLabel: String {
        ProcessInfo.processInfo.hostName
    }
}
