// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// What one mutation of the on-device source totals did.
enum SourceTotalsOutcome: Equatable, Sendable {
    /// The file now holds the new totals.
    case applied
    /// The file already accounted for this contribution.
    case unchanged
    /// The file is not a version this build writes. Its bytes were left alone.
    case skippedUnreadable
    /// A readable file could not be replaced. The previous bytes remain.
    case saveFailed
}

/// The app's one install of the totals file. Capture reads it without waiting
/// on an actor hop. Tests pass their own instance and do not install one.
enum SourceTotalsInstall {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var current: SourceTotals?

    static func install(_ totals: SourceTotals) {
        lock.lock()
        current = totals
        lock.unlock()
    }

    static func currentStore() -> SourceTotals? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// Lifetime totals for what this Mac has taken in, kept beside the captures
/// directory. The file is not a preference and it is not uploaded.
final class SourceTotals: @unchecked Sendable {
    static let fileName = "source-totals.json"
    /// The terminal helper's counter, in its own data root. Not this app's file.
    static let carriedTerminalFileName = "source-intake.json"
    static let version = 1

    struct Clock: Sendable {
        var now: Date
        var timeZone: TimeZone
    }

    struct View: Equatable, Sendable {
        var audioSeconds: Int
        var audioRemainderMs: Int
        var audioLast: String?
        var audioSegments: [String]
        var audioStarted: String
        var screenSeconds: Int
        var screenRemainderMs: Int
        var screenLast: String?
        var screenSegments: [String]
        var screenStarted: String
        var terminalSeconds: Int
        var terminalLast: String?
        var terminalCarried: Bool
        var terminalStarted: String
        var browsersTotal: Int
        var browsersLast: String?
        var browsersTabs: [String: String]
        var browsersStarted: String
        var obsidianTotal: Int
        var obsidianLast: String?
        var obsidianNotes: Set<String>
        var obsidianBaseline: Bool
        var obsidianStarted: String
    }

    enum ObsidianEvent: Equatable, Sendable {
        case added(String)
        case renamed(from: String?, to: String)
        case removed(String)
    }

    let fileURL: URL
    private let lock = NSLock()
    private var clock: Clock
    private var model: Model?
    private var replaceFails = false

    init(directory: URL, clock: Clock) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        self.clock = clock
        if let data = try? Data(contentsOf: fileURL) {
            model = Self.decode(data)
        } else if !FileManager.default.fileExists(atPath: fileURL.path) {
            let fresh = Model.fresh(day: Self.localDay(clock.now, zone: clock.timeZone))
            model = fresh
            _ = save(fresh)
        }
    }

    func setClock(_ clock: Clock) {
        lock.lock()
        self.clock = clock
        lock.unlock()
    }

    func setReplaceFails(_ fails: Bool) {
        lock.lock()
        replaceFails = fails
        lock.unlock()
    }

    /// Nil when the bytes are not a version this build writes.
    func view() -> View? {
        lock.lock()
        defer { lock.unlock() }
        return model?.view
    }

    func bytes() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    func applyCapture(segmentID: String, audioMilliseconds: Int, screenMilliseconds: Int) -> SourceTotalsOutcome {
        mutate { model in
            var changed = false
            if !model.audio.segments.contains(segmentID) {
                model.audio.segments.append(segmentID)
                addMilliseconds(max(0, audioMilliseconds), into: &model.audio)
                changed = true
            }
            if !model.screen.segments.contains(segmentID) {
                model.screen.segments.append(segmentID)
                addMilliseconds(max(0, screenMilliseconds), into: &model.screen)
                changed = true
            }
            return changed
        }
    }

    func applyTerminal(startUnix: Int, length: Int) -> SourceTotalsOutcome {
        mutate { model in
            addTerminal(startUnix: startUnix, length: length, into: &model)
        }
    }

    /// Counts every finished segment the spool walker returns. One save.
    func absorbFinishedTerminal(root: URL) -> SourceTotalsOutcome {
        let segments = TerminalSpool.finished(root: root)
        return mutate { model in
            var changed = false
            for segment in segments {
                guard let placed = Self.placement(day: segment.day, segment: segment.segment, zone: segment.zone, timeZone: clock.timeZone) else { continue }
                if addTerminal(startUnix: placed.start, length: placed.length, into: &model) {
                    changed = true
                }
            }
            return changed
        }
    }

