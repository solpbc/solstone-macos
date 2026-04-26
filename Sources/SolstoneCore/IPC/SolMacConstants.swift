// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum SolMacIPCConstants {
    /// If the .app is ever sandboxed, this moves to `Library/Containers/app.solstone.observer/Data/Library/Application Support/Solstone/sol-mac.sock`.
    public static var socketURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Solstone/sol-mac.sock")
    }

    public static let teamID = "7QCG8V4M6H"
    public static let cliIdentifier = "app.solstone.observer.cli"
    public static let appBundleIdentifier = "app.solstone.observer"
    public static let currentProtocolVersion: Int = 1
    public static let minSupportedClientVersion: Int = 1
}
