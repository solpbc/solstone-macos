// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SolstoneCore

extension Logger {
    static let journalRuntimeEntryReceipts = Logger(
        subsystem: SolstoneLogSubsystem.journal,
        category: "runtime-entry-receipts"
    )
}
