// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public protocol OnDiskJournalFileReading: Sendable {
    func directoryExists(_ path: String) async -> Bool
    func fileExists(_ path: String) async -> Bool
    func contentsOfDirectory(_ path: String) async -> [String]
}

public struct LiveOnDiskJournalFileReader: OnDiskJournalFileReading, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func directoryExists(_ path: String) async -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func fileExists(_ path: String) async -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func contentsOfDirectory(_ path: String) async -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
    }
}

public func journalDirectoryQualifies(
    at path: String,
    using reader: OnDiskJournalFileReading
) async -> Bool {
    guard await reader.directoryExists(path) else {
        return false
    }
    if Task.isCancelled {
        return false
    }

    let configPath = journalChildPath(parent: path, child: "config", isDirectory: true)
    if await reader.directoryExists(configPath) {
        return true
    }
    if Task.isCancelled {
        return false
    }

    let entries = await reader.contentsOfDirectory(path)
    for entry in entries {
        if Task.isCancelled {
            return false
        }
        let entryPath = journalChildPath(parent: path, child: entry, isDirectory: false)
        if entry.hasSuffix(".jsonl"),
           await reader.fileExists(entryPath),
           !(await reader.directoryExists(entryPath)) {
            return true
        }

        if isEightASCIIDigits(entry),
           await reader.directoryExists(entryPath) {
            return true
        }
    }

    return false
}

private func journalChildPath(parent: String, child: String, isDirectory: Bool) -> String {
    URL(fileURLWithPath: parent, isDirectory: true)
        .appendingPathComponent(child, isDirectory: isDirectory)
        .path
}

private func isEightASCIIDigits(_ value: String) -> Bool {
    let bytes = value.utf8
    return bytes.count == 8 && bytes.allSatisfy { byte in
        byte >= 48 && byte <= 57
    }
}
