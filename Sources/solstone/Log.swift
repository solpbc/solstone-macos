// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os

/// Unified logging via macOS os.Logger
///
/// Use `Logger.<category>.<level>(...)` at call sites for compile-time
/// optimized logging with per-value privacy control and accurate source location.
///
/// View logs with:
///   log stream --predicate 'subsystem == "app.solstone.observer"' --level debug
///   log show --predicate 'subsystem == "app.solstone.observer"' --last 1h
///
/// Filter by category:
///   log stream --predicate 'subsystem == "app.solstone.observer" AND category == "audio"'
///
/// Or use Console.app and filter by subsystem "app.solstone.observer"
extension Logger {
    private static let subsystem = "app.solstone.observer"

    static let general = Logger(subsystem: subsystem, category: "general")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let upload = Logger(subsystem: subsystem, category: "upload")
    static let setup = Logger(subsystem: subsystem, category: "setup")
    static let storage = Logger(subsystem: subsystem, category: "storage")
}
