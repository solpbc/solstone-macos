// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation

/// The note line contract, v1. Every byte on the wire is written here.
enum ObsidianWire {
    static let source = "obsidian"
    static let capability = "obsidian_notes"
    static let filePrefix = "obsidian_"
    static let fileSuffix = ".jsonl"
    static let maxFileLines = 5_000
    static let maxFileBytes = 8 * 1024 * 1024
    static let maxNoteBytes = 4 * 1024 * 1024
    static let windowSeconds: Int64 = 300
    /// A window closes this long after it ends.
    static let windowCloseSeconds: Int64 = 90
    static let maxVaultNameBytes = 128

    static func sha256Hex(_ data: some DataProtocol) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileName(for bytes: Data) -> String {
        "\(filePrefix)\(sha256Hex(bytes))\(fileSuffix)"
    }

    /// Whether a vault's folder name can travel as the `vault` field.
    static func isUsableVaultName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maxVaultNameBytes
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Whether a note's path can travel. A vault can hold names the journal refuses.
    static func isSendablePath(_ path: String) -> Bool {
        !path.contains("\\") && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

/// A moment, with the offset the device had at that moment.
struct ObsidianStamp: Codable, Equatable, Sendable {
    let epochSeconds: Int64
    let offsetSeconds: Int32

    init(epochSeconds: Int64, timeZone: TimeZone) {
        self.epochSeconds = epochSeconds
        let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
        // An offset carrying seconds can't be written in RFC 3339, so the moment is written in UTC.
        self.offsetSeconds = offset % 60 == 0 ? Int32(offset) : 0
    }

    init(milliseconds: Int64, timeZone: TimeZone) {
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        self.init(epochSeconds: seconds, timeZone: timeZone)
    }

    private struct Wall {
        let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    }

    private var wall: Wall {
        var seconds = time_t(epochSeconds + Int64(offsetSeconds))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return Wall(
            year: Int(parts.tm_year) + 1900, month: Int(parts.tm_mon) + 1, day: Int(parts.tm_mday),
            hour: Int(parts.tm_hour), minute: Int(parts.tm_min), second: Int(parts.tm_sec)
        )
    }

    /// False for a moment RFC 3339 can't hold, like a file time far outside any real date.
    var isRepresentable: Bool { (1...9999).contains(wall.year) }

    var rfc3339: String {
        let wall = wall
        let date = "\(pad(wall.year, 4))-\(pad(wall.month, 2))-\(pad(wall.day, 2))"
        let time = "\(pad(wall.hour, 2)):\(pad(wall.minute, 2)):\(pad(wall.second, 2))"
        guard offsetSeconds != 0 else { return "\(date)T\(time)Z" }
        let sign = offsetSeconds < 0 ? "-" : "+"
        let magnitude = abs(Int(offsetSeconds))
        return "\(date)T\(time)\(sign)\(pad(magnitude / 3600, 2)):\(pad(magnitude % 3600 / 60, 2))"
    }

    /// The window this moment's wall clock, in its own offset, falls inside.
    var window: ObsidianWindow {
        let wall = wall
        let seconds = wall.hour * 3600 + wall.minute * 60 + wall.second
        let floored = seconds - seconds % Int(ObsidianWire.windowSeconds)
        return ObsidianWindow(
            day: "\(pad(wall.year, 4))\(pad(wall.month, 2))\(pad(wall.day, 2))",
            segment: "\(pad(floored / 3600, 2))\(pad(floored % 3600 / 60, 2))00_\(ObsidianWire.windowSeconds)"
        )
    }

    private func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}

/// One five-minute window, named as it travels. `key` also names its directories and sorts oldest first.
struct ObsidianWindow: Hashable, Codable, Sendable, Comparable {
    let day: String
    let segment: String

    var key: String { "\(day)-\(segment)" }

    init(day: String, segment: String) {
        self.day = day
        self.segment = segment
    }

    init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2, parts[0].count == 8, parts[1].count == 10 else { return nil }
        self.init(day: String(parts[0]), segment: String(parts[1]))
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }

    /// When this window closes, read in the device's offset around that moment.
    func closeDate(timeZone: TimeZone) -> Date? {
        guard let year = Int(day.prefix(4)), let month = Int(day.dropFirst(4).prefix(2)),
              let dayOfMonth = Int(day.suffix(2)), let hour = Int(segment.prefix(2)),
              let minute = Int(segment.dropFirst(2).prefix(2)) else { return nil }
        var parts = tm()
        parts.tm_year = Int32(year - 1900)
        parts.tm_mon = Int32(month - 1)
        parts.tm_mday = Int32(dayOfMonth)
        parts.tm_hour = Int32(hour)
        parts.tm_min = Int32(minute)
        let wallEpoch = Int64(timegm(&parts))
        // Offsets from a day either side cover a change of clocks. Of the moments that really
        // carry this wall clock, the latest: in a repeated hour a window never closes early.
        let starts = [wallEpoch - 86_400, wallEpoch + 86_400].map { probe -> Int64 in
            wallEpoch - Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(probe))))
        }
        let real = starts.filter { start in
            Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(start)))) == wallEpoch - start
        }
        guard let start = real.max() ?? starts.max() else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start + ObsidianWire.windowSeconds + ObsidianWire.windowCloseSeconds))
    }
}

