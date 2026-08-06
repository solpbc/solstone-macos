// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SolstoneCore

extension Logger {
    static let watchdogBootstrap = Logger(subsystem: "app.solstone.watchdog", category: "watchdog")

    static func watchdog(for product: WatchdogProduct) -> Logger {
        Logger(subsystem: product.loggerSubsystem, category: "watchdog")
    }
}
