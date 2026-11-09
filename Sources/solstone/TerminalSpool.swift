// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// A finished terminal segment waiting to go to the journal.
struct TerminalSpoolSegment: Equatable, Sendable {
    let day: String
    let segment: String
    let directory: URL
    let files: [URL]
    let zone: [String: IngestJSONValue]?

    var zoneURL: URL { TerminalSpool.zoneURL(segmentDirectory: directory) }
}

/// The helper's spool: `<root>/<YYYYMMDD>/<HHMMSS_LLL>/` with a sibling
/// `<HHMMSS_LLL>.zone.json`. A segment is finished once the `.meta` of its
/// unfinished form is gone.
enum TerminalSpool {
    static func rootURL(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("Solstone/terminal", isDirectory: true)
    }

    /// The helper writes owner-private captures here, so the app makes it 0700 first.
    static func ensureRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    static func zoneURL(segmentDirectory: URL) -> URL {
        segmentDirectory.deletingLastPathComponent()
            .appendingPathComponent("\(segmentDirectory.lastPathComponent).zone.json")
    }

    static func isDayName(_ name: String) -> Bool {
        name.count == 8 && name.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func isSegmentName(_ name: String) -> Bool {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 6, !parts[1].isEmpty else { return false }
        return parts.allSatisfy { part in part.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    private static func directories(in url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )) ?? []
        return contents.filter { entry in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    /// Every finished segment, oldest first.
    static func finished(root: URL) -> [TerminalSpoolSegment] {
        var found: [TerminalSpoolSegment] = []
        for day in directories(in: root).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isDayName(day.lastPathComponent) else { continue }
            for directory in directories(in: day).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = directory.lastPathComponent
                guard isSegmentName(name), !isAwaitingCaptureTime(directory) else { continue }
                let files = memberFiles(directory)
                guard !files.isEmpty else { continue }
                found.append(TerminalSpoolSegment(
                    day: day.lastPathComponent,
                    segment: name,
                    directory: directory,
                    files: files,
                    zone: readZone(segmentDirectory: directory)
                ))
            }
        }
        return found
    }

    private static func isAwaitingCaptureTime(_ directory: URL) -> Bool {
        let stem = directory.lastPathComponent.split(separator: "_")[0]
        let meta = directory.deletingLastPathComponent().appendingPathComponent("\(stem).incomplete.meta")
        var status = stat()
        return lstat(meta.path, &status) == 0
    }

    private static func memberFiles(_ directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return contents
            .filter { url in
                !url.lastPathComponent.hasPrefix(".")
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The capture time, as upload `meta`. `nil` when absent or unreadable.
    static func readZone(segmentDirectory: URL) -> [String: IngestJSONValue]? {
        guard let data = try? Data(contentsOf: zoneURL(segmentDirectory: segmentDirectory)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let offset = (root["utc_offset_seconds"] as? NSNumber)?.int64Value else { return nil }
        var meta: [String: IngestJSONValue] = ["utc_offset_seconds": .integer(Int(offset))]
        if let tz = root["tz"] as? String { meta["tz"] = .string(tz) }
        return meta
    }

    /// The directory goes first: a zone file left by a crash is harmless, a segment
    /// missing its capture time is not.
    static func remove(_ segment: TerminalSpoolSegment) throws {
        try FileManager.default.removeItem(at: segment.directory)
        try? FileManager.default.removeItem(at: segment.zoneURL)
    }
}
