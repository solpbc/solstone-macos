// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin

struct DesktopActivityRow: Codable, Equatable, Sendable {
    var v = 1
    var t = "desktop_activity"
    var kind: String
    var ts: Int64 = 0
    var end_ts: Int64 = 0
    var method: String
    var app: String?
    var app_id: String?
    var title: String?
    var url: String?
    var state: String?
    var capability: String?
    var status: String?

    func sameObservation(as other: Self) -> Bool {
        var a = self, b = other
        a.ts = 0; a.end_ts = 0; b.ts = 0; b.end_ts = 0
        return a == b
    }
}

/// A checkpoint never belongs to a destination journal. While a capture segment is open, rows wait
/// here and are written into that segment as its capture ends, so they reach the journal beside the
/// screen they describe. Without one, rows are sealed into their own ordinary segments. Only sealed
/// or finished segments are exposed to sync; a restart seals the last observed endpoint, never the
/// intervening gap.
final class DesktopActivityStore {
    struct Checkpoint: Codable {
        var closed: [DesktopActivityRow] = []
        var open: [DesktopActivityRow] = []
        var targetDay: String?
        var targetStem: String?
        var targetDuration: Int?
        var artifactID = UUID().uuidString.lowercased()
        /// Rows assigned to a capture segment whose file is not yet known to be written.
        var placement: Placement?
    }

    struct Placement: Codable {
        var day: String
        var stem: String
        var artifactID: String
        var rows: [DesktopActivityRow]
    }

    let storage: StorageManager
    let pendingURL: URL
    private(set) var checkpoint = Checkpoint()
    private(set) var publicationCount = 0
    private let write: (Data, URL) throws -> Void

    init(storage: StorageManager, write: @escaping (Data, URL) throws -> Void = DesktopActivityStore.durableWrite) {
        self.storage = storage
        pendingURL = storage.baseDirectory.deletingLastPathComponent()
            .appendingPathComponent("activity-pending/checkpoint.json")
        self.write = write
    }

    static func durableWrite(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        // Make publication of the checkpoint or artifact durable as well as its contents.
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func save(_ next: Checkpoint) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try write(encoder.encode(next), pendingURL)
        checkpoint = next
    }

