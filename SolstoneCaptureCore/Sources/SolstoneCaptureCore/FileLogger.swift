// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// File-based logger with rotation (keeps last N log files)
public final class FileLogger: @unchecked Sendable {
    public static let shared = FileLogger()

    private var fileHandle: FileHandle?
    private let maxLogFiles = 5
    private let logDirectory: URL
    private let lock = NSLock()

    private init() {
        // ~/Library/Application Support/Solstone/logs/
        logDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Solstone/logs")
    }

    /// Start logging - creates log directory, rotates old logs, opens new log file
    public func start() {
        lock.lock()
        defer { lock.unlock() }

        // Create logs directory if needed
        do {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fputs("[FileLogger] Failed to create log directory: \(error)\n", stderr)
            return
        }

        // Rotate old logs
        rotateOldLogs()

        // Create new log file with timestamp
        let timestamp = DateFormatter()
        timestamp.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "solstone-\(timestamp.string(from: Date())).log"
        let logFile = logDirectory.appendingPathComponent(filename)

        // Create and open file
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        do {
            fileHandle = try FileHandle(forWritingTo: logFile)
            if #available(macOS 10.15.4, *) {
                try fileHandle?.seekToEnd()
            }
            fputs("[FileLogger] Logging to \(logFile.path)\n", stderr)
        } catch {
            fputs("[FileLogger] Failed to open log file: \(error)\n", stderr)
            fileHandle = nil
        }
    }

    /// Write a message to the log file (thread-safe)
    public func write(_ message: String) {
        // Create timestamp outside the lock to avoid DateFormatter thread issues
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withSpaceBetweenDateAndTime, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date())

        lock.lock()
        defer { lock.unlock() }

        guard let handle = fileHandle else { return }

        let line = "\(timestamp) \(message)\n"

        if let data = line.data(using: .utf8) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                // Silently ignore write errors
            }
        }
    }

    /// Close the log file
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        try? fileHandle?.close()
        fileHandle = nil
    }

    /// Delete old log files, keeping only the most recent (maxLogFiles - 1)
    private func rotateOldLogs() {
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Filter to only .log files
        let logFiles = files.filter { $0.pathExtension == "log" }

        // Sort by modification date (oldest first)
        let sorted = logFiles.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return date1 < date2
        }

        // Delete oldest files, keeping room for the new one
        let filesToDelete = sorted.count - (maxLogFiles - 1)
        if filesToDelete > 0 {
            for i in 0..<filesToDelete {
                try? fileManager.removeItem(at: sorted[i])
            }
        }
    }
}
