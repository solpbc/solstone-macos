// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
@testable import solstone

@Suite("LogExport")
struct LogExportTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let version = "2.0.0"
    private let build = "42"

    @Test func twoProcessesOnSameSubsystemAppearOldestFirstWithDistinctProcess() async throws {
        let subsystem = SolstoneLogSubsystem.observer
        let older = entry(date: now.addingTimeInterval(-30), subsystem: subsystem, process: "solstone", message: "first")
        let newer = entry(date: now.addingTimeInterval(-10), subsystem: subsystem, process: "watchdog", message: "second")
        let document = try await buildLogExport(
            source: fake(overrides: [subsystem: .entries([newer, older])]),
            now: now,
            version: version,
            build: build
        )
        let lines = entryLines(document)
        #expect(lines.count == 2)
        #expect(lines[0].contains(" solstone "))
        #expect(lines[0].contains(" first"))
        #expect(lines[1].contains(" watchdog "))
        #expect(lines[1].contains(" second"))
        #expect(lines[0].contains(subsystem))
        #expect(lines[1].contains(subsystem))
        #expect(headerValue(document, "realized-first") == logExportISO8601(older.date))
        #expect(headerValue(document, "realized-last") == logExportISO8601(newer.date))
    }

    @Test func headerSubsystemLinesFollowAllForPersistedHelpEmptyVsFailedShapes() async throws {
        let names = SolstoneLogSubsystem.allForPersistedHelp
        let failed = names[1]
        let populated = names[0]
        let document = try await buildLogExport(
            source: fake(overrides: [
                populated: .entries([entry(date: now.addingTimeInterval(-5), subsystem: populated)]),
                failed: .failed(reason: "nope")
            ]),
            now: now,
            version: version,
            build: build
        )
        let lines = headerLines(document)
        let subsystemLines = lines.filter { $0.hasPrefix("subsystem: ") }
        #expect(subsystemLines.count == names.count)
        for (index, name) in names.enumerated() {
            #expect(subsystemLines[index].hasPrefix("subsystem: \(name) "))
        }
        #expect(subsystemLines[0].contains(" ok count=1"))
        #expect(subsystemLines[1] == "subsystem: \(failed) failed count=0 reason=nope")
        for line in subsystemLines.dropFirst(2) {
            #expect(line.hasSuffix(" empty count=0"))
            #expect(!line.contains(" failed "))
        }
    }

    @Test func headerRequestedWindowAndBoundsArePresent() async throws {
        #expect(LogExportBounds.maxEntries == 40_000)
        #expect(LogExportBounds.maxBytes == 5_242_880)
        #expect(LogExportBounds.requestedWindow == 24 * 60 * 60)
        #expect(LogExportBounds.maxEntryBytes == 8_192)
        #expect(LogExportBounds.previewEntryLimit == 1_000)

        let document = try await buildLogExport(
            source: fake(),
            now: now,
            version: version,
            build: build
        )
        #expect(headerValue(document, "requested-window-hours") == "24")
        #expect(headerValue(document, "requested-max-entries") == "40000")
        #expect(headerValue(document, "requested-max-bytes") == "5242880")
    }

    @Test func oversizeEntryIsKeptAndMarkedTruncated() async throws {
        let subsystem = SolstoneLogSubsystem.observer
        let huge = String(repeating: "m", count: 20_000)
        let document = try await buildLogExport(
            source: fake(overrides: [
                subsystem: .entries([entry(date: now.addingTimeInterval(-1), subsystem: subsystem, message: huge)])
            ]),
            now: now,
            version: version,
            build: build
        )
        let lines = entryLines(document)
        #expect(lines.count == 1)
        #expect(lines[0].hasSuffix(" [truncated]"))
        #expect(lines[0].utf8.count <= LogExportBounds.maxEntryBytes)
        #expect(document.entryCount == 1)
        if case .failed = document.outcome {
            Issue.record("oversize entry should not fail the read")
        }
    }

    @Test func boundHitKeepsNewestSuffixAndReportsDropped() async throws {
        let subsystem = SolstoneLogSubsystem.observer
        let entries = (0..<5).map { index in
            entry(
                date: now.addingTimeInterval(TimeInterval(index - 5)),
                subsystem: subsystem,
                message: "m\(index)"
            )
        }
        let bounds = LogExportBounds(maxEntries: 3)
        let document = try await buildLogExport(
            source: fake(overrides: [subsystem: .entries(entries)]),
            now: now,
            version: version,
            build: build,
            bounds: bounds
        )
        let lines = entryLines(document)
        #expect(lines.count == 3)
        #expect(lines[0].contains(" m2"))
        #expect(lines[2].contains(" m4"))
        #expect(headerValue(document, "truncated") == "yes")
        #expect(headerValue(document, "dropped-count") == "2")
        #expect(headerValue(document, "realized-first") == logExportISO8601(entries[2].date))
        #expect(headerValue(document, "realized-last") == logExportISO8601(entries[4].date))
        #expect(headerValue(document, "realized-count") == "3")
    }

    @Test func boundNotHitReportsDroppedZero() async throws {
        let subsystem = SolstoneLogSubsystem.observer
        let document = try await buildLogExport(
            source: fake(overrides: [
                subsystem: .entries([
                    entry(date: now.addingTimeInterval(-2), subsystem: subsystem, message: "a"),
                    entry(date: now.addingTimeInterval(-1), subsystem: subsystem, message: "b")
                ])
            ]),
            now: now,
            version: version,
            build: build
        )
        #expect(headerValue(document, "truncated") == "no")
        #expect(headerValue(document, "dropped-count") == "0")
        #expect(entryLines(document).count == 2)
    }

    @Test func everyHeaderKeyPresentStoreScopeAndReachedWindowStartPlumbed() async throws {
        let yes = try await buildLogExport(
            source: fake(storeScope: "injected-scope", reachedWindowStart: true),
            now: now,
            version: version,
            build: build
        )
        for key in [
            "version",
            "build",
            "store-scope",
            "requested-window-hours",
            "requested-max-entries",
            "requested-max-bytes",
            "realized-first",
            "realized-last",
            "realized-count",
            "reached-window-start",
            "truncated",
            "dropped-count",
            "redaction-notice"
        ] {
            #expect(headerValue(yes, key) != nil, "missing \(key)")
        }
        #expect(headerValue(yes, "version") == version)
        #expect(headerValue(yes, "build") == build)
        #expect(headerValue(yes, "store-scope") == "injected-scope")
        #expect(headerValue(yes, "reached-window-start") == "yes")

        let no = try await buildLogExport(
            source: fake(reachedWindowStart: false),
            now: now,
            version: version,
            build: build
        )
        #expect(headerValue(no, "reached-window-start") == "no")
        #expect(headerValue(no, "store-scope") == LogExportBounds.storeScopeHostLocal)
    }

    @Test func redactionNoticeKeyPresentAndNonEmpty() async throws {
        let document = try await buildLogExport(
            source: fake(),
            now: now,
            version: version,
            build: build
        )
        let value = headerValue(document, "redaction-notice")
        #expect(value != nil)
        #expect(!(value ?? "").isEmpty)
    }

    @Test func saveWritesDocumentBytesWithoutFetchingAgain() async throws {
        let subsystem = SolstoneLogSubsystem.observer
        let firstEntries = [entry(date: now.addingTimeInterval(-3), subsystem: subsystem, message: "one")]
        let secondEntries = [entry(date: now.addingTimeInterval(-2), subsystem: subsystem, message: "two")]
        let source = FakeLogExportSource(
            first: .fetched(
                LogExportFetchSuccess(
                    storeScope: LogExportBounds.storeScopeHostLocal,
                    reachedWindowStart: true,
                    subsystems: filled([subsystem: .entries(firstEntries)])
                )
            ),
            second: .fetched(
                LogExportFetchSuccess(
                    storeScope: LogExportBounds.storeScopeHostLocal,
                    reachedWindowStart: true,
                    subsystems: filled([subsystem: .entries(secondEntries)])
                )
            )
        )
        let document = try await buildLogExport(
            source: source,
            now: now,
            version: version,
            build: build
        )
        #expect(source.fetchCount == 1)
        let directory = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-log-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dest = directory.appendingPathComponent("solstone-logs.txt")
        let feedback = performLogExportSave(
            document: document,
            chooseURL: { _ in dest },
            writer: LogExportAtomicWriter()
        )
        #expect(feedback == nil)
        #expect(source.fetchCount == 1)
        let saved = try Data(contentsOf: dest)
        #expect(saved == document.bytes)
        let second = try await buildLogExport(
            source: source,
            now: now,
            version: version,
            build: build
        )
        #expect(source.fetchCount == 2)
        #expect(second.bytes != document.bytes)
    }

    @Test func previewShowsHeaderPlusNewestSubsetNotInBytes() async throws {
        let subsystem = SolstoneLogSubsystem.observer
        let entries = (0..<5).map { index in
            entry(
                date: now.addingTimeInterval(TimeInterval(index - 5)),
                subsystem: subsystem,
                message: "e\(index)"
            )
        }
        let document = try await buildLogExport(
            source: fake(overrides: [subsystem: .entries(entries)]),
            now: now,
            version: version,
            build: build
        )
        let preview = logExportPreviewText(from: document, limit: 2)
        #expect(preview.contains("version: \(version)"))
        #expect(preview.contains("e3"))
        #expect(preview.contains("e4"))
        #expect(!preview.contains("e0"))
        let full = String(data: document.bytes, encoding: .utf8) ?? ""
        #expect(full.contains("e0"))
        #expect(!document.bytes.map { String(data: Data([$0]), encoding: .utf8) ?? "" }
            .joined()
            .contains("showing the newest"))
        #expect(!(String(data: document.bytes, encoding: .utf8) ?? "").contains("showing the newest"))
    }

    @Test func storeFailureAndAllSubsystemsFailedAreOutrightFailedWithoutSave() async throws {
        let storeFail = try await buildLogExport(
            source: FakeLogExportSource(
                first: .failed(reason: "store down", storeScope: "host-local")
            ),
            now: now,
            version: version,
            build: build
        )
        #expect(storeFail.outcome == .failed(reason: "store down"))
        #expect(!logExportOffersSave(storeFail.outcome))
        #expect(headerValue(storeFail, "realized-count") == "0")
        for name in SolstoneLogSubsystem.allForPersistedHelp {
            #expect(headerLines(storeFail).contains { $0 == "subsystem: \(name) failed count=0 reason=store down" })
        }

        let allFailed = Dictionary(
            uniqueKeysWithValues: SolstoneLogSubsystem.allForPersistedHelp.map {
                ($0, LogExportSubsystemRead.failed(reason: "gone"))
            }
        )
        let fetchedFail = try await buildLogExport(
            source: FakeLogExportSource(
                first: .fetched(
                    LogExportFetchSuccess(
                        storeScope: "host-local",
                        reachedWindowStart: false,
                        subsystems: allFailed
                    )
                )
            ),
            now: now,
            version: version,
            build: build
        )
        #expect(fetchedFail.outcome == .failed(reason: "gone"))
        #expect(!logExportOffersSave(fetchedFail.outcome))
    }

    @Test func partialKeepsEntriesNamesLostAndAllowsSave() async throws {
        let names = SolstoneLogSubsystem.allForPersistedHelp
        let kept = names[0]
        let lost = names[2]
        let document = try await buildLogExport(
            source: fake(overrides: [
                kept: .entries([entry(date: now.addingTimeInterval(-1), subsystem: kept, message: "kept")]),
                lost: .failed(reason: "timeout")
            ]),
            now: now,
            version: version,
            build: build
        )
        guard case .partial(let lostList) = document.outcome else {
            Issue.record("expected partial")
            return
        }
        #expect(lostList.map(\.subsystem) == [lost])
        #expect(lostList.first?.reason == "timeout")
        #expect(logExportOffersSave(document.outcome))
        #expect(entryLines(document).contains { $0.contains(" kept") })
    }

    @Test func emptySuccessIsHeaderOnlyRealizedCountZero() async throws {
        let document = try await buildLogExport(
            source: fake(),
            now: now,
            version: version,
            build: build
        )
        #expect(document.outcome == .empty)
        #expect(headerValue(document, "realized-count") == "0")
        #expect(headerValue(document, "realized-first") == "none")
        #expect(headerValue(document, "realized-last") == "none")
        #expect(entryLines(document).isEmpty)
        #expect(logExportOffersSave(document.outcome))
        let text = String(data: document.bytes, encoding: .utf8) ?? ""
        #expect(!text.contains("\n\n"))
    }

    @Test func writeFailureIsNotReadFailureAndLeavesDestAndCleansTemp() async throws {
        let subsystem = SolstoneLogSubsystem.observer
        let document = try await buildLogExport(
            source: fake(overrides: [
                subsystem: .entries([entry(date: now.addingTimeInterval(-1), subsystem: subsystem)])
            ]),
            now: now,
            version: version,
            build: build
        )
        #expect(document.outcome == .complete)

        let parent = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-log-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let dest = parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let result = LogExportAtomicWriter().writeAtomically(document.bytes, to: dest)
        #expect(result.isFailure)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix(".") && $0.contains(".tmp") }
        #expect(leftovers.isEmpty)

        let missingParent = parent.appendingPathComponent("missing", isDirectory: true)
        let missingDest = missingParent.appendingPathComponent("solstone-logs.txt")
        let absent = LogExportAtomicWriter().writeAtomically(document.bytes, to: missingDest)
        #expect(absent.isFailure)
        #expect(!FileManager.default.fileExists(atPath: missingDest.path))

        let injected = performLogExportSave(
            document: document,
            chooseURL: { _ in dest },
            writer: FailingLogExportWriter()
        )
        #expect(injected == .failed)
        #expect(document.outcome == .complete)
    }

    @Test func logExportTestsDoNotConstructOSLogStore() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let storeType = "OSLog" + "Store"
        #expect(!source.contains(storeType + ".local"))
        #expect(!source.contains(storeType + ".init"))
        #expect(!source.contains("import " + "OSLog"))
    }

    @Test func byteBoundDropsOldestWhileKeepingNewest() async throws {
        let subsystem = SolstoneLogSubsystem.observer
        let payload = String(repeating: "x", count: 400)
        let entries = (0..<6).map { index in
            entry(
                date: now.addingTimeInterval(TimeInterval(index - 6)),
                subsystem: subsystem,
                message: "\(index)-\(payload)"
            )
        }
        let bounds = LogExportBounds(maxBytes: 2_800)
        let document = try await buildLogExport(
            source: fake(overrides: [subsystem: .entries(entries)]),
            now: now,
            version: version,
            build: build,
            bounds: bounds
        )
        #expect(headerValue(document, "truncated") == "yes")
        let kept = entryLines(document)
        #expect(!kept.isEmpty)
        #expect(kept.last?.contains("5-\(payload)") == true)
        #expect(Int(headerValue(document, "dropped-count") ?? "0") ?? 0 > 0)
        #expect(document.bytes.count <= bounds.maxBytes)
    }

    private func fake(
        overrides: [String: LogExportSubsystemRead] = [:],
        storeScope: String = LogExportBounds.storeScopeHostLocal,
        reachedWindowStart: Bool = true
    ) -> FakeLogExportSource {
        FakeLogExportSource(
            first: .fetched(
                LogExportFetchSuccess(
                    storeScope: storeScope,
                    reachedWindowStart: reachedWindowStart,
                    subsystems: filled(overrides)
                )
            )
        )
    }

    private func filled(_ overrides: [String: LogExportSubsystemRead]) -> [String: LogExportSubsystemRead] {
        Dictionary(uniqueKeysWithValues: SolstoneLogSubsystem.allForPersistedHelp.map { name in
            (name, overrides[name] ?? .entries([]))
        })
    }

    private func entry(
        date: Date,
        subsystem: String,
        category: String = "general",
        level: String = "info",
        process: String = "solstone",
        message: String = "hello"
    ) -> LogExportEntry {
        LogExportEntry(
            date: date,
            subsystem: subsystem,
            category: category,
            level: level,
            process: process,
            message: message
        )
    }

    private func headerLines(_ document: LogExportDocument) -> [String] {
        let text = String(data: document.bytes, encoding: .utf8) ?? ""
        if let blank = text.range(of: "\n\n") {
            return String(text[..<blank.lowerBound]).split(separator: "\n").map(String.init)
        }
        return text.split(separator: "\n").map(String.init)
    }

    private func entryLines(_ document: LogExportDocument) -> [String] {
        let text = String(data: document.bytes, encoding: .utf8) ?? ""
        guard let blank = text.range(of: "\n\n") else { return [] }
        return String(text[blank.upperBound...])
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func headerValue(_ document: LogExportDocument, _ key: String) -> String? {
        let prefix = "\(key): "
        return headerLines(document).first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

private final class FakeLogExportSource: LogExportEntrySourcing, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetchCount = 0
    private let first: LogExportFetch
    private let second: LogExportFetch?

    init(first: LogExportFetch, second: LogExportFetch? = nil) {
        self.first = first
        self.second = second
    }

    var fetchCount: Int {
        lock.withLock { _fetchCount }
    }

    func fetch(windowStart: Date, windowEnd: Date, subsystems: [String]) async -> LogExportFetch {
        _ = windowStart
        _ = windowEnd
        _ = subsystems
        let count = lock.withLock { _fetchCount += 1; return _fetchCount }
        if count == 1 {
            return first
        }
        return second ?? first
    }
}

private struct FailingLogExportWriter: LogExportFileWriting {
    func writeAtomically(_ data: Data, to destination: URL) -> Result<Void, Error> {
        _ = data
        _ = destination
        return .failure(NSError(domain: "LogExportTests", code: 1))
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
