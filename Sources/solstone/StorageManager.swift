// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

/// Manages file storage for capture segments
public final class StorageManager: Sendable {
    /// Base directory for all captures
    public let baseDirectory: URL
    private let listDirectoryContents: @Sendable (URL) throws -> [String]

    static let captureZoneFileName = "capture_zone.json"

    private struct CaptureZoneRecord: Codable {
        let tz: String
        let utc_offset_seconds: Int
    }

    public static var defaultBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Solstone/captures", isDirectory: true)
    }

    static func configureSegmentFormatter(_ formatter: DateFormatter) {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
    }

    /// Date formatter for directory names (YYYY-MM-DD)
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        configureSegmentFormatter(formatter)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Time formatter for segment directories (HHMMSS)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        configureSegmentFormatter(formatter)
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

    private static let civilCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private static let civilDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func nextCivilDay(after dateString: String) -> String {
        guard let date = civilDateFormatter.date(from: dateString),
              let nextDate = civilCalendar.date(byAdding: .day, value: 1, to: date) else {
            return dateString
        }
        return civilDateFormatter.string(from: nextDate)
    }

    private static func incrementStem(_ stem: String) -> (bumpedStem: String, rolledOverDay: Bool) {
        guard stem.count == 6,
              let hh = Int(stem.prefix(2)),
              let mm = Int(stem.dropFirst(2).prefix(2)),
              let ss = Int(stem.suffix(2)) else {
            return (stem, false)
        }
        var s = ss + 1
        var m = mm
        var h = hh
        var rolledOver = false
        if s >= 60 {
            s = 0
            m += 1
            if m >= 60 {
                m = 0
                h += 1
                if h >= 24 {
                    h = 0
                    rolledOver = true
                }
            }
        }
        let bumped = String(format: "%02d%02d%02d", h, m, s)
        return (bumped, rolledOver)
    }

    private static func segmentNaming(
        segmentStartTime: Date,
        timeZone: TimeZone
    ) -> (dateString: String, timePrefix: String, identifier: String, utcOffsetSeconds: Int) {
        let localDateFormatter = DateFormatter()
        localDateFormatter.locale = dateFormatter.locale
        localDateFormatter.calendar = dateFormatter.calendar
        localDateFormatter.dateFormat = dateFormatter.dateFormat
        localDateFormatter.timeZone = timeZone

        let localTimeFormatter = DateFormatter()
        localTimeFormatter.locale = timeFormatter.locale
        localTimeFormatter.calendar = timeFormatter.calendar
        localTimeFormatter.dateFormat = timeFormatter.dateFormat
        localTimeFormatter.timeZone = timeZone

        let dateString = localDateFormatter.string(from: segmentStartTime)
        let timePrefix = localTimeFormatter.string(from: segmentStartTime)
        let identifier = timeZone.identifier
        let utcOffsetSeconds = timeZone.secondsFromGMT(for: segmentStartTime)

        return (dateString, timePrefix, identifier, utcOffsetSeconds)
    }

    public init(
        baseDirectory: URL? = nil,
        listDirectoryContents: (@Sendable (URL) throws -> [String])? = nil
    ) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            // ~/Library/Application Support/Solstone/captures/
            self.baseDirectory = Self.defaultBaseDirectory
        }
        self.listDirectoryContents = listDirectoryContents ?? { url in
            try FileManager.default.contentsOfDirectory(atPath: url.path)
        }
    }

    /// Creates the base directory if it doesn't exist
    public func ensureBaseDirectoryExists() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// Creates a new segment directory and returns its URL
    /// - Parameters:
    ///   - segmentStartTime: The time when this segment starts
    ///   - timeZone: Optional explicit time zone for segment naming and capture zone recording
    /// - Returns: URL to the segment directory (with .incomplete suffix) and time prefix (HHMMSS)
    public func createSegmentDirectory(
        segmentStartTime: Date,
        timeZone: TimeZone? = nil
    ) throws -> (url: URL, timePrefix: String) {
        let initialDateString: String
        let initialTimeString: String
        let zoneRecord: CaptureZoneRecord?

        if let timeZone {
            let naming = Self.segmentNaming(segmentStartTime: segmentStartTime, timeZone: timeZone)
            initialDateString = naming.dateString
            initialTimeString = naming.timePrefix
            zoneRecord = CaptureZoneRecord(tz: naming.identifier, utc_offset_seconds: naming.utcOffsetSeconds)
        } else {
            initialDateString = Self.dateFormatter.string(from: segmentStartTime)
            initialTimeString = Self.timeFormatter.string(from: segmentStartTime)
            zoneRecord = nil
        }

        var currentDateString = initialDateString
        var currentTimeString = initialTimeString

        // Scan for existing stems in the day directory and bump on collision.
        var steps = 0
        let maxSteps = 86400 // Cap search at 24 hours of sequential bumps

        var cachedEntries: (day: String, entries: [String])? = nil

        func entriesForDay(_ dayString: String) -> [String]? {
            if let cached = cachedEntries, cached.day == dayString {
                return cached.entries
            }
            let dayDir = baseDirectory.appendingPathComponent(dayString, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dayDir.path, isDirectory: &isDir), isDir.boolValue else {
                cachedEntries = (dayString, [])
                return []
            }
            do {
                let entries = try listDirectoryContents(dayDir)
                cachedEntries = (dayString, entries)
                return entries
            } catch {
                Logger.storage.warning("Failed to list capture directory \(dayString, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }

        while steps < maxSteps {
            let isOriginal = (currentDateString == initialDateString)
            guard let entries = entriesForDay(currentDateString) else {
                // Listing failed: if original day, do not bump; if later civil day, exclusive-create 000000 on that day.
                if isOriginal {
                    currentTimeString = initialTimeString
                } else {
                    currentTimeString = "000000"
                }
                break
            }

            let isTaken = entries.contains { $0.hasPrefix(currentTimeString) }
            if !isTaken {
                break
            }

            let (bumpedStem, rolledOver) = Self.incrementStem(currentTimeString)
            currentTimeString = bumpedStem
            if rolledOver {
                currentDateString = Self.nextCivilDay(after: currentDateString)
            }
            steps += 1
        }

        if currentDateString != initialDateString || currentTimeString != initialTimeString {
            Logger.storage.info("Capture stem collision resolved: \(initialTimeString, privacy: .public) -> \(currentTimeString, privacy: .public)")
        }

        // Create date directory: YYYY-MM-DD
        let dateDir = baseDirectory.appendingPathComponent(currentDateString, isDirectory: true)

        // Create segment directory: HHMMSS.incomplete (duration added on completion)
        let segmentDir = dateDir.appendingPathComponent("\(currentTimeString).incomplete", isDirectory: true)

        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: false)

        if let zoneRecord {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(zoneRecord)
                let zoneFileURL = segmentDir.appendingPathComponent(Self.captureZoneFileName)
                try data.write(to: zoneFileURL, options: .atomic)
            } catch {
                Logger.storage.warning("Failed to persist capture zone record: \(error, privacy: .public)")
            }
        }

        return (segmentDir, currentTimeString)
    }

    /// Lists all segment directories for a given date
    public func listSegments(for date: Date) -> [URL] {
        let dateString = Self.dateFormatter.string(from: date)
        let dateDir = baseDirectory.appendingPathComponent(dateString, isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dateDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Calculates total disk usage of all files under `baseDirectory`, in bytes
    public func calculateStorageUsed() async -> Int64 {
        let baseDirectory = self.baseDirectory
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: baseDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return Int64(0)
            }

            var totalSize: Int64 = 0
            while let fileURL = enumerator.nextObject() as? URL {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      resourceValues.isRegularFile == true,
                      let fileSize = resourceValues.fileSize else {
                    continue
                }
                totalSize += Int64(fileSize)
            }
            return totalSize
        }.value
    }
}
