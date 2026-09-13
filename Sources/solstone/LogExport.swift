// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

internal struct LogExportBounds: Sendable, Equatable {
    static let requestedWindow: TimeInterval = 24 * 60 * 60
    static let maxEntries = 40_000
    static let maxBytes = 5 * 1024 * 1024
    static let maxEntryBytes = 8 * 1024
    static let previewEntryLimit = 1_000
    static let storeScopeHostLocal = "host-local"

    var requestedWindow: TimeInterval = Self.requestedWindow
    var maxEntries: Int = Self.maxEntries
    var maxBytes: Int = Self.maxBytes
    var maxEntryBytes: Int = Self.maxEntryBytes
    var previewEntryLimit: Int = Self.previewEntryLimit
}

internal struct LogExportEntry: Sendable, Equatable {
    var date: Date
    var subsystem: String
    var category: String
    var level: String
    var process: String
    var message: String
}

internal enum LogExportSubsystemRead: Sendable, Equatable {
    case entries([LogExportEntry])
    case failed(reason: String)
}

internal struct LogExportFetchSuccess: Sendable {
    var storeScope: String
    var reachedWindowStart: Bool
    var subsystems: [String: LogExportSubsystemRead]
}

internal enum LogExportFetch: Sendable {
    case failed(reason: String, storeScope: String)
    case fetched(LogExportFetchSuccess)
}

internal protocol LogExportEntrySourcing: Sendable {
    func fetch(windowStart: Date, windowEnd: Date, subsystems: [String]) async -> LogExportFetch
}

internal struct LogExportLostSubsystem: Sendable, Equatable {
    var subsystem: String
    var reason: String
}

internal enum LogExportReadOutcome: Sendable, Equatable {
    case empty
    case complete
    case partial(lost: [LogExportLostSubsystem])
    case failed(reason: String)
}

internal struct LogExportDocument: Sendable {
    var bytes: Data
    var outcome: LogExportReadOutcome
    var entryCount: Int
}

internal enum LogExportWriteFeedback: Equatable, Sendable {
    case failed
}

internal let logExportRedactionNotice = "the system log may omit some fields"

internal func buildLogExport(
    source: any LogExportEntrySourcing,
    now: Date,
    version: String,
    build: String,
    subsystems: [String] = SolstoneLogSubsystem.allForPersistedHelp,
    bounds: LogExportBounds = LogExportBounds()
) async throws -> LogExportDocument {
    try Task.checkCancellation()
    let windowEnd = now
    let windowStart = now.addingTimeInterval(-bounds.requestedWindow)
    let fetch = await source.fetch(
        windowStart: windowStart,
        windowEnd: windowEnd,
        subsystems: subsystems
    )
    try Task.checkCancellation()

    switch fetch {
    case .failed(let reason, let storeScope):
        return failedDocument(
            subsystems: subsystems,
            reason: reason,
            storeScope: storeScope,
            reachedWindowStart: false,
            version: version,
            build: build,
            bounds: bounds
        )
    case .fetched(let success):
        return try assembleFetchedDocument(
            success: success,
            subsystems: subsystems,
            windowStart: windowStart,
            windowEnd: windowEnd,
            version: version,
            build: build,
            bounds: bounds
        )
    }
}