    /// One read of the terminal helper's counter. Missing, not version 1, or
    /// without a whole `seconds` adds nothing, and is not read again. Those
    /// seconds are not coverage, and the helper's `seen` list is not applied.
    func considerCarry(_ data: Data?) -> SourceTotalsOutcome {
        mutate { model in
            if model.terminal.carried { return false }
            model.terminal.carried = true
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.integer(root["version"]) == 1,
                  let terminal = root["terminal"] as? [String: Any],
                  let seconds = Self.integer(terminal["seconds"]) else {
                return true
            }
            let before = model.terminal.totalSeconds
            model.terminal.totalSeconds += max(0, seconds)
            if let raw = terminal["last"] as? String, let carried = Self.parseInstant(raw) {
                let current = model.terminal.last.flatMap(Self.parseInstant)
                if current == nil || carried > current! {
                    model.terminal.last = raw
                }
            } else if model.terminal.totalSeconds > before {
                model.terminal.last = Self.iso(clock.now)
            }
            return true
        }
    }

    func applyPages(_ pages: [(key: String, url: String)]) -> SourceTotalsOutcome {
        mutate { model in
            var changed = false
            for page in pages {
                if model.browsers.tabs[page.key] == page.url { continue }
                model.browsers.tabs[page.key] = page.url
                model.browsers.total += 1
                model.browsers.last = Self.iso(clock.now)
                changed = true
            }
            return changed
        }
    }

    /// A completed listing. The total does not move. A second call does nothing.
    func applyBaseline(hashes: [String]) -> SourceTotalsOutcome {
        mutate { model in
            if model.obsidian.baseline { return false }
            for hash in hashes { model.obsidian.notes.insert(hash) }
            model.obsidian.baseline = true
            return true
        }
    }

    /// Queue-time note identity. Before a baseline save, nothing is recorded.
    func applyObsidianQueue(_ events: [ObsidianEvent]) -> SourceTotalsOutcome {
        mutate { model in
            guard model.obsidian.baseline else { return false }
            var changed = false
            for event in events {
                switch event {
                case .added(let hash):
                    if model.obsidian.notes.contains(hash) { continue }
                    model.obsidian.notes.insert(hash)
                    model.obsidian.total += 1
                    model.obsidian.last = Self.iso(clock.now)
                    changed = true
                case .renamed(let from, let to):
                    if let from, model.obsidian.notes.remove(from) != nil { changed = true }
                    if model.obsidian.notes.insert(to).inserted { changed = true }
                case .removed(let hash):
                    if model.obsidian.notes.remove(hash) != nil { changed = true }
                }
            }
            return changed
        }
    }

