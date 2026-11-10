// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import Testing
@testable import solstone

private let utc = TimeZone(secondsFromGMT: 0)!
private let denver = TimeZone(secondsFromGMT: -7 * 3600)!

private func moment(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

private func totals(at text: String = "2026-03-03T17:00:00Z", zone: TimeZone = utc) throws -> SourceTotals {
    let directory = try makeTempDirectory("source-totals")
    return SourceTotals(directory: directory, clock: .init(now: moment(text), timeZone: zone))
}

private func object(_ data: Data?) throws -> [String: Any] {
    let bytes = try #require(data)
    let parsed = try JSONSerialization.jsonObject(with: bytes)
    return try #require(parsed as? [String: Any])
}

private func source(_ root: [String: Any], _ name: String) throws -> [String: Any] {
    try #require(root[name] as? [String: Any])
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite("Source totals")
struct SourceTotalsTests {
    @Test func aNewFileStartsAtZeroOnTheLocalDay() throws {
        let morning = try totals(at: "2026-03-03T10:00:00-07:00", zone: denver)
        let next = try SourceTotals(directory: try makeTempDirectory("source-totals-next"),
                                     clock: .init(now: moment("2026-03-04T00:30:00-07:00"), timeZone: denver))
        for store in [morning, next] {
            let view = try #require(store.view())
            #expect(view.audioSeconds == 0 && view.screenSeconds == 0 && view.terminalSeconds == 0)
            #expect(view.browsersTotal == 0 && view.obsidianTotal == 0)
            #expect(view.audioLast == nil && view.screenLast == nil && view.terminalLast == nil)
            #expect(view.audioRemainderMs == 0 && view.screenRemainderMs == 0)
            #expect(view.terminalCarried == false && view.obsidianBaseline == false)
        }
        #expect(morning.view()?.audioStarted == "2026-03-03")
        #expect(next.view()?.audioStarted == "2026-03-04")
        #expect(morning.view()?.screenStarted == "2026-03-03")
        let mode = try FileManager.default.attributesOfItem(atPath: morning.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(mode?.uint16Value == 0o600)
        let root = try object(morning.bytes())
        #expect(root["version"] as? Int == 1)
        #expect(morning.fileURL.lastPathComponent == "source-totals.json")
    }

    @Test func remainderCarriesAndAZeroAddDoesNotMoveLast() throws {
        let store = try totals()
        #expect(store.applyCapture(segmentID: "d/a", audioMilliseconds: 1500, screenMilliseconds: 0) == .applied)
        #expect(store.applyCapture(segmentID: "d/b", audioMilliseconds: 1500, screenMilliseconds: 400) == .applied)
        var view = try #require(store.view())
        #expect(view.audioSeconds == 3 && view.audioRemainderMs == 0)
        #expect(view.screenSeconds == 0 && view.screenRemainderMs == 400 && view.screenLast == nil)
        #expect(view.audioSegments == ["d/a", "d/b"] && view.screenSegments == ["d/a", "d/b"])
        let last = view.audioLast
        store.setClock(.init(now: moment("2026-03-03T18:00:00Z"), timeZone: utc))
        #expect(store.applyCapture(segmentID: "d/c", audioMilliseconds: 400, screenMilliseconds: 0) == .applied)
        view = try #require(store.view())
        #expect(view.audioSeconds == 3 && view.audioRemainderMs == 400 && view.audioLast == last)

        let again = try totals()
        #expect(again.applyCapture(segmentID: "d/a", audioMilliseconds: 1600, screenMilliseconds: 0) == .applied)
        #expect(again.view()?.audioSeconds == 1 && again.view()?.audioRemainderMs == 600)
        #expect(again.applyCapture(segmentID: "d/b", audioMilliseconds: 400, screenMilliseconds: 0) == .applied)
        #expect(again.view()?.audioSeconds == 2 && again.view()?.audioRemainderMs == 0)
        let reopened = SourceTotals(directory: again.fileURL.deletingLastPathComponent(), clock: .init(now: moment("2026-03-03T17:00:00Z"), timeZone: utc))
        #expect(reopened.view()?.audioLast == again.view()?.audioLast)
        #expect(reopened.applyCapture(segmentID: "d/a", audioMilliseconds: 9999, screenMilliseconds: 9999) == .unchanged)
        #expect(reopened.view()?.audioSeconds == 2)
    }

    @Test func unreadableBytesStayAndAFailedReplaceKeepsThePreviousFile() throws {
        let directory = try makeTempDirectory("source-totals-bytes")
        let url = directory.appendingPathComponent(SourceTotals.fileName)
        let garbage = Data("not json".utf8)
        try garbage.write(to: url)
        let broken = SourceTotals(directory: directory, clock: .init(now: moment("2026-03-03T17:00:00Z"), timeZone: utc))
        #expect(broken.view() == nil)
        #expect(broken.applyCapture(segmentID: "d/a", audioMilliseconds: 1000, screenMilliseconds: 0) == .skippedUnreadable)
        #expect(broken.bytes() == garbage)
        try Data().write(to: url)
        let empty = SourceTotals(directory: directory, clock: .init(now: moment("2026-03-03T17:00:00Z"), timeZone: utc))
        #expect(empty.applyTerminal(startUnix: 0, length: 10) == .skippedUnreadable)
        #expect(empty.bytes() == Data())
        try Data(#"{"version":2}"#.utf8).write(to: url)
        let future = SourceTotals(directory: directory, clock: .init(now: moment("2026-03-03T17:00:00Z"), timeZone: utc))
        #expect(future.considerCarry(Data(#"{"version":1,"terminal":{"total_seconds":5}}"#.utf8)) == .skippedUnreadable)
        #expect(future.bytes() == Data(#"{"version":2}"#.utf8))

        let store = try totals()
        #expect(store.applyCapture(segmentID: "d/a", audioMilliseconds: 1000, screenMilliseconds: 0) == .applied)
        let before = try #require(store.bytes())
        store.setReplaceFails(true)
        #expect(store.applyCapture(segmentID: "d/b", audioMilliseconds: 5000, screenMilliseconds: 0) == .saveFailed)
        #expect(store.bytes() == before)
        #expect(store.view()?.audioSeconds == 1)
        #expect(store.view()?.audioSegments == ["d/a"])
        let reopened = SourceTotals(directory: store.fileURL.deletingLastPathComponent(), clock: .init(now: moment("2026-03-03T17:00:00Z"), timeZone: utc))
        #expect(reopened.view()?.audioSegments == ["d/a"])
    }

    @Test func audioUnionSubtractsOnlyTheSilenceThisRemixApplied() {
        let mic = ["mic": [(0.0, 10.0), (2.0, 4.0)], "system": [(5.0, 15.0)]]
        let both: Set<String> = ["mic", "system"]
        #expect(IntakeIntervalLog.audioMilliseconds(audio: mic, landed: both, silence: [:]) == 15_000)
        #expect(IntakeIntervalLog.audioMilliseconds(audio: mic, landed: both, silence: ["system": [(5, 15)]]) == 10_000)
        #expect(IntakeIntervalLog.audioMilliseconds(audio: mic, landed: both, silence: ["system": [(12, 15)]]) == 12_000)
        #expect(IntakeIntervalLog.audioMilliseconds(audio: mic, landed: ["mic"], silence: [:]) == 10_000)
        #expect(IntakeIntervalLog.screenMilliseconds(screen: ["1": [(0, 10)], "2": [(0, 10)]], hasScreenFile: true) == 10_000)
        #expect(IntakeIntervalLog.screenMilliseconds(screen: ["1": [(0, 10)]], hasScreenFile: false) == 0)
    }

    @Test func aMissingIntervalsFileAddsNothing() throws {
        let directory = try makeTempDirectory("intervals-missing")
        let measured = IntakeIntervalLog.measure(directory: directory, landed: ["mic"], silence: [:])
        #expect(measured.audioMs == 0 && measured.screenMs == 0)
        try Data("nope".utf8).write(to: directory.appendingPathComponent("intake-intervals.json"))
        let unreadable = IntakeIntervalLog.measure(directory: directory, landed: ["mic"], silence: [:])
        #expect(unreadable.audioMs == 0 && unreadable.screenMs == 0)
    }

    @Test func terminalOverlapCountsOnceAndACarryIsNotCoverage() throws {
        let root = try makeTempDirectory("terminal-coverage")
        let store = try totals()
        try finishedSegment(root: root, name: "120000_10")
        #expect(store.absorbFinishedTerminal(root: root) == .applied)
        let firstLast = store.view()?.terminalLast
        #expect(store.view()?.terminalSeconds == 10)
        try finishedSegment(root: root, name: "120006_10")
        #expect(store.absorbFinishedTerminal(root: root) == .applied)
        #expect(store.view()?.terminalSeconds == 16)
        #expect(store.view()?.terminalLast != firstLast)
        #expect(store.absorbFinishedTerminal(root: root) == .unchanged)
        #expect(store.view()?.terminalLast != nil)

        let adjacent = try makeTempDirectory("terminal-adjacent")
        let adjacentStore = try totals()
        try finishedSegment(root: adjacent, name: "120000_10")
        try finishedSegment(root: adjacent, name: "120010_10")
        #expect(adjacentStore.absorbFinishedTerminal(root: adjacent) == .applied)
        #expect(adjacentStore.view()?.terminalSeconds == 20)

        let covered = try makeTempDirectory("terminal-covered")
        let coveredStore = try totals()
        try finishedSegment(root: covered, name: "120000_20")
        #expect(coveredStore.absorbFinishedTerminal(root: covered) == .applied)
        let coveredLast = coveredStore.view()?.terminalLast
        try finishedSegment(root: covered, name: "120005_5")
        #expect(coveredStore.absorbFinishedTerminal(root: covered) == .unchanged)
        #expect(coveredStore.view()?.terminalSeconds == 20 && coveredStore.view()?.terminalLast == coveredLast)

        let shared = try makeTempDirectory("terminal-shared")
        let sharedStore = try totals()
        try finishedSegment(root: shared, name: "120000_10", files: 2)
        #expect(sharedStore.absorbFinishedTerminal(root: shared) == .applied)
        #expect(sharedStore.view()?.terminalSeconds == 10)

        let unzoned = try makeTempDirectory("terminal-zone")
        let unzonedStore = try totals()
        try finishedSegment(root: unzoned, name: "120000_10", zoneOffset: nil)
        #expect(unzonedStore.absorbFinishedTerminal(root: unzoned) == .applied)
        #expect(unzonedStore.view()?.terminalSeconds == 10)

        let unfinished = try makeTempDirectory("terminal-open")
        let unfinishedStore = try totals()
        let directory = try finishedSegment(root: unfinished, name: "120000_10")
        try Data("x".utf8).write(to: directory.deletingLastPathComponent().appendingPathComponent("120000.incomplete.meta"))
        #expect(unfinishedStore.absorbFinishedTerminal(root: unfinished) == .unchanged)
        #expect(unfinishedStore.view()?.terminalSeconds == 0)

        let carried = try totals(at: "2026-03-03T17:00:00Z")
        let started = carried.view()?.terminalStarted
        let payload = Data(#"{"version":1,"terminal":{"total_seconds":100,"started":"2020-01-01","last":"2020-01-01T00:00:00.000Z"}}"#.utf8)
        #expect(carried.considerCarry(payload) == .applied)
        #expect(carried.view()?.terminalSeconds == 100)
        #expect(carried.view()?.terminalStarted == started)
        #expect(carried.view()?.terminalLast == "2020-01-01T00:00:00.000Z")
        #expect(carried.view()?.terminalCarried == true)
        let afterCarry = try makeTempDirectory("terminal-after-carry")
        try finishedSegment(root: afterCarry, name: "130000_10")
        #expect(carried.absorbFinishedTerminal(root: afterCarry) == .applied)
        #expect(carried.view()?.terminalSeconds == 110)
        #expect(carried.considerCarry(payload) == .unchanged)

        let later = try totals(at: "2026-03-03T17:00:00Z")
        #expect(later.applyTerminal(startUnix: 1_700_000_000, length: 10) == .applied)
        let localLast = later.view()?.terminalLast
        #expect(later.considerCarry(payload) == .applied)
        #expect(later.view()?.terminalSeconds == 110)
        #expect(later.view()?.terminalLast == localLast)
        #expect(later.view()?.terminalStarted == started)

        let blank = try totals()
        #expect(blank.considerCarry(nil) == .applied)
        #expect(blank.view()?.terminalSeconds == 0 && blank.view()?.terminalCarried == true)
        #expect(blank.considerCarry(payload) == .unchanged)
        #expect(blank.view()?.terminalSeconds == 0)
    }

    @Test func pagesRememberTheLatestURLAndNotesFollowTheQueue() throws {
        let store = try totals()
        #expect(store.applyPages([(key: "tab:a:1", url: "https://one.example")]) == .applied)
        #expect(store.applyPages([(key: "tab:a:1", url: "https://one.example")]) == .unchanged)
        #expect(store.applyPages([(key: "tab:a:1", url: "https://two.example")]) == .applied)
        #expect(store.view()?.browsersTotal == 2)
        #expect(store.view()?.browsersTabs["tab:a:1"] == "https://two.example")
        let quiet = store.view()?.browsersLast
        store.setClock(.init(now: moment("2026-03-03T18:00:00Z"), timeZone: utc))
        #expect(store.applyPages([(key: "tab:a:1", url: "https://two.example")]) == .unchanged)
        #expect(store.view()?.browsersLast == quiet)

        #expect(store.applyObsidianQueue([.added("h")]) == .unchanged)
        #expect(store.view()?.obsidianBaseline == false)
        #expect(store.applyBaseline(hashes: ["kept"]) == .applied)
        #expect(store.applyBaseline(hashes: ["other"]) == .unchanged)
        #expect(store.view()?.obsidianNotes == ["kept"] && store.view()?.obsidianTotal == 0)
        #expect(store.applyObsidianQueue([.added("kept")]) == .unchanged)
        #expect(store.applyObsidianQueue([.added("new")]) == .applied)
        #expect(store.applyObsidianQueue([.renamed(from: "kept", to: "moved")]) == .applied)
        #expect(store.applyObsidianQueue([.renamed(from: "missing", to: "fresh")]) == .applied)
        #expect(store.applyObsidianQueue([.removed("moved")]) == .applied)
        let view = try #require(store.view())
        #expect(view.obsidianTotal == 1)
        #expect(view.obsidianNotes == ["new", "fresh"])
        #expect(store.applyObsidianQueue([.added("moved")]) == .applied)
        #expect(store.view()?.obsidianTotal == 2)
        let file = try #require(store.bytes())
        #expect(!file.contains(Data("secret-path".utf8)))
    }
}

@Suite("Capture counters")
struct CaptureCounterTests {
    @Test func acceptedSamplesAreRangesAndGeneratedPaddingIsNot() async throws {
        let root = try makeTempDirectory("accepted-spans")
        let url = root.appendingPathComponent("120000_audio_mic.m4a")
        let writer = try SingleTrackAudioWriter(
            url: url,
            trackType: .microphone(name: "Mic", deviceUID: "mic"),
            segmentStartTime: .zero
        )
        let buffer = try pcm(frames: 4800)
        writer.appendPCMBuffer(buffer, presentationTime: CMTime(seconds: 1.0, preferredTimescale: 48_000))
        _ = await writer.finish(captureCutoff: CMTime(seconds: 4, preferredTimescale: 48_000))
        let spans = writer.acceptedSpansSnapshot()
        #expect(spans.count == 1)
        #expect(abs(spans[0].0 - 1.0) < 0.02)
        #expect(abs(spans[0].1 - 1.1) < 0.02)
        #expect((writer.statisticsSnapshot.generatedFrames ?? 0) > 0)
        writer.writeAcceptedIntervals(into: root, source: "mic")
        let read = try #require(IntakeIntervalLog.read(directory: root))
        #expect(read.audio["mic"]?.count == 1)
        #expect(read.screen.isEmpty)
    }

    @Test func aKeptSegmentCountsBeforeTheCallbackAndAFailedRemixDoesNot() async throws {
        let parent = try makeTempDirectory("remix-count")
        let day = parent.appendingPathComponent("20260303")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let store = SourceTotals(directory: parent, clock: .init(now: moment("2026-03-03T17:00:00Z"), timeZone: utc))
        let remixer = ScriptedRemixer(.success(AudioRemixerResult(
            tracksWritten: 2, tracksSkipped: 0, sourceFiles: [],
            sources: [landed("mic"), landed("system")],
            appliedSilence: ["system": [(12, 15)]]
        )))
        let queue = RemixQueue { _ in remixer }
        await queue.setSourceTotals(store)
        let readings = Box<[Int]>([])
        await queue.setOnSegmentComplete { _, reconciliation in
            if case .failed = reconciliation { return }
            readings.value.append(store.view()?.audioSeconds ?? -1)
        }
        let first = try segment(day: day, prefix: "120000", audioMs: [(0, 1.5)], screen: false)
        await queue.enqueue(job(first, prefix: "120000"))
        await queue.waitForCompletion()
        let second = try segment(day: day, prefix: "120010", audioMs: [(0, 1.5)], screen: false)
        await queue.enqueue(job(second, prefix: "120010"))
        await queue.waitForCompletion()
        #expect(readings.value == [1, 3])
        let view = try #require(store.view())
        #expect(view.audioSeconds == 3 && view.audioRemainderMs == 0)
        #expect(view.screenSegments.count == 2 && view.screenSeconds == 0 && view.screenLast == nil)
        #expect(view.audioLast != nil)

        let partial = try segment(
            day: day,
            prefix: "120100",
            audio: ["mic": [[0.0, 10.0], [2.0, 4.0]], "system": [[5.0, 15.0]]],
            screenRanges: ["1": [[0.0, 8.0]], "2": [[2.0, 6.0]]],
            screenFiles: 2
        )
        remixer.result = .success(AudioRemixerResult(
            tracksWritten: 2, tracksSkipped: 0, sourceFiles: [],
            sources: [landed("mic"), landed("system")],
            appliedSilence: ["system": [(12, 15)]]
        ))
        await queue.enqueue(job(partial, prefix: "120100", duration: 15))
        await queue.waitForCompletion()
        let after = try #require(store.view())
        #expect(after.audioSeconds == 15 && after.screenSeconds == 8)
        let kept = day.appendingPathComponent("120100_15")
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("intake-intervals.json").path))

        let dropped = try segment(day: day, prefix: "120200", audioMs: [(0, 9)], screen: true)
        remixer.result = .failure(RemixBoom())
        await queue.enqueue(job(dropped, prefix: "120200"))
        await queue.waitForCompletion()
        #expect(store.view()?.audioSegments.contains { $0.contains("120200") } == false)
        #expect(store.view()?.audioSeconds == 15)

        let before = try #require(store.bytes())
        store.setReplaceFails(true)
        let lost = try segment(day: day, prefix: "120300", audioMs: [(0, 4)], screen: true)
        remixer.result = .success(AudioRemixerResult(
            tracksWritten: 1, tracksSkipped: 0, sourceFiles: [],
            sources: [landed("mic")]
        ))
        let ran = Box(false)
        await queue.setOnSegmentComplete { _, _ in ran.value = true }
        await queue.enqueue(job(lost, prefix: "120300"))
        await queue.waitForCompletion()
        #expect(ran.value)
        #expect(store.bytes() == before)
        #expect(store.view()?.audioSegments.contains { $0.contains("120300") } == false)
    }

    @Test func terminalIsCountedBeforeUploadAndASecondPassDoesNotAddItAgain() async throws {
        let root = try makeTempDirectory("terminal-hook")
        let store = try totals()
        try finishedSegment(root: root, name: "120000_10", files: 2)
        let transport = CountingTransport(totals: store)
        let held = Box(false)
        let planner = TerminalUploadPlanner(
            root: root, transport: transport, serverURL: { "http://127.0.0.1" }, isHeld: { held.value }, sourceTotals: store
        )
        transport.succeed = false
        await planner.planAndUpload()
        #expect(transport.seen == [10])
        #expect(store.view()?.terminalSeconds == 10)
        transport.succeed = true
        await planner.planAndUpload()
        #expect(transport.seen == [10, 10])
        #expect(store.view()?.terminalSeconds == 10)

        let heldRoot = try makeTempDirectory("terminal-held")
        let heldStore = try totals()
        try finishedSegment(root: heldRoot, name: "120000_10")
        let heldTransport = CountingTransport(totals: heldStore)
        held.value = true
        let heldPlanner = TerminalUploadPlanner(
            root: heldRoot, transport: heldTransport, serverURL: { "http://127.0.0.1" }, isHeld: { held.value }, sourceTotals: heldStore
        )
        await heldPlanner.planAndUpload()
        #expect(heldTransport.seen.isEmpty && heldStore.view()?.terminalSeconds == 10)
        held.value = false
        heldTransport.succeed = true
        await heldPlanner.planAndUpload()
        #expect(heldTransport.seen == [10] && heldStore.view()?.terminalSeconds == 10)

        let failedRoot = try makeTempDirectory("terminal-save")
        let failedStore = try totals()
        let fresh = try #require(failedStore.bytes())
        try finishedSegment(root: failedRoot, name: "120000_10")
        failedStore.setReplaceFails(true)
        let failedTransport = CountingTransport(totals: failedStore)
        let failedPlanner = TerminalUploadPlanner(
            root: failedRoot, transport: failedTransport, serverURL: { "http://127.0.0.1" }, isHeld: { false }, sourceTotals: failedStore
        )
        await failedPlanner.planAndUpload()
        #expect(failedTransport.seen.isEmpty && failedStore.bytes() == fresh)
        failedStore.setReplaceFails(false)
        failedTransport.succeed = true
        await failedPlanner.planAndUpload()
        #expect(failedTransport.seen == [10])

        let brokenRoot = try makeTempDirectory("terminal-broken")
        let brokenDirectory = brokenRoot.appendingPathComponent("counters")
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        let garbage = Data("nope".utf8)
        try garbage.write(to: brokenDirectory.appendingPathComponent(SourceTotals.fileName))
        let brokenStore = SourceTotals(directory: brokenDirectory, clock: .init(now: moment("2026-03-03T17:00:00Z"), timeZone: utc))
        try finishedSegment(root: brokenRoot, name: "120000_10")
        let brokenTransport = CountingTransport(totals: brokenStore)
        brokenTransport.succeed = true
        let brokenPlanner = TerminalUploadPlanner(
            root: brokenRoot, transport: brokenTransport, serverURL: { "http://127.0.0.1" }, isHeld: { false }, sourceTotals: brokenStore
        )
        await brokenPlanner.planAndUpload()
        #expect(brokenTransport.seen == [-1])
        #expect(brokenStore.bytes() == garbage)
    }

    @Test func theUploadListLeavesTheIntervalsFileBehind() async throws {
        let root = try makeTempDirectory("upload-list")
        let segment = root.appendingPathComponent("20260303").appendingPathComponent("120000_10")
        try FileManager.default.createDirectory(at: segment, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: segment.appendingPathComponent("120000_10_audio.m4a"))
        try Data("s".utf8).write(to: segment.appendingPathComponent("120000_10_display_1_screen.mp4"))
        try Data("s2".utf8).write(to: segment.appendingPathComponent("120000_10_display_2_screen.mp4"))
        try Data("{}".utf8).write(to: segment.appendingPathComponent("intake-intervals.json"))
        try Data("x".utf8).write(to: segment.appendingPathComponent("notes.txt"))
        let service = SyncService(
            storageManager: StorageManager(baseDirectory: root),
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1") }
        )
        let listed = try #require(await service.uploadMedia(in: segment, onFailure: { _ in })).map(\.lastPathComponent).sorted()
        #expect(listed == ["120000_10_audio.m4a", "120000_10_display_1_screen.mp4", "120000_10_display_2_screen.mp4"])
        let discovered = await service.discover()
        let media = discovered.candidatesByDay["20260303"]?.first?.media.map(\.lastPathComponent).sorted()
        #expect(media == listed)
    }

    @Test func aReportBuiltBesideTheCounterDoesNotContainIt() throws {
        let store = try totals()
        let sentinel = "https://counter-sentinel.example/only-here"
        #expect(store.applyPages([(key: "tab:a:1", url: sentinel)]) == .applied)
        let report = buildDiagnosticReport(DiagnosticReportInput(
            appVersion: "1.2.3",
            screenRecording: .granted,
            microphone: .notGranted,
            isRecording: false,
            isPaused: false,
            hasError: false,
            lastDelivery: .noDeliveryYet,
            lastJournalContact: .noSyncYet,
            evidence: .available(DiagnosticEvidenceEnvelope(schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion, entries: [])),
            ingestReason: nil,
            ingestRoute: nil,
            now: moment("2026-03-03T17:00:00Z")
        ))
        #expect(!report.text.contains(sentinel))
        #expect(!report.rows.map(\.id).contains { String(describing: $0).contains("source") })
        let defaults = UserDefaults(suiteName: "source-totals-\(UUID().uuidString)")!
        let delivery = UserDefaultsLastJournalDeliveryStore(defaults: defaults)
        let fingerprint = "sha256:" + String(repeating: "ab", count: 32)
        #expect(delivery.write(LastJournalDeliveryPayload(date: moment("2026-03-03T17:00:00Z"), fingerprint: fingerprint)) == .confirmed)
        let stored = defaults.data(forKey: UserDefaultsLastJournalDeliveryStore.storageKey) ?? Data()
        #expect(!stored.contains(Data(sentinel.utf8)))
        if case .found(let payload) = delivery.read() {
            #expect(payload.fingerprint == fingerprint)
        } else {
            Issue.record("delivery record did not read back")
        }
    }
}

@Suite("Screen hold intervals")
struct ScreenHoldIntervalTests {
    @Test @MainActor func aSiteHoldClosesOnlyThatDisplayAndAGapOrStallDoesNot() {
        let log = IntakeIntervalLog()
        log.beginDisplay("1", at: 0)
        log.beginDisplay("2", at: 0)
        log.idleSkipped(display: "1", at: 5)
        let gate = SiteFrameGate()
        gate.intakeLog = log
        let origin = ticks(100)
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Ordinary")]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: 2, title: "Covered")]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "Ordinary")]))
        var decisions = SiteDecision()
        decisions.evaluate(key: SiteDecisionKey(windowID: 1, title: "Ordinary"), initialAXTitle: "Ordinary", finalAXTitle: "Ordinary",
                           walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete), sites: ["bank.com"], now: 10, isSweep: false)
        decisions.evaluate(key: SiteDecisionKey(windowID: 2, title: "Covered"), initialAXTitle: "Covered", finalAXTitle: "Covered",
                           walk: WebAreaWalkResult(urls: ["https://login.bank.com"], completeness: .complete), sites: ["bank.com"], now: 10, isSweep: false)
        gate.updateDecisions(decisions, axAvailable: true)
        let frame = SiteHeldFrame(id: 1, displayTicks: ticks(110), c: 10, originTicks: origin)
        _ = gate.enqueue(displayID: 1, frame: frame)
        #expect(gate.evaluate(displayID: 1, now: 11) == [.drop(id: 1, reason: .cov)])
        #expect(log.screenRanges()["1"]?.count == 1)
        #expect(abs((log.screenRanges()["1"]?.first?.1 ?? 0) - 10) < 0.001)
        #expect(log.screenRanges()["2"] == nil)
        log.endAll(at: 20)
        let displayTwo = log.screenRanges()["2"] ?? []
        #expect(displayTwo.count == 1 && displayTwo.first?.0 == 0 && displayTwo.first?.1 == 20)

        let gapLog = IntakeIntervalLog()
        gapLog.beginDisplay("1", at: 0)
        let gapGate = SiteFrameGate()
        gapGate.intakeLog = gapLog
        gapGate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gapGate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gapGate.updateDecisions(decisions, axAvailable: true)
        _ = gapGate.enqueue(displayID: 1, frame: SiteHeldFrame(id: 2, displayTicks: ticks(110), c: 10, originTicks: origin))
        #expect(gapGate.evaluate(displayID: 1, now: 11) == [.drop(id: 2, reason: .gap)])
        gapLog.endAll(at: 20)
        let gapRange = gapLog.screenRanges()["1"] ?? []
        #expect(gapRange.count == 1 && gapRange.first?.0 == 0 && gapRange.first?.1 == 20)

        let stallLog = IntakeIntervalLog()
        stallLog.beginDisplay("1", at: 0)
        let stallGate = SiteFrameGate()
        stallGate.intakeLog = stallLog
        for id in UInt64(1)...5 {
            _ = stallGate.enqueue(displayID: 1, frame: SiteHeldFrame(id: id, displayTicks: ticks(100 + Double(id)), c: Double(id), originTicks: origin))
        }
        #expect(stallLog.screenRanges()["1"] == nil)
        stallLog.endAll(at: 30)
        let stallRange = stallLog.screenRanges()["1"] ?? []
        #expect(stallRange.count == 1 && stallRange.first?.0 == 0 && stallRange.first?.1 == 30)
    }
}

@Suite("Obsidian counters")
struct ObsidianCounterTests {
    @Test func aCompletedListingIsTheBaselineAndLaterNotesCountAtClose() async throws {
        let fixture = try NoteFixture()
        let store = try totals()
        let engine = fixture.engine(store)
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: moment("2026-11-08T08:00:00-07:00"))
        #expect(store.view()?.obsidianBaseline == true && store.view()?.obsidianTotal == 0)

        try fixture.write("secret-path.md", "hello")
        await engine.scan(now: moment("2026-11-08T08:30:00-07:00"))
        #expect(store.view()?.obsidianTotal == 0)
        await engine.closeDueWindows(now: moment("2026-11-08T09:00:00-07:00"))
        #expect(store.view()?.obsidianTotal == 1)
        let hash = ObsidianWire.sha256Hex(Data("secret-path.md".utf8))
        #expect(store.view()?.obsidianNotes.contains(hash) == true)
        let file = try #require(store.bytes())
        #expect(!file.contains(Data("secret-path.md".utf8)))
        #expect(try await fixture.outboxLines(engine).count == 1)

        try fixture.write("secret-path.md", "edited", at: moment("2026-11-08T09:30:00-07:00"))
        await engine.scan(now: moment("2026-11-08T10:00:00-07:00"))
        await engine.closeDueWindows(now: moment("2026-11-08T11:00:00-07:00"))
        #expect(store.view()?.obsidianTotal == 1)

        try fixture.write("huge.md", String(repeating: "x", count: ObsidianWire.maxNoteBytes + 1))
        await engine.scan(now: moment("2026-11-08T11:30:00-07:00"))
        await engine.closeDueWindows(now: moment("2026-11-08T12:30:00-07:00"))
        #expect(store.view()?.obsidianTotal == 1)
    }

    @Test func aRenameAddsNothingAndARemovedPathCanCountAgain() async throws {
        let fixture = try NoteFixture()
        try fixture.write("inbox/Alex.md", "Alex likes rivers.\n")
        let store = try totals()
        let engine = fixture.engine(store)
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: moment("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: moment("2026-11-08T09:00:00-07:00"))
        #expect(store.view()?.obsidianTotal == 0)
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.rename("inbox/Alex.md", to: "people/Alex Rivera.md")
        await engine.scan(now: moment("2026-11-08T09:43:33-07:00"))
        await engine.closeDueWindows(now: moment("2026-11-08T10:30:00-07:00"))
        #expect(store.view()?.obsidianTotal == 0)
        let old = ObsidianWire.sha256Hex(Data("inbox/Alex.md".utf8))
        let moved = ObsidianWire.sha256Hex(Data("people/Alex Rivera.md".utf8))
        #expect(store.view()?.obsidianNotes.contains(old) == false)
        #expect(store.view()?.obsidianNotes.contains(moved) == true)
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.delete("people/Alex Rivera.md")
        await engine.scan(now: moment("2026-11-08T11:00:00-07:00"))
        await engine.closeDueWindows(now: moment("2026-11-08T12:00:00-07:00"))
        await engine.scan(now: moment("2026-11-08T12:10:00-07:00"))
        await engine.closeDueWindows(now: moment("2026-11-08T13:00:00-07:00"))
        #expect(store.view()?.obsidianNotes.contains(moved) == false)
        #expect(store.view()?.obsidianTotal == 0)
        try fixture.write("people/Alex Rivera.md", "back")
        await engine.scan(now: moment("2026-11-08T13:30:00-07:00"))
        await engine.closeDueWindows(now: moment("2026-11-08T14:30:00-07:00"))
        #expect(store.view()?.obsidianTotal == 1)
        #expect(store.view()?.obsidianNotes.contains(moved) == true)
    }

    @Test func aRenameSeenBeforeTheOldPathWasRecordedAddsNothing() async throws {
        let fixture = try NoteFixture()
        let store = try totals()
        let engine = fixture.engine(store)
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: moment("2026-11-08T08:00:00-07:00"))
        try fixture.write("a.md", "alpha")
        await engine.scan(now: moment("2026-11-08T08:30:00-07:00"))
        try fixture.rename("a.md", to: "b.md")
        await engine.scan(now: moment("2026-11-08T09:00:00-07:00"))
        await engine.closeDueWindows(now: moment("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.contains { ($0["change"] as? String) == "renamed" })
        #expect(store.view()?.obsidianTotal == 0)
        #expect(store.view()?.obsidianNotes.contains(ObsidianWire.sha256Hex(Data("b.md".utf8))) == true)
    }

    @Test func aFailedSaveLeavesTheWindowPendingAndAnUnreadableFileDoesNot() async throws {
        let fixture = try NoteFixture()
        let store = try totals()
        let engine = fixture.engine(store)
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: moment("2026-11-08T08:00:00-07:00"))
        try fixture.write("n.md", "one")
        await engine.scan(now: moment("2026-11-08T08:30:00-07:00"))
        store.setReplaceFails(true)
        await engine.closeDueWindows(now: moment("2026-11-08T09:00:00-07:00"))
        #expect(await engine.outboxFiles().isEmpty)
        #expect(store.view()?.obsidianTotal == 0)
        store.setReplaceFails(false)
        await engine.closeDueWindows(now: moment("2026-11-08T09:00:00-07:00"))
        #expect(store.view()?.obsidianTotal == 1)
        #expect(try await fixture.outboxLines(engine).count == 1)

        let retry = try NoteFixture()
        let retryStore = try totals()
        let retryEngine = retry.engine(retryStore)
        await retryEngine.adoptVault(root: retry.root, name: "Notes")
        await retryEngine.setFirstSendCleared()
        await retryEngine.scan(now: moment("2026-11-08T08:00:00-07:00"))
        try retry.write("n.md", "one")
        await retryEngine.scan(now: moment("2026-11-08T08:30:00-07:00"))
        let outbox = retry.store.appendingPathComponent("outbox")
        try FileManager.default.removeItem(at: outbox)
        try Data("file".utf8).write(to: outbox)
        await retryEngine.closeDueWindows(now: moment("2026-11-08T09:00:00-07:00"))
        #expect(retryStore.view()?.obsidianTotal == 1)
        #expect(await retryEngine.outboxFiles().isEmpty)
        try FileManager.default.removeItem(at: outbox)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        await retryEngine.closeDueWindows(now: moment("2026-11-08T09:00:00-07:00"))
        #expect(retryStore.view()?.obsidianTotal == 1)
        #expect(try await retry.outboxLines(retryEngine).count == 1)

        let blind = try NoteFixture()
        try Data("nope".utf8).write(to: blind.store.appendingPathComponent(SourceTotals.fileName))
        let blindStore = SourceTotals(directory: blind.store, clock: .init(now: moment("2026-03-03T17:00:00Z"), timeZone: utc))
        let blindEngine = blind.engine(blindStore)
        await blindEngine.adoptVault(root: blind.root, name: "Notes")
        await blindEngine.setFirstSendCleared()
        try blind.write("n.md", "one")
        await blindEngine.scan(now: moment("2026-11-08T08:30:00-07:00"))
        await blindEngine.closeDueWindows(now: moment("2026-11-08T09:00:00-07:00"))
        #expect(blindStore.bytes() == Data("nope".utf8))
        #expect(try await blind.outboxLines(blindEngine).count == 1)

        let missed = try NoteFixture()
        let missedStore = try totals()
        missedStore.setReplaceFails(true)
        let missedEngine = missed.engine(missedStore)
        await missedEngine.adoptVault(root: missed.root, name: "Notes")
        await missedEngine.setFirstSendCleared()
        try missed.write("n.md", "one")
        await missedEngine.scan(now: moment("2026-11-08T08:30:00-07:00"))
        #expect(missedStore.view()?.obsidianBaseline == false)
        await missedEngine.closeDueWindows(now: moment("2026-11-08T09:00:00-07:00"))
        #expect(try await missed.outboxLines(missedEngine).count == 1)
        #expect(missedStore.view()?.obsidianTotal == 0)
        missedStore.setReplaceFails(false)
        await missedEngine.scan(now: moment("2026-11-08T10:00:00-07:00"))
        #expect(missedStore.view()?.obsidianBaseline == true)
        #expect(missedStore.view()?.obsidianTotal == 0)
    }

    @Test func anUnreadableVaultDoesNotBaseline() async throws {
        let directory = try makeTempDirectory("obsidian-blind")
        let store = try totals(at: "2026-11-08T08:00:00-07:00", zone: denver)
        let engine = ObsidianEngine(directory: directory, timeZone: { denver }, walker: { _ in .unreachable }, sourceTotals: store)
        await engine.load()
        await engine.adoptVault(root: directory.appendingPathComponent("vault"), name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: moment("2026-11-08T08:30:00-07:00"))
        #expect(store.view()?.obsidianBaseline == false)
    }
}

private func finishedSegment(root: URL, day: String = "20260101", name: String, zoneOffset: Int? = 0, files: Int = 1) throws -> URL {
    let directory = root.appendingPathComponent(day).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<files {
        try Data("body-\(index)".utf8).write(to: directory.appendingPathComponent("session_\(index).jsonl"))
    }
    if let zoneOffset {
        let zone = directory.deletingLastPathComponent().appendingPathComponent("\(name).zone.json")
        try Data("{\"utc_offset_seconds\":\(zoneOffset)}".utf8).write(to: zone)
    }
    return directory
}

private func landed(_ id: String) -> AudioSourceRemixResult {
    var source = AudioSourceRemixResult.failure(sourceID: id, stage: "reader", error: nil, state: "complete")
    source.framesCopied = 1
    return source
}

private struct RemixBoom: Error {}

private final class ScriptedRemixer: AudioRemixing, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<AudioRemixerResult, RemixBoom>
    init(_ result: Result<AudioRemixerResult, RemixBoom>) { stored = result }
    var result: Result<AudioRemixerResult, RemixBoom> {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func remix(inputs: [AudioRemixerInput], to outputURL: URL, silenceMusic: Bool) async throws -> AudioRemixerResult {
        switch result {
        case .success(let value):
            try Data("mix".utf8).write(to: outputURL)
            return value
        case .failure(let error):
            throw error
        }
    }
}

private func segment(day: URL, prefix: String, audioMs: [(Double, Double)], screen: Bool) throws -> URL {
    var audio: [String: [[Double]]] = [:]
    if !audioMs.isEmpty { audio["mic"] = audioMs.map { [$0.0, $0.1] } }
    return try segment(day: day, prefix: prefix, audio: audio, screenRanges: screen ? ["1": [[0.0, 4.0]]] : [:], screenFiles: screen ? 1 : 0)
}

private func segment(day: URL, prefix: String, audio: [String: [[Double]]], screenRanges: [String: [[Double]]], screenFiles: Int) throws -> URL {
    let directory = day.appendingPathComponent("\(prefix).incomplete")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let body: [String: Any] = ["audio": audio, "screen": screenRanges]
    try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).write(to: directory.appendingPathComponent("intake-intervals.json"))
    for index in 0..<screenFiles {
        try Data("s".utf8).write(to: directory.appendingPathComponent("\(prefix)_display_\(index + 1)_screen.mp4"))
    }
    return directory
}

private func job(_ directory: URL, prefix: String, duration: Int = 2) -> RemixQueue.RemixJob {
    let input = AudioRemixerInput(
        url: directory.appendingPathComponent("\(prefix)_audio_mic.m4a"),
        timingInfo: AudioTrackTimingInfo(startOffset: .zero, endOffset: CMTime(seconds: Double(duration), preferredTimescale: 600),
                                         trackType: .microphone(name: "Mic", deviceUID: "mic"))
    )
    return RemixQueue.RemixJob(segmentDirectory: directory, timePrefix: prefix, capturedDurationSeconds: duration,
                               audioInputs: [input], silenceMusic: true, micMetadataJSON: nil)
}

private final class CountingTransport: TerminalUploadTransport, @unchecked Sendable {
    let totals: SourceTotals
    private let lock = NSLock()
    private var readings: [Int] = []
    var succeed = false
    init(totals: SourceTotals) { self.totals = totals }
    var seen: [Int] { lock.withLock { readings } }
    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay {
        IngestProtocolV3.SegmentsDay(total: 0, items: [])
    }
    func prepareTerminalUpload(serverURL: String, segment: TerminalSpoolSegment, bodyURL: URL) throws -> PreparedIngestV3Upload {
        PreparedIngestV3Upload(request: URLRequest(url: URL(string: "http://127.0.0.1")!), bodyURL: bodyURL,
                               stagedParts: [], submittedSegment: segment.segment, metadata: segment.zone)
    }
    func uploadStaged(prepared: PreparedIngestV3Upload) async -> UploadResult {
        let seconds = totals.view()?.terminalSeconds ?? -1
        lock.withLock { readings.append(seconds) }
        guard succeed else { return .failure(URLError(.notConnectedToInternet)) }
        return .success(UploadSuccessInfo(response: IngestProtocolV3.UploadResponse(status: .ok, storedSegmentKey: prepared.submittedSegment)))
    }
}

private func pcm(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    if let samples = buffer.floatChannelData?[0] {
        for index in 0..<Int(frames) { samples[index] = 0.2 }
    }
    return buffer
}

private func ticks(_ seconds: TimeInterval) -> UInt64 {
    var info = mach_timebase_info()
    mach_timebase_info(&info)
    let nanos = seconds * 1_000_000_000
    return UInt64((nanos * Double(info.denom)) / Double(info.numer))
}

private final class NoteFixture: @unchecked Sendable {
    let root: URL
    let store: URL
    init() throws {
        let base = try makeTempDirectory("obsidian-counter")
        root = base.appendingPathComponent("Notes", isDirectory: true)
        store = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    }
    func engine(_ totals: SourceTotals) -> ObsidianEngine {
        ObsidianEngine(directory: store, timeZone: { denver }, sourceTotals: totals)
    }
    func write(_ path: String, _ text: String, at mtime: Date = moment("2026-11-08T08:00:00-07:00")) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        var times = [timeval](repeating: timeval(tv_sec: Int(mtime.timeIntervalSince1970), tv_usec: 0), count: 2)
        guard utimes(url.path, &times) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    func delete(_ path: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
    func rename(_ old: String, to new: String) throws {
        let destination = root.appendingPathComponent(new)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(old), to: destination)
    }
    func outboxLines(_ engine: ObsidianEngine) async throws -> [[String: Any]] {
        var lines: [[String: Any]] = []
        for file in await engine.outboxFiles() {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                lines.append(try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]))
            }
        }
        return lines
    }
}

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

