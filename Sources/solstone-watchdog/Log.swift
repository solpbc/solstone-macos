// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os

extension Logger {
    private static let subsystem = "app.solstone.observer.watchdog"

    static let watchdog = Logger(subsystem: subsystem, category: "watchdog")
}
