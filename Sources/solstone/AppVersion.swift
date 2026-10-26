// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The running app's short marketing version (CFBundleShortVersionString), e.g. "1.3.17".
/// Single source of truth for product-display version reads (About, Settings → Help, Settings → Status).
@usableFromInline
enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    /// The `app_version` this app reports to the journal: the short version with the
    /// build as semver build metadata, e.g. "2.0.48+128". Not for owner-facing display.
    @usableFromInline
    static var reported: String {
        reported(short: short, build: build)
    }

    /// `short+build` when the build is real; the short version alone when it is
    /// missing or the "unknown" placeholder.
    static func reported(short: String, build: String) -> String {
        guard !build.isEmpty, build != "unknown" else { return short }
        return "\(short)+\(build)"
    }
}
