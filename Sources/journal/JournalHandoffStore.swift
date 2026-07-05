// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

protocol JournalHandoffStoring: Sendable {
    func exists() -> Bool
    func load() throws -> JournalHandoff?
    func consume() throws
}

struct JournalHandoffStore: JournalHandoffStoring, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager

    init(
        applicationSupportBaseURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) {
        self.url = JournalHandoffFile.url(applicationSupportBaseURL: applicationSupportBaseURL)
        self.fileManager = fileManager
    }

    func exists() -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func load() throws -> JournalHandoff? {
        guard exists() else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JournalHandoff.self, from: data)
    }

    func consume() throws {
        guard exists() else { return }
        try fileManager.removeItem(at: url)
    }
}
