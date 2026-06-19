// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The running app's short marketing version (CFBundleShortVersionString), e.g. "1.3.17".
/// Single source of truth for product-display version reads (About, Settings → Help, Settings → Status).
enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
