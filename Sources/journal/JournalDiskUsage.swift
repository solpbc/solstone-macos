// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct JournalDiskUsage: Sendable {
    func calculateBytes(under root: URL) async -> Int64 {
        await Self.calculateBytes(under: root)
    }

    static func calculateBytes(under root: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return Int64(0)
            }

            var totalSize: Int64 = 0
            while let fileURL = enumerator.nextObject() as? URL {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let fileSize = values.fileSize else {
                    continue
                }
                totalSize += Int64(fileSize)
            }
            return totalSize
        }.value
    }
}
