// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SolstoneCore

extension Logger {
    private static let subsystem = WatchdogConfiguration().loggerSubsystem

    static let watchdog = Logger(subsystem: subsystem, category: "watchdog")
}