internal func logExportPreviewText(
    from document: LogExportDocument,
    limit: Int = LogExportBounds.previewEntryLimit
) -> String {
    guard let text = String(data: document.bytes, encoding: .utf8) else {
        return ""
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if let blank = lines.firstIndex(of: "") {
        let header = lines[..<blank]
        let entries = Array(lines[(blank + 1)...].filter { !$0.isEmpty })
        let previewEntries = Array(entries.suffix(limit))
        var parts = Array(header)
        parts.append("")
        parts.append(contentsOf: previewEntries)
        return parts.joined(separator: "\n") + "\n"
    }
    if text.hasSuffix("\n") {
        return text
    }
    return text + "\n"
}

internal func shouldPublishLogExportLoad(_ generation: UInt, activeGeneration: UInt) -> Bool {
    generation == activeGeneration
}

internal func logExportOffersSave(_ outcome: LogExportReadOutcome) -> Bool {
    if case .failed = outcome {
        return false
    }
    return true
}

internal func logExportAXState(
    loading: Bool,
    document: LogExportDocument?,
    writeFailed: Bool
) -> LogExportAXState {
    if writeFailed {
        return .write_failed
    }
    if loading {
        return .working
    }
    guard let document else {
        return .idle
    }
    switch document.outcome {
    case .empty:
        return .empty
    case .complete:
        return .ready
    case .partial:
        return .partial
    case .failed:
        return .failed
    }
}

internal func performLogExportSave(
    document: LogExportDocument,
    chooseURL: (LogExportDocument) -> URL?,
    writer: any LogExportFileWriting
) -> LogExportWriteFeedback? {
    guard logExportOffersSave(document.outcome) else {
        return nil
    }
    guard let url = chooseURL(document) else {
        return nil
    }
    switch writer.writeAtomically(document.bytes, to: url) {
    case .success:
        return nil
    case .failure:
        return .failed
    }
}

private func assembleFetchedDocument(
    success: LogExportFetchSuccess,
    subsystems: [String],
    windowStart: Date,
    windowEnd: Date,
    version: String,
    build: String,
    bounds: LogExportBounds
) throws -> LogExportDocument {
    var subsystemReads: [(name: String, read: LogExportSubsystemRead)] = []
    var windowedBySubsystem: [String: [LogExportEntry]] = [:]
    var lost: [LogExportLostSubsystem] = []
    var successfulReads = 0

    for name in subsystems {
        try Task.checkCancellation()
        let read = success.subsystems[name] ?? .failed(reason: "missing")
        subsystemReads.append((name, read))
        switch read {
        case .failed(let reason):
            lost.append(LogExportLostSubsystem(subsystem: name, reason: reason))
        case .entries(let entries):
            successfulReads += 1
            let windowed = entries.filter { entry in
                entry.date >= windowStart && entry.date <= windowEnd
            }
            windowedBySubsystem[name] = windowed
        }
    }

    if successfulReads == 0 {
        let reason = lost.first?.reason ?? "missing"
        return failedDocument(
            subsystems: subsystems,
            reads: subsystemReads,
            reason: reason,
            storeScope: success.storeScope,
            reachedWindowStart: success.reachedWindowStart,
            version: version,
            build: build,
            bounds: bounds
        )
    }

    var combined: [LogExportEntry] = []
    for name in subsystems {
        combined.append(contentsOf: windowedBySubsystem[name] ?? [])
    }
    combined.sort { lhs, rhs in
        if lhs.date != rhs.date {
            return lhs.date < rhs.date
        }
        if lhs.subsystem != rhs.subsystem {
            return lhs.subsystem < rhs.subsystem
        }
        return lhs.message < rhs.message
    }

    let sourceSuccessfulCount = combined.count
    let serialized = combined.map { entry in
        (entry: entry, line: serializeLogExportEntry(entry, maxEntryBytes: bounds.maxEntryBytes))
    }

    var kept = serialized
    if kept.count > bounds.maxEntries {
        kept = Array(kept.suffix(bounds.maxEntries))
    }

    let outcome: LogExportReadOutcome
    if !lost.isEmpty {
        outcome = .partial(lost: lost)
    } else if sourceSuccessfulCount == 0 {
        outcome = .empty
    } else {
        outcome = .complete
    }

    while true {
        try Task.checkCancellation()
        let candidate = renderDocument(
            version: version,
            build: build,
            storeScope: success.storeScope,
            reachedWindowStart: success.reachedWindowStart,
            bounds: bounds,
            subsystems: subsystemReads,
            windowedBySubsystem: windowedBySubsystem,
            kept: kept,
            sourceSuccessfulCount: sourceSuccessfulCount
        )
        if candidate.utf8.count <= bounds.maxBytes || kept.isEmpty {
            return LogExportDocument(
                bytes: Data(candidate.utf8),
                outcome: outcome,
                entryCount: kept.count
            )
        }
        kept.removeFirst()
    }
}

private func failedDocument(
    subsystems: [String],
    reason: String,
    storeScope: String,
    reachedWindowStart: Bool,
    version: String,
    build: String,
    bounds: LogExportBounds
) -> LogExportDocument {
    let reads = subsystems.map { name in
        (name: name, read: LogExportSubsystemRead.failed(reason: reason))
    }
    return failedDocument(
        subsystems: subsystems,
        reads: reads,
        reason: reason,
        storeScope: storeScope,
        reachedWindowStart: reachedWindowStart,
        version: version,
        build: build,
        bounds: bounds
    )
}

private func failedDocument(
    subsystems: [String],
    reads: [(name: String, read: LogExportSubsystemRead)],
    reason: String,
    storeScope: String,
    reachedWindowStart: Bool,
    version: String,
    build: String,
    bounds: LogExportBounds
) -> LogExportDocument {
    _ = subsystems
    let text = renderDocument(
        version: version,
        build: build,
        storeScope: storeScope,
        reachedWindowStart: reachedWindowStart,
        bounds: bounds,
        subsystems: reads,
        windowedBySubsystem: [:],
        kept: [],
        sourceSuccessfulCount: 0
    )
    return LogExportDocument(
        bytes: Data(text.utf8),
        outcome: .failed(reason: reason),
        entryCount: 0
    )
}

private func renderDocument(
    version: String,
    build: String,
    storeScope: String,
    reachedWindowStart: Bool,
    bounds: LogExportBounds,
    subsystems: [(name: String, read: LogExportSubsystemRead)],
    windowedBySubsystem: [String: [LogExportEntry]],
    kept: [(entry: LogExportEntry, line: String)],
    sourceSuccessfulCount: Int
) -> String {
    let dropped = sourceSuccessfulCount - kept.count
    let truncated = dropped > 0
    let realizedFirst = kept.first.map { logExportISO8601($0.entry.date) } ?? "none"
    let realizedLast = kept.last.map { logExportISO8601($0.entry.date) } ?? "none"
    var lines = [
        "version: \(version)",
        "build: \(build)",
        "store-scope: \(storeScope)",
        "requested-window-hours: \(Int(bounds.requestedWindow / 3600))",
        "requested-max-entries: \(bounds.maxEntries)",
        "requested-max-bytes: \(bounds.maxBytes)",
        "realized-first: \(realizedFirst)",
        "realized-last: \(realizedLast)",
        "realized-count: \(kept.count)",
        "reached-window-start: \(reachedWindowStart ? "yes" : "no")",
        "truncated: \(truncated ? "yes" : "no")",
        "dropped-count: \(dropped)",
        "redaction-notice: \(logExportRedactionNotice)"
    ]
    for item in subsystems {
        lines.append(subsystemHeaderLine(item.name, read: item.read, windowed: windowedBySubsystem[item.name] ?? []))
    }
    if kept.isEmpty {
        return lines.joined(separator: "\n") + "\n"
    }
    return lines.joined(separator: "\n")
        + "\n\n"
        + kept.map(\.line).joined(separator: "\n")
        + "\n"
}

private func subsystemHeaderLine(
    _ name: String,
    read: LogExportSubsystemRead,
    windowed: [LogExportEntry]
) -> String {
    switch read {
    case .failed(let reason):
        let sanitized = reason.replacingOccurrences(of: "\n", with: " ")
        return "subsystem: \(name) failed count=0 reason=\(sanitized)"
    case .entries:
        if windowed.isEmpty {
            return "subsystem: \(name) empty count=0"
        }
        return "subsystem: \(name) ok count=\(windowed.count)"
    }
}

internal func serializeLogExportEntry(_ entry: LogExportEntry, maxEntryBytes: Int) -> String {
    let timestamp = logExportISO8601(entry.date)
    let process = entry.process.isEmpty ? "-" : entry.process
    let prefix = "\(timestamp) \(entry.subsystem) \(entry.category) \(entry.level) \(process) "
    let message = entry.message
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    let full = prefix + message
    if full.utf8.count <= maxEntryBytes {
        return full
    }
    let mark = " [truncated]"
    let budget = maxEntryBytes - prefix.utf8.count - mark.utf8.count
    if budget >= 0 {
        return prefix + truncateToUTF8ByteLimit(message, maxBytes: budget) + mark
    }
    let markBudget = maxEntryBytes - mark.utf8.count
    if markBudget > 0 {
        return truncateToUTF8ByteLimit(prefix, maxBytes: markBudget) + mark
    }
    return truncateToUTF8ByteLimit(full, maxBytes: maxEntryBytes)
}

internal func logExportISO8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

private func truncateToUTF8ByteLimit(_ string: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    let data = Data(string.utf8)
    if data.count <= maxBytes {
        return string
    }
    var end = maxBytes
    while end > 0 {
        let slice = data.prefix(end)
        if let value = String(data: Data(slice), encoding: .utf8) {
            return value
        }
        end -= 1
    }
    return ""
}
