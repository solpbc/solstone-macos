// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

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

    /// `deviceLabel`, read on a background queue. The read reverse-resolves this Mac's
    /// addresses, over mDNS on a local network; on a first run that lookup is what raises
    /// macOS's local network prompt, and it does not return until the owner answers. On the
    /// main thread it froze the app for as long as the prompt was up.
    public static func deviceLabelOffMainThread(
        _ read: @escaping @Sendable () -> String = { deviceLabel }
    ) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: read())
            }
        }
    }
}
