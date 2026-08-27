// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os

extension Logger {
    static let journalRuntimeEntryReceipts = Logger(
        subsystem: "app.solstone.journal",
        category: "runtime-entry-receipts"
    )
}
