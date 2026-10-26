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

    /// The `app_version` this app reports to the journal, in the about block's
    /// `<version> (<build>)` form, e.g. "2.0.48 (128)". The journal shows it verbatim.
    /// Not for owner-facing display in this app.
    @usableFromInline
    static var reported: String {
        reported(short: short, build: build)
    }

    /// The journal's `app_version` limit, in UTF-8 bytes.
    static let reportedMaxBytes = 64

    /// `short (build)` when the build is real and the result fits the journal's
    /// 64-byte limit; the short version alone when the build is missing, the
    /// "unknown" placeholder, or the combined value would be too long.
    static func reported(short: String, build: String) -> String {
        guard !build.isEmpty, build != "unknown" else { return short }
        let combined = "\(short) (\(build))"
        guard combined.utf8.count <= reportedMaxBytes else { return short }
        return combined
    }
}
