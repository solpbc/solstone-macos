// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum SolstoneIdentity {
    public static var applicationSupportURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Solstone")
    }

    public static let bundleIdentifier = "app.solstone.observer"
    public static let teamIdentifier = "7QCG8V4M6H"
}