    static func localDay(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func parseInstant(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// Half-open placement of a finished segment. A missing zone uses `timeZone`.
    static func placement(day: String, segment: String, zone: [String: IngestJSONValue]?, timeZone: TimeZone) -> (start: Int, length: Int)? {
        let parts = segment.split(separator: "_", omittingEmptySubsequences: false)
        guard day.count == 8, parts.count == 2, parts[0].count == 6,
              let length = Int(parts[1]), length > 0,
              let year = Int(day.prefix(4)),
              let month = Int(day.dropFirst(4).prefix(2)),
              let dayOfMonth = Int(day.suffix(2)),
              let hour = Int(parts[0].prefix(2)),
              let minute = Int(parts[0].dropFirst(2).prefix(2)),
              let second = Int(parts[0].suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if case .integer(let offset) = zone?["utc_offset_seconds"], let zoned = TimeZone(secondsFromGMT: offset) {
            calendar.timeZone = zoned
        } else {
            calendar.timeZone = timeZone
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else { return nil }
        return (Int(date.timeIntervalSince1970.rounded()), length)
    }

    private func addMilliseconds(_ milliseconds: Int, into source: inout TimeSource) {
        let before = source.totalMilliseconds / 1000
        source.totalMilliseconds += milliseconds
        if source.totalMilliseconds / 1000 > before {
            source.last = Self.iso(clock.now)
        }
    }

    /// Newly covered seconds move the total. A range already covered adds nothing
    /// and does not move `last`. Overlap is counted once.
    private func addTerminal(startUnix: Int, length: Int, into model: inout Model) -> Bool {
        guard length > 0 else { return false }
        let end = startUnix + length
        var covered = 0
        for range in model.terminal.coverage {
            let low = max(startUnix, range.start)
            let high = min(end, range.end)
            if high > low { covered += high - low }
        }
        let added = (end - startUnix) - covered
        guard added > 0 else { return false }
        model.terminal.coverage.append(Coverage(start: startUnix, end: end))
        model.terminal.coverage = Self.merged(model.terminal.coverage)
        model.terminal.totalSeconds += added
        model.terminal.last = Self.iso(clock.now)
        return true
    }

    private static func merged(_ ranges: [Coverage]) -> [Coverage] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var out: [Coverage] = []
        for range in sorted where range.end > range.start {
            if let last = out.last, range.start <= last.end {
                out[out.count - 1].end = max(last.end, range.end)
            } else {
                out.append(range)
            }
        }
        return out
    }

    private func mutate(_ body: (inout Model) -> Bool) -> SourceTotalsOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var next = model else { return .skippedUnreadable }
        guard body(&next) else { return .unchanged }
        guard save(next) else { return .saveFailed }
        model = next
        return .applied
    }

    private func save(_ model: Model) -> Bool {
        if replaceFails { return false }
        guard let data = try? Self.encode(model) else { return false }
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".source-totals.\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    private struct Coverage: Equatable {
        var start: Int
        var end: Int
    }

    private struct TimeSource: Equatable {
        var totalMilliseconds: Int
        var started: String
        var last: String?
        var segments: [String]

        var viewSeconds: Int { totalMilliseconds / 1000 }
        var viewRemainder: Int { totalMilliseconds % 1000 }
    }

    private struct TerminalSource: Equatable {
        var totalSeconds: Int
        var started: String
        var last: String?
        var coverage: [Coverage]
        var carried: Bool
    }

    private struct PageSource: Equatable {
        var total: Int
        var started: String
        var last: String?
        var tabs: [String: String]
    }

    private struct NoteSource: Equatable {
        var total: Int
        var started: String
        var last: String?
        var notes: Set<String>
        var baseline: Bool
    }

    private struct Model: Equatable {
        var audio: TimeSource
        var screen: TimeSource
        var terminal: TerminalSource
        var browsers: PageSource
        var obsidian: NoteSource

        static func fresh(day: String) -> Model {
            Model(
                audio: TimeSource(totalMilliseconds: 0, started: day, last: nil, segments: []),
                screen: TimeSource(totalMilliseconds: 0, started: day, last: nil, segments: []),
                terminal: TerminalSource(totalSeconds: 0, started: day, last: nil, coverage: [], carried: false),
                browsers: PageSource(total: 0, started: day, last: nil, tabs: [:]),
                obsidian: NoteSource(total: 0, started: day, last: nil, notes: [], baseline: false)
            )
        }

        var view: View {
            View(
                audioSeconds: audio.viewSeconds,
                audioRemainderMs: audio.viewRemainder,
                audioLast: audio.last,
                audioSegments: audio.segments,
                audioStarted: audio.started,
                screenSeconds: screen.viewSeconds,
                screenRemainderMs: screen.viewRemainder,
                screenLast: screen.last,
                screenSegments: screen.segments,
                screenStarted: screen.started,
                terminalSeconds: terminal.totalSeconds,
                terminalLast: terminal.last,
                terminalCarried: terminal.carried,
                terminalStarted: terminal.started,
                browsersTotal: browsers.total,
                browsersLast: browsers.last,
                browsersTabs: browsers.tabs,
                browsersStarted: browsers.started,
                obsidianTotal: obsidian.total,
                obsidianLast: obsidian.last,
                obsidianNotes: obsidian.notes,
                obsidianBaseline: obsidian.baseline,
                obsidianStarted: obsidian.started
            )
        }
    }

    private static func encode(_ model: Model) throws -> Data {
        let root: [String: Any] = [
            "version": version,
            "audio": timeJSON(model.audio, remainder: true),
            "screen": timeJSON(model.screen, remainder: true),
            "terminal": terminalJSON(model.terminal),
            "browsers": pageJSON(model.browsers),
            "obsidian": noteJSON(model.obsidian),
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func timeJSON(_ source: TimeSource, remainder: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "total_seconds": source.viewSeconds,
            "started": source.started,
            "last": source.last ?? NSNull(),
            "segments": source.segments,
        ]
        if remainder { object["remainder_ms"] = source.viewRemainder }
        return object
    }

    private static func terminalJSON(_ source: TerminalSource) -> [String: Any] {
        [
            "total_seconds": source.totalSeconds,
            "started": source.started,
            "last": source.last ?? NSNull(),
            "coverage": source.coverage.map { [$0.start, $0.end] },
            "carried": source.carried,
        ]
    }

    private static func pageJSON(_ source: PageSource) -> [String: Any] {
        [
            "total": source.total,
            "started": source.started,
            "last": source.last ?? NSNull(),
            "tabs": source.tabs,
        ]
    }

    private static func noteJSON(_ source: NoteSource) -> [String: Any] {
        [
            "total": source.total,
            "started": source.started,
            "last": source.last ?? NSNull(),
            "notes": source.notes.sorted(),
            "baseline": source.baseline,
        ]
    }

    private static func decode(_ data: Data) -> Model? {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(root["version"]) == version,
              let audio = time(root["audio"], remainder: true),
              let screen = time(root["screen"], remainder: true),
              let terminal = terminal(root["terminal"]),
              let browsers = pages(root["browsers"]),
              let obsidian = notes(root["obsidian"]) else { return nil }
        return Model(audio: audio, screen: screen, terminal: terminal, browsers: browsers, obsidian: obsidian)
    }

    private static func time(_ value: Any?, remainder: Bool) -> TimeSource? {
        guard let object = value as? [String: Any],
              let seconds = integer(object["total_seconds"]),
              let started = object["started"] as? String else { return nil }
        let remainderMs = remainder ? (integer(object["remainder_ms"]) ?? 0) : 0
        let segments = object["segments"] as? [String] ?? []
        return TimeSource(
            totalMilliseconds: seconds * 1000 + remainderMs,
            started: started,
            last: instant(object["last"]),
            segments: segments
        )
    }

    private static func terminal(_ value: Any?) -> TerminalSource? {
        guard let object = value as? [String: Any],
              let seconds = integer(object["total_seconds"]),
              let started = object["started"] as? String else { return nil }
        var coverage: [Coverage] = []
        for row in object["coverage"] as? [Any] ?? [] {
            guard let pair = row as? [Any], pair.count == 2,
                  let start = integer(pair[0]), let end = integer(pair[1]), end > start else { continue }
            coverage.append(Coverage(start: start, end: end))
        }
        return TerminalSource(
            totalSeconds: seconds,
            started: started,
            last: instant(object["last"]),
            coverage: merged(coverage),
            carried: object["carried"] as? Bool ?? false
        )
    }

    private static func pages(_ value: Any?) -> PageSource? {
        guard let object = value as? [String: Any],
              let total = integer(object["total"]),
              let started = object["started"] as? String else { return nil }
        var tabs: [String: String] = [:]
        for (key, url) in object["tabs"] as? [String: Any] ?? [:] {
            if let url = url as? String { tabs[key] = url }
        }
        return PageSource(total: total, started: started, last: instant(object["last"]), tabs: tabs)
    }

    private static func notes(_ value: Any?) -> NoteSource? {
        guard let object = value as? [String: Any],
              let total = integer(object["total"]),
              let started = object["started"] as? String else { return nil }
        let hashes = Set(object["notes"] as? [String] ?? [])
        return NoteSource(
            total: total,
            started: started,
            last: instant(object["last"]),
            notes: hashes,
            baseline: object["baseline"] as? Bool ?? false
        )
    }

    private static func instant(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return number.intValue
    }
}
