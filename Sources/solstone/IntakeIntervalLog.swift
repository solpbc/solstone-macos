// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Accepted audio and per-display screen time for one capture segment, on the
/// segment clock. Padding the audio writer generated is not a range. A frame the
/// site gate drops on a hold, a gap or a stall closes only that display's
/// range. An idle frame that was skipped does not.
final class IntakeIntervalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: TimeInterval = 0
    private var audio: [String: [(Double, Double)]] = [:]
    private var screen: [String: [(Double, Double)]] = [:]
    private var screenOpen: [String: Double] = [:]
    private var screenHeld: Set<String> = []

    func setOrigin(_ hostSeconds: TimeInterval) {
        lock.lock()
        origin = hostSeconds
        lock.unlock()
    }

    func acceptAudio(source: String, start: Double, end: Double) {
        guard end > start, start.isFinite, end.isFinite else { return }
        lock.lock()
        audio[source, default: []].append((start, end))
        lock.unlock()
    }

    /// `at` is host time. The stored range is relative to the origin.
    func beginDisplay(_ display: String, at hostSeconds: TimeInterval) {
        lock.lock()
        openLocked(display, at: hostSeconds - origin)
        lock.unlock()
    }

    func hold(display: String, at hostSeconds: TimeInterval) {
        lock.lock()
        closeLocked(display, at: hostSeconds - origin)
        screenHeld.insert(display)
        lock.unlock()
    }

    func resume(display: String, at hostSeconds: TimeInterval) {
        lock.lock()
        guard screenHeld.contains(display) else { lock.unlock(); return }
        screenHeld.remove(display)
        openLocked(display, at: hostSeconds - origin)
        lock.unlock()
    }

    func endDisplay(_ display: String, at hostSeconds: TimeInterval) {
        lock.lock()
        closeLocked(display, at: hostSeconds - origin)
        screenHeld.remove(display)
        lock.unlock()
    }

    func endAll(at hostSeconds: TimeInterval) {
        lock.lock()
        let relative = hostSeconds - origin
        for display in Array(screenOpen.keys) {
            closeLocked(display, at: relative)
        }
        screenHeld.removeAll()
        lock.unlock()
    }

    /// An idle frame that was not encoded. The open range stays open.
    func idleSkipped(display: String, at hostSeconds: TimeInterval) {}

    func audioRanges() -> [String: [(Double, Double)]] {
        lock.lock()
        defer { lock.unlock() }
        return audio
    }

    func screenRanges() -> [String: [(Double, Double)]] {
        lock.lock()
        defer { lock.unlock() }
        return screen
    }

    @discardableResult
    func write(into directory: URL) -> Bool {
        lock.lock()
        let payload: [String: Any] = [
            "audio": Self.encoded(audio),
            "screen": Self.encoded(screen),
        ]
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return false }
        let url = directory.appendingPathComponent(Self.fileName)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static let fileName = "intake-intervals.json"

    /// Nil when the file is missing or cannot be read. Either one contributes no time.
    static func read(directory: URL) -> (audio: [String: [(Double, Double)]], screen: [String: [(Double, Double)]])? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (audio: decoded(root["audio"]), screen: decoded(root["screen"]))
    }

    /// Length of the union, in milliseconds. Microphone ranges are one half.
    /// The system range, after the silence this remix applied, is the other.
    /// A source that did not land contributes nothing.
    static func audioMilliseconds(
        audio: [String: [(Double, Double)]],
        landed: Set<String>,
        silence: [String: [(Double, Double)]]
    ) -> Int {
        var spans: [Span] = []
        for (id, ranges) in audio where landed.contains(id) {
            let piece = spansFrom(ranges)
            if id == AudioTrackType.systemSourceID {
                spans.append(contentsOf: subtract(piece, spansFrom(silence[id] ?? [])))
            } else {
                spans.append(contentsOf: piece)
            }
        }
        return unionLength(spans)
    }

    static func screenMilliseconds(screen: [String: [(Double, Double)]], hasScreenFile: Bool) -> Int {
        guard hasScreenFile else { return 0 }
        return unionLength(screen.values.flatMap(spansFrom))
    }

    static func measure(
        directory: URL,
        landed: Set<String>,
        silence: [String: [(Double, Double)]]
    ) -> (audioMs: Int, screenMs: Int) {
        let hasScreen = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .contains { $0.lastPathComponent.hasSuffix("_screen.mp4") }
        guard let file = read(directory: directory) else {
            return (0, 0)
        }
        return (
            audioMilliseconds(audio: file.audio, landed: landed, silence: silence),
            screenMilliseconds(screen: file.screen, hasScreenFile: hasScreen)
        )
    }

    private func openLocked(_ display: String, at relative: Double) {
        guard screenOpen[display] == nil else { return }
        screenOpen[display] = relative
    }

    private func closeLocked(_ display: String, at relative: Double) {
        guard let start = screenOpen.removeValue(forKey: display) else { return }
        if relative > start {
            screen[display, default: []].append((start, relative))
        }
    }

    private static func encoded(_ ranges: [String: [(Double, Double)]]) -> [String: [[Double]]] {
        var out: [String: [[Double]]] = [:]
        for (key, value) in ranges {
            out[key] = value.map { [$0.0, $0.1] }
        }
        return out
    }

    private static func decoded(_ value: Any?) -> [String: [(Double, Double)]] {
        guard let object = value as? [String: Any] else { return [:] }
        var out: [String: [(Double, Double)]] = [:]
        for (key, raw) in object {
            guard let rows = raw as? [Any] else { continue }
            var ranges: [(Double, Double)] = []
            for row in rows {
                guard let pair = row as? [Any], pair.count == 2,
                      let start = pair[0] as? NSNumber, let end = pair[1] as? NSNumber else { continue }
                ranges.append((start.doubleValue, end.doubleValue))
            }
            out[key] = ranges
        }
        return out
    }

    struct Span {
        var start: Int
        var end: Int
    }

    static func spansFrom(_ ranges: [(Double, Double)]) -> [Span] {
        ranges.compactMap { pair in
            let start = Int((pair.0 * 1000).rounded())
            let end = Int((pair.1 * 1000).rounded())
            return end > start ? Span(start: start, end: end) : nil
        }
    }

    static func subtract(_ base: [Span], _ cut: [Span]) -> [Span] {
        var out = base
        for piece in cut {
            var next: [Span] = []
            for span in out {
                if piece.end <= span.start || piece.start >= span.end {
                    next.append(span)
                } else {
                    if span.start < piece.start { next.append(Span(start: span.start, end: piece.start)) }
                    if piece.end < span.end { next.append(Span(start: piece.end, end: span.end)) }
                }
            }
            out = next
        }
        return out
    }

    static func unionLength(_ spans: [Span]) -> Int {
        let sorted = spans.sorted { $0.start < $1.start }
        var merged: [Span] = []
        for span in sorted where span.end > span.start {
            if var last = merged.last, span.start <= last.end {
                last.end = max(last.end, span.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged.reduce(0) { $0 + ($1.end - $1.start) }
    }
}
