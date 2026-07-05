// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os

extension Logger {
    private static let journalSubsystem = "app.solstone.journal"

    static let journalApp = Logger(subsystem: journalSubsystem, category: "app")
    static let journalSupervisor = Logger(subsystem: journalSubsystem, category: "supervisor")
    static let updates = Logger(subsystem: journalSubsystem, category: "updates")
}
