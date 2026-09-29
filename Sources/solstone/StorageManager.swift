// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

/// Manages file storage for capture segments
public final class StorageManager: Sendable {
    /// Base directory for all captures
    public let baseDirectory: URL

    static let captureZoneFileName = "capture_zone.json"

    private struct CaptureZoneRecord: Codable {
        let tz: String
        let utc_offset_seconds: Int
    }

    public static var defaultBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Solstone/captures", isDirectory: true)
    }

    /// Date formatter for directory names (YYYY-MM-DD)
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Time formatter for segment directories (HHMMSS)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

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

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
            return
        }

        // ~/Library/Application Support/Solstone/captures/
        self.baseDirectory = Self.defaultBaseDirectory
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
        let dateString: String
        let timeString: String
        let zoneRecord: CaptureZoneRecord?

        if let timeZone {
            let naming = Self.segmentNaming(segmentStartTime: segmentStartTime, timeZone: timeZone)
            dateString = naming.dateString
            timeString = naming.timePrefix
            zoneRecord = CaptureZoneRecord(tz: naming.identifier, utc_offset_seconds: naming.utcOffsetSeconds)
        } else if let dateTZ = Self.dateFormatter.timeZone,
                  let timeTZ = Self.timeFormatter.timeZone,
                  dateTZ.identifier == timeTZ.identifier,
                  dateTZ.secondsFromGMT(for: segmentStartTime) == timeTZ.secondsFromGMT(for: segmentStartTime) {
            let naming = Self.segmentNaming(segmentStartTime: segmentStartTime, timeZone: dateTZ)
            dateString = naming.dateString
            timeString = naming.timePrefix
            zoneRecord = CaptureZoneRecord(tz: naming.identifier, utc_offset_seconds: naming.utcOffsetSeconds)
        } else {
            // Disagreement or missing zone on static formatters: fall back to static formatters without recording zone
            Logger.storage.warning("Date and time formatters have mismatched or nil time zones; formatting without zone record")
            dateString = Self.dateFormatter.string(from: segmentStartTime)
            timeString = Self.timeFormatter.string(from: segmentStartTime)
            zoneRecord = nil
        }

        // Create date directory: YYYY-MM-DD
        let dateDir = baseDirectory.appendingPathComponent(dateString, isDirectory: true)

        // Create segment directory: HHMMSS.incomplete (duration added on completion)
        let segmentDir = dateDir.appendingPathComponent("\(timeString).incomplete", isDirectory: true)

        try FileManager.default.createDirectory(at: segmentDir, withIntermediateDirectories: true)

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

        return (segmentDir, timeString)
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