@Suite("Browser counters")
struct BrowserCounterTests {
    private var vendorURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor")
    }

    private func authority(_ store: SourceTotals) throws -> BrowserIntakeAuthority {
        let root = try makeTempDirectory("browser-counter")
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = try BrowserIntakeStore(rootURL: root, projection: projection)
        let authority = BrowserIntakeAuthority(
            store: spool, projection: projection,
            wallClock: { moment("2023-11-14T22:13:20Z") },
            timeZone: utc
        )
        authority.setSourceTotals(store)
        return authority
    }

    private func batch(generation: String, id: String, inst: String, ctx: String, url: String, tab: Any? = nil, reason: String? = nil, delta: Bool = false) throws -> Data {
        var record: [String: Any] = [
            "t": "segment_start", "ts": 1_700_000_000_000, "ctx": ctx, "url": url,
            "blocks": [["id": "b", "text": "page"]]
        ]
        if let tab { record["tab"] = ["id": tab] }
        if let reason { record["snapshot_reason"] = reason }
        if delta {
            record = ["t": "delta", "ts": 1_700_000_000_000, "ctx": ctx, "op": "add", "block": ["id": "b", "text": "page"]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "type": "batch", "destination_generation": generation, "inst": inst,
            "batch_id": id, "queued_at_ms": 1_700_000_000_000, "records": [record]
        ])
    }

    @Test func aSnapshotCountsTheTabAndARetryOrRecoveryDoesNot() throws {
        let store = try totals(at: "2023-11-14T22:13:20Z")
        let gate = try authority(store)
        let generation = try gate.testConnectionGeneration(identityToken: "browser-counter")
        let sentinel = "https://counter-sentinel.example/only-here"
        let seen = Box(0)
        gate.beforeAcceptReply = { seen.value = store.view()?.browsersTotal ?? -1 }
        let firstID = "0123456789abcdef0123456789abcde1"
        let first = try batch(generation: generation, id: firstID, inst: "inst-a", ctx: "ctx-1", url: sentinel, tab: 7)
        let reply = try gate.accept(bytes: first, direction: "extension_to_host")
        #expect(reply["result"] as? String == "accepted")
        #expect(seen.value == 1)
        #expect(!String(describing: reply).contains(sentinel))
        #expect(!String(describing: gate.status()).contains(sentinel))
        let again = try gate.accept(bytes: first, direction: "extension_to_host")
        #expect(again["result"] as? String == "duplicate")
        #expect(store.view()?.browsersTotal == 1)

        let iframe = try batch(generation: generation, id: "0123456789abcdef0123456789abcde2", inst: "inst-a", ctx: "ctx-2", url: "https://counter-sentinel.example/frame", tab: 7)
        #expect(try gate.accept(bytes: iframe, direction: "extension_to_host")["result"] as? String == "accepted")
        #expect(store.view()?.browsersTotal == 2)
        #expect(store.view()?.browsersTabs["tab:inst-a:7"] == "https://counter-sentinel.example/frame")
        let back = try batch(generation: generation, id: "0123456789abcdef0123456789abcde3", inst: "inst-a", ctx: "ctx-1", url: sentinel, tab: 7)
        #expect(try gate.accept(bytes: back, direction: "extension_to_host")["result"] as? String == "accepted")
        #expect(store.view()?.browsersTotal == 3)
        #expect(store.view()?.browsersTabs["tab:inst-a:7"] == sentinel)

        let recovery = try batch(generation: generation, id: "0123456789abcdef0123456789abcde4", inst: "inst-a", ctx: "ctx-1", url: "https://counter-sentinel.example/recovered", tab: 7, reason: "delivery_recovery")
        #expect(try gate.accept(bytes: recovery, direction: "extension_to_host")["result"] as? String == "accepted")
        #expect(store.view()?.browsersTotal == 3)
        #expect(store.view()?.browsersTabs["tab:inst-a:7"] == sentinel)

        let one = try batch(generation: generation, id: "0123456789abcdef0123456789abcde5", inst: "inst-a", ctx: "ctx-a", url: "https://counter-sentinel.example/a")
        let two = try batch(generation: generation, id: "0123456789abcdef0123456789abcde6", inst: "inst-a", ctx: "ctx-b", url: "https://counter-sentinel.example/b")
        #expect(try gate.accept(bytes: one, direction: "extension_to_host")["result"] as? String == "accepted")
        #expect(try gate.accept(bytes: two, direction: "extension_to_host")["result"] as? String == "accepted")
        #expect(store.view()?.browsersTabs["ctx:inst-a:ctx-a"] != nil)
        #expect(store.view()?.browsersTabs["ctx:inst-a:ctx-b"] != nil)

        let other = try batch(generation: generation, id: "0123456789abcdef0123456789abcde7", inst: "inst-b", ctx: "ctx-1", url: sentinel, tab: 7)
        #expect(try gate.accept(bytes: other, direction: "extension_to_host")["result"] as? String == "accepted")
        #expect(store.view()?.browsersTabs["tab:inst-b:7"] == sentinel)

        let delta = try batch(generation: generation, id: "0123456789abcdef0123456789abcde8", inst: "inst-a", ctx: "ctx-new", url: sentinel, delta: true)
        let rejected = try gate.accept(bytes: delta, direction: "extension_to_host")
        #expect(rejected["result"] as? String == "rejected")
        let beforeFail = store.view()?.browsersTotal
        store.setReplaceFails(true)
        let lost = try batch(generation: generation, id: "0123456789abcdef0123456789abcde9", inst: "inst-a", ctx: "ctx-lost", url: "https://counter-sentinel.example/lost", tab: "lost")
        #expect(try gate.accept(bytes: lost, direction: "extension_to_host")["result"] as? String == "accepted")
        #expect(store.view()?.browsersTotal == beforeFail)
        #expect(try gate.accept(bytes: lost, direction: "extension_to_host")["result"] as? String == "duplicate")
        #expect(store.view()?.browsersTotal == beforeFail)
        let file = try #require(store.bytes())
        #expect(!file.contains(Data("https://counter-sentinel.example/lost".utf8)))
    }
}

#endif
