// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum JournalSetupCommand {
    static func setupArguments(journalURL: URL, skipService: Bool) -> [String] {
        var arguments = [
            "setup",
            "--jsonl",
            "--yes",
            "--skip-models",
            "--accept-existing-journal",
            "--journal",
            journalURL.path,
        ]
        if skipService {
            arguments.append("--skip-service")
        }
        return arguments
    }
}