/// One line of a note file.
struct ObsidianNoteLine: Equatable, Sendable {
    let change: ObsidianChange
    let vault: String
    let path: String
    let previousPath: String?
    let changedAt: ObsidianStamp
    let observedAt: ObsidianStamp
    let text: String?
    let contentHash: String?

    var sortKey: ObsidianLineSortKey {
        ObsidianLineSortKey(vault: vault, path: path, changedAt: changedAt.rfc3339, change: change.rawValue)
    }

    /// Compact JSON with sorted keys, without a trailing newline.
    func encoded() -> Data {
        var out = Data(capacity: 256 + (text?.utf8.count ?? 0))
        out.append(contentsOf: Array("{\"change\":".utf8))
        out.appendJSONString(change.rawValue)
        out.appendKey("changed_at")
        out.appendJSONString(changedAt.rfc3339)
        out.appendKey("content_hash")
        out.appendJSONString(contentHash)
        out.appendKey("observed_at")
        out.appendJSONString(observedAt.rfc3339)
        out.appendKey("path")
        out.appendJSONString(path)
        out.appendKey("previous_path")
        out.appendJSONString(previousPath)
        out.appendKey("text")
        out.appendJSONString(text)
        out.append(contentsOf: Array(",\"v\":1".utf8))
        out.appendKey("vault")
        out.appendJSONString(vault)
        out.append(UInt8(ascii: "}"))
        return out
    }

    /// Whether this line fits in a file. Escaping can make a line more than twice its text.
    var fitsInFile: Bool { encoded().count + 1 <= ObsidianWire.maxFileBytes }
}

enum ObsidianChange: String, Codable, Sendable {
    case changed, renamed, removed
}

/// The file sort: vault, path, changed_at, change, compared as bytes.
struct ObsidianLineSortKey: Comparable {
    let vault: String
    let path: String
    let changedAt: String
    let change: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in [(lhs.vault, rhs.vault), (lhs.path, rhs.path), (lhs.changedAt, rhs.changedAt), (lhs.change, rhs.change)] {
            if left.utf8.elementsEqual(right.utf8) { continue }
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        return false
    }
}

/// Packs encoded lines into files of at most `maxFileLines` lines and `maxFileBytes` bytes, in order.
struct ObsidianFileAccumulator {
    private var current = Data()
    private var lines = 0

    /// Adds a line. Returns the finished file when this line didn't fit in it.
    mutating func add(_ line: Data) -> Data? {
        var finished: Data?
        if lines > 0, lines == ObsidianWire.maxFileLines || current.count + line.count + 1 > ObsidianWire.maxFileBytes {
            finished = current
            current = Data()
            lines = 0
        }
        current.append(line)
        current.append(UInt8(ascii: "\n"))
        lines += 1
        return finished
    }

    mutating func finish() -> Data? {
        guard lines > 0 else { return nil }
        let finished = current
        current = Data()
        lines = 0
        return finished
    }
}

extension ObsidianNoteLine {
    /// Sorted, split and named files for a set of lines in one window.
    static func files(for lines: [ObsidianNoteLine]) -> [(name: String, bytes: Data)] {
        var files: [(name: String, bytes: Data)] = []
        var accumulator = ObsidianFileAccumulator()
        for line in lines.sorted(by: { $0.sortKey < $1.sortKey }) {
            if let finished = accumulator.add(line.encoded()) {
                files.append((ObsidianWire.fileName(for: finished), finished))
            }
        }
        if let finished = accumulator.finish() {
            files.append((ObsidianWire.fileName(for: finished), finished))
        }
        return files
    }
}

private extension Data {
    mutating func appendKey(_ key: String) {
        append(contentsOf: Array(",\"\(key)\":".utf8))
    }

    mutating func appendJSONString(_ value: String?) {
        guard let value else {
            append(contentsOf: Array("null".utf8))
            return
        }
        append(UInt8(ascii: "\""))
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "\""): append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x08: append(contentsOf: Array("\\b".utf8))
            case 0x0C: append(contentsOf: Array("\\f".utf8))
            case 0x0A: append(contentsOf: Array("\\n".utf8))
            case 0x0D: append(contentsOf: Array("\\r".utf8))
            case 0x09: append(contentsOf: Array("\\t".utf8))
            case 0..<0x20:
                append(contentsOf: Array(String(format: "\\u%04x", byte).utf8))
            default:
                append(byte)
            }
        }
        append(UInt8(ascii: "\""))
    }
}
