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

/// A checkpoint never belongs to a destination journal. Only sealed ordinary segments are
/// exposed to sync; a restart seals the last observed endpoint, never the intervening gap.
final class DesktopActivityStore {
    struct Checkpoint: Codable {
        var closed: [DesktopActivityRow] = []
        var open: [DesktopActivityRow] = []
        var targetDay: String?
        var targetStem: String?
        var targetDuration: Int?
        var artifactID = UUID().uuidString.lowercased()
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

    /// Split at the ordinary five-minute UTC boundaries, including a delayed timer tick.
    func observe(_ observations: [DesktopActivityRow], at milliseconds: Int64) throws {
        if checkpoint.targetStem != nil { try seal() }
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

    func end(at milliseconds: Int64) throws {
        try observe([], at: milliseconds)
        try seal()
    }

    func seal() throws {
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for row in rows { data.append(try encoder.encode(row)); data.append(0x0A) }
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