    func recover() throws {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return }
        checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: pendingURL))
        try seal()
    }

    /// Split at the ordinary five-minute UTC boundaries, including a delayed timer tick. While a
    /// capture segment is open, the capture's own cut splits the rows instead (`place(into:at:)`).
    func observe(_ observations: [DesktopActivityRow], at milliseconds: Int64, captureOpen: Bool = false) throws {
        if checkpoint.placement != nil { try finishPlacement() }
        if checkpoint.targetStem != nil { try seal() }
        if captureOpen {
            try advance(observations, at: milliseconds)
            return
        }
        if checkpoint.open.isEmpty, let earliest = checkpoint.closed.map(\.ts).min(),
           milliseconds >= (earliest / 300_000 + 1) * 300_000 {
            // An excluded/private window must not strand earlier admitted rows until quit.
            try seal()
        }
        let last = checkpoint.open.map(\.end_ts).max() ?? milliseconds
        var boundary = (last / 300_000 + 1) * 300_000
        while !checkpoint.open.isEmpty && boundary <= milliseconds {
            try advance(checkpoint.open, at: boundary)
            let continuing = checkpoint.open
            try seal()
            try advance(continuing, at: boundary)
            boundary += 300_000
        }
        try advance(observations, at: milliseconds)
    }

    private func advance(_ observations: [DesktopActivityRow], at milliseconds: Int64) throws {
        var next = checkpoint
        let now = max(milliseconds, next.open.map(\.end_ts).max() ?? milliseconds)
        if next.open.count == observations.count && zip(next.open, observations).allSatisfy({ $0.sameObservation(as: $1) }) {
            for i in next.open.indices { next.open[i].end_ts = now }
        } else {
            for var row in next.open { row.end_ts = max(row.ts, now); next.closed.append(row) }
            next.open = observations.map { row in
                var row = row; row.ts = now; row.end_ts = now; return row
            }
        }
        guard !next.open.isEmpty || !next.closed.isEmpty else { return }
        try save(next)
    }

    func end(at milliseconds: Int64, captureOpen: Bool = false) throws {
        try observe([], at: milliseconds, captureOpen: captureOpen)
        if !captureOpen { try seal() }
    }

    /// Writes every row before `cut` into the capture segment whose capture is ending, while it is
    /// still `.incomplete`, so the segment's finishing step publishes them with its media. A row
    /// still being observed continues from the cut, as at a boundary.
    func place(into directory: URL, at cut: Int64) throws {
        if checkpoint.placement != nil { try finishPlacement() }
        if checkpoint.targetStem != nil { try seal() }
        let name = directory.lastPathComponent
        guard name.hasSuffix(".incomplete") else { return }
        var next = checkpoint
        var placed: [DesktopActivityRow] = [], closed: [DesktopActivityRow] = [], open: [DesktopActivityRow] = []
        for row in next.closed {
            if row.ts < cut { var inside = row; inside.end_ts = min(row.end_ts, cut); placed.append(inside) }
            if row.ts >= cut || row.end_ts > cut { var after = row; after.ts = max(row.ts, cut); closed.append(after) }
        }
        for row in next.open {
            if row.ts < cut { var inside = row; inside.end_ts = cut; placed.append(inside) }
            var after = row; after.ts = max(row.ts, cut); after.end_ts = max(row.end_ts, cut); open.append(after)
        }
        guard !placed.isEmpty else { return }
        next.closed = closed; next.open = open
        next.placement = Placement(day: directory.deletingLastPathComponent().lastPathComponent,
                                   stem: String(name.dropLast(".incomplete".count)),
                                   artifactID: UUID().uuidString.lowercased(), rows: placed)
        try save(next)
        try finishPlacement()
    }

    private func finishPlacement() throws {
        guard let placement = checkpoint.placement else { return }
        guard placement.day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              placement.stem.range(of: #"^\d{6}$"#, options: .regularExpression) != nil,
              UUID(uuidString: placement.artifactID) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let dayURL = storage.baseDirectory.appendingPathComponent(placement.day)
        let incomplete = dayURL.appendingPathComponent("\(placement.stem).incomplete")
        let suffix = "_\(placement.artifactID)_desktop_activity.jsonl"
        var next = checkpoint
        next.placement = nil
        if FileManager.default.fileExists(atPath: incomplete.path) {
            // Same name and bytes on a retry, so a crash before the clear below rewrites, never duplicates.
            try write(Self.encode(placement.rows), incomplete.appendingPathComponent("\(placement.stem)\(suffix)"))
        } else if !Self.holds(dayURL, stem: placement.stem, suffix: suffix) {
            // The segment finished without them (a crash before the write): seal them on their own.
            next.closed = placement.rows + next.closed
        }
        try save(next)
    }

    /// Finishing renames the segment and its files, so look for the artifact id, not the name.
    private static func holds(_ dayURL: URL, stem: String, suffix: String) -> Bool {
        let segments = (try? FileManager.default.contentsOfDirectory(at: dayURL, includingPropertiesForKeys: nil)) ?? []
        return segments.contains { segment in
            let name = segment.lastPathComponent
            guard name.hasPrefix("\(stem)_") || name == "\(stem).failed" else { return false }
            return ((try? FileManager.default.contentsOfDirectory(atPath: segment.path)) ?? []).contains { $0.hasSuffix(suffix) }
        }
    }

    private static func encode(_ rows: [DesktopActivityRow]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for row in rows { data.append(try encoder.encode(row)); data.append(0x0A) }
        return data
    }

    func seal() throws {
        if checkpoint.placement != nil { try finishPlacement() }
        var next = checkpoint
        let rows = (next.closed + next.open).filter { $0.end_ts >= $0.ts }
        guard let start = rows.map(\.ts).min(), let end = rows.map(\.end_ts).max() else { return }
        if next.targetStem == nil {
            let directory = try storage.createSegmentDirectory(
                segmentStartTime: Date(timeIntervalSince1970: Double(start) / 1000), timeZone: .current)
            next.targetDay = directory.url.deletingLastPathComponent().lastPathComponent
            next.targetStem = directory.timePrefix
            next.targetDuration = max(1, Int(ceil(Double(end - start) / 1000)))
            try save(next)
        }
        guard let day = next.targetDay, let stem = next.targetStem, let duration = next.targetDuration,
              day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              stem.range(of: #"^\d{6}$"#, options: .regularExpression) != nil,
              UUID(uuidString: next.artifactID) != nil, duration >= 1 else { throw CocoaError(.fileReadCorruptFile) }
        let dayURL = storage.baseDirectory.appendingPathComponent(day)
        let incomplete = dayURL.appendingPathComponent("\(stem).incomplete")
        let completed = dayURL.appendingPathComponent("\(stem)_\(duration)")
        let filename = "\(stem)_\(next.artifactID)_desktop_activity.jsonl"
        let data = try Self.encode(rows)
        if FileManager.default.fileExists(atPath: completed.path) {
            // A crash after publication must not republish the same interval under a new name.
            guard try Data(contentsOf: completed.appendingPathComponent(filename)) == data else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else {
            try write(data, incomplete.appendingPathComponent(filename))
            try FileManager.default.moveItem(at: incomplete, to: completed)
            let fd = open(dayURL.path, O_RDONLY)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        // Durably clear before sync can remove the published artifact; a deleted checkpoint
        // could otherwise reappear after a crash and duplicate an acknowledged interval.
        try save(Checkpoint())
        publicationCount += 1
    }
}

func desktopActivityURL(_ value: String) -> String? {
    guard var parts = URLComponents(string: value),
          ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
          let host = parts.host, !host.isEmpty else { return nil }
    parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
    return parts.string
}
