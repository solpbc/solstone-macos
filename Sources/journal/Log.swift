// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SolstoneCore

extension Logger {
    private static let journalSubsystem = SolstoneLogSubsystem.journal

    static let journalApp = Logger(subsystem: journalSubsystem, category: "app")
    static let journalSupervisor = Logger(subsystem: journalSubsystem, category: "supervisor")
    static let updates = Logger(subsystem: journalSubsystem, category: "updates")
}
