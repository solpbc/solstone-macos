// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Screenshots")
struct ScreenshotLogicTests {
    private let denver = TimeZone(secondsFromGMT: -7 * 3600)!

    private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        let calendar = ScreenshotCalendar.gregorian(in: denver)
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @Test func stampMatchesTheGoldenMoment() {
        let stamp = ScreenshotStamp(date: moment(2026, 11, 3, 14, 32, 7), timeZone: denver)
        #expect(stamp.rfc3339 == "2026-11-03T14:32:07-07:00")
        #expect(stamp.day == "20261103")
        #expect(stamp.segment == "143207_1")
        let utc = ScreenshotStamp(date: Date(timeIntervalSince1970: 1793836800), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(utc.rfc3339 == "2026-11-05T00:00:00Z")
        #expect(utc.day == "20261105")
        #expect(utc.segment == "000000_1")
    }

    @Test func spanStartsMatchTheCalendar() {
        let now = moment(2026, 11, 10, 15, 0, 0)
        let calendar = ScreenshotCalendar.gregorian(in: denver)
        let today = calendar.startOfDay(for: now)
        #expect(ScreenshotSpan.last30Days.start(now: now, timeZone: denver) == calendar.date(byAdding: .day, value: -30, to: today))
        #expect(ScreenshotSpan.last6Months.start(now: now, timeZone: denver) == calendar.date(byAdding: .month, value: -6, to: today))
        #expect(ScreenshotSpan.lastYear.start(now: now, timeZone: denver) == calendar.date(byAdding: .year, value: -1, to: today))
        #expect(ScreenshotSpan.fromToday.start(now: now, timeZone: denver) == today)
        let everything = ScreenshotSpan.everything.start(now: now, timeZone: denver)
        #expect(calendar.component(.year, from: everything) == 1900)
        #expect(ScreenshotSpan.allCases.map(\.label) == [
            "the last 30 days", "the last 6 months", "the last year", "all of it", "nothing from before today",
        ])
    }

    @Test func acceptedBytesArePngJpegAndWebpOnly() {
        #expect(ScreenshotBytes.kind(header: ScreenshotBytes.pngHeader(width: 2, height: 3)) == .png)
        #expect(ScreenshotBytes.pixelCount(data: ScreenshotBytes.pngHeader(width: 2, height: 3)) == 6)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x02, 0x00, 0x03, 0x01, 0x01, 0x11, 0x00])
        #expect(ScreenshotBytes.kind(header: jpeg) == .jpeg)
        #expect(ScreenshotBytes.pixelCount(data: jpeg) == 6)
        var webp = Data(count: 30)
        webp.replaceSubrange(0..<4, with: Array("RIFF".utf8))
        webp.replaceSubrange(8..<12, with: Array("WEBP".utf8))
        webp.replaceSubrange(12..<16, with: Array("VP8X".utf8))
        webp[24] = 1
        webp[27] = 3
        #expect(ScreenshotBytes.kind(header: webp) == .webp)
        #expect(ScreenshotBytes.pixelCount(data: webp) == 8)
        #expect(ScreenshotBytes.kind(header: Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])) == .heic)
        #expect(ScreenshotBytes.kind(header: Data("GIF89a".utf8)) == .gif)
        #expect(ScreenshotBytes.kind(header: Data("%PDF".utf8)) == .pdf)
        #expect(ScreenshotBytes.kind(header: Data([0x49, 0x49, 0x2A, 0x00])) == .tiff)
        #expect(ScreenshotBytes.uploadName(kind: .jpeg, fileExtension: "jpeg") == "screenshot_screen.jpeg")
        #expect(ScreenshotBytes.uploadName(kind: .jpeg, fileExtension: "jpg") == "screenshot_screen.jpg")
        #expect(ScreenshotBytes.uploadName(kind: .heic, fileExtension: "heic") == nil)
        #expect(ScreenshotBytes.refused(byteCount: ScreenshotBytes.maxBytes + 1, pixelCount: 1, kind: .png))
        #expect(ScreenshotBytes.refused(byteCount: 10, pixelCount: ScreenshotBytes.maxPixels + 1, kind: .png))
        #expect(!ScreenshotBytes.refused(byteCount: 10, pixelCount: nil, kind: .png))
    }

    @Test func folderLineKeepsTheLastThreeParts() {
        #expect(ScreenshotPaths.folderLine(path: "/Users/a/Desktop", home: "/Users/a") == "Desktop")
        #expect(ScreenshotPaths.folderLine(path: "/Users/a/Pictures/Screenshots", home: "/Users/a") == "Pictures › Screenshots")
        #expect(ScreenshotPaths.folderLine(path: "/Users/a/Library/Cloud/OneDrive/Pictures/Screenshots", home: "/Users/a") == "OneDrive › Pictures › Screenshots")
    }

    @Test func pauseIncludesTheStartAndNotTheResume() {
        let start = moment(2026, 11, 10, 12, 0, 0)
        let end = moment(2026, 11, 10, 13, 0, 0)
        let window = [ScreenshotPauseWindow(start: start, end: end, expiration: end)]
        #expect(ScreenshotPause.excludes(start, windows: window))
        #expect(!ScreenshotPause.excludes(end, windows: window))
        #expect(ScreenshotPause.excludes(start.addingTimeInterval(60), windows: window))
    }

    @Test func aScreenCapturePlistBoolReadsTrue() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        #expect(ScreenshotMac.plistBool(data))
        #expect(!ScreenshotMac.plistBool(Data("no".utf8)))
    }

    @Test func theTileBeforeAllowAsksAndDoesNotPretendToBeOn() {
        var facts = ScreenshotFacts()
        facts.folderName = "Desktop"
        let tile = presentScreenshots(facts)
        #expect(tile.state == .readyToSetUp)
        #expect(tile.subline == nil)
        #expect(tile.action == .allowScreenshotFolder)
        #expect(tile.switchOn == false)
        #expect(tile.pageNotice == ScreenshotCopy.needsFolder("Desktop"))
    }

    @Test func bringingInCountingAndAMissingCapability() {
        var facts = ScreenshotFacts()
        facts.consented = true
        facts.enabled = true
        facts.confirmed = true
        facts.backlogOpen = true
        facts.done = 2
        facts.total = 9
        facts.paired = true
        let bringing = presentScreenshots(facts)
        #expect(bringing.subline == "2 of 9 in your journal")
        #expect(bringing.pageNotice == "2 of 9 screenshots in your journal")
        #expect(bringing.state == .on)

        facts.paired = false
        let unpaired = presentScreenshots(facts)
        #expect(unpaired.subline == "from Desktop")
        #expect(unpaired.pageNotice == nil)

        facts.paired = true
        facts.waitingForJournal = true
        let waiting = presentScreenshots(facts)
        #expect(waiting.state == .on)
        #expect(waiting.subline == "from Desktop")
        #expect(waiting.pageNotice == ScreenshotCopy.waitingForJournal)
        #expect(waiting.action == nil)

        facts.waitingForJournal = false
        facts.ownerPaused = true
        let paused = presentScreenshots(facts)
        #expect(paused.state == .paused)
        #expect(paused.subline == ScreenshotCopy.pausedSkips)
        #expect(paused.action == .resumeIntake)
    }

    @Test func theDesktopKeepsItsSentenceAndAChosenFolderDoesNot() {
        var facts = ScreenshotFacts()
        facts.consented = true
        facts.folderIsDesktop = true
        facts.folderFromOwner = false
        facts.folderName = "Desktop"
        #expect(presentScreenshots(facts).leavesAlone == "other files on your Desktop stay where they are.")
        facts.folderFromOwner = true
        #expect(presentScreenshots(facts).leavesAlone == "other files in Desktop stay where they are.")
        facts.folderFromOwner = false
        facts.folderIsDesktop = false
        facts.folderName = "Screenshots"
        #expect(presentScreenshots(facts).leavesAlone == "other files in Screenshots stay where they are.")
    }

    @Test func confirmWords() {
        #expect(ScreenshotCopy.confirmTitle(spanFromToday: true, count: 4) == "start from today")
        #expect(ScreenshotCopy.confirmTitle(spanFromToday: false, count: 0) == "start from today")
        #expect(ScreenshotCopy.confirmTitle(spanFromToday: false, count: 1) == "bring in 1 screenshot")
        #expect(ScreenshotCopy.confirmTitle(spanFromToday: false, count: 3) == "bring in 3 screenshots")
        #expect(ScreenshotCopy.refusedLine(1) == "1 screenshot can't come in, so it stays in the folder.")
        #expect(ScreenshotCopy.unreadableLine(2) == "couldn't read 2 screenshots.")
        #expect(totalWords(1, unit: .screenshots) == "1 screenshot")
        #expect(totalWords(1412, unit: .screenshots).contains("1"))
    }

    @Test func answersFollowTheContract() throws {
        let ok = try JSONEncoder().encode(["status": "ok"])
        let duplicate = try JSONEncoder().encode(["status": "duplicate"])
        let collision = try JSONEncoder().encode(["status": "collision"])
        #expect(classifyScreenshot(statusCode: 200, body: ok) == .delivered)
        #expect(classifyScreenshot(statusCode: 200, body: duplicate) == .delivered)
        #expect(classifyScreenshot(statusCode: 200, body: collision) == .delivered)
        #expect(classifyScreenshot(statusCode: 400, body: Data(#"{"reason_code":"screenshot_invalid"}"#.utf8)) == .invalid)
        #expect(classifyScreenshot(statusCode: 409, body: Data(#"{"reason_code":"screenshot_ahead"}"#.utf8)) == .ahead)
        #expect(classifyScreenshot(statusCode: 413, body: Data(#"{"reason_code":"multipart_part_too_large"}"#.utf8)) == .invalid)
        #expect(classifyScreenshot(statusCode: 503, body: Data()) == .retry)
        #expect(classifyScreenshot(statusCode: 200, body: Data("no".utf8)) == .retry)
    }
}

@Suite("Screenshots engine")
struct ScreenshotEngineTests {
    private let denver = TimeZone(secondsFromGMT: -7 * 3600)!

    private func now() -> Date {
        ScreenshotCalendar.gregorian(in: denver).date(from: DateComponents(
            year: 2026, month: 11, day: 10, hour: 15, minute: 0, second: 0
        ))!
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func shot(
        path: String = "/Users/a/Desktop/one.png",
        hash: String = "abc",
        when: Date,
        marked: Bool = true,
        stable: Bool = true,
        header: Data? = nil,
        ext: String = "png",
        bytes: Int = 32,
        pixels: Int64? = 6
    ) -> ScreenshotCandidate {
        ScreenshotCandidate(
            path: path, marked: marked, platformDate: when, fileDate: when,
            byteCount: bytes, stable: stable, header: header ?? ScreenshotBytes.pngHeader(width: 2, height: 3),
            sha256: hash, pixelCount: pixels, unreadable: false, fileExtension: ext
        )
    }

    @Test func nothingIsListedUntilAllow() async throws {
        let reader = FakeShots()
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: FakeShotTransport(), timeZone: { self.denver })
        let snap = await engine.tick(now: now(), pause: .running, journalID: nil, serverURL: nil, paired: true, syncPaused: false)
        #expect(reader.listCount == 0)
        #expect(snap.action == .allowScreenshotFolder)
        #expect(snap.switchOn == false)
    }

    @Test func confirmFreezesTheCountAndSendsEachHashOnce() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        let taken = ScreenshotCalendar.gregorian(in: denver).date(from: DateComponents(
            year: 2026, month: 11, day: 3, hour: 14, minute: 32, second: 7
        ))!
        reader.files = [
            shot(hash: "aa", when: taken),
            shot(path: "/Users/a/Desktop/photo.jpg", hash: "bb", when: taken, marked: false, ext: "jpg"),
            shot(path: "/Users/a/Desktop/same.png", hash: "aa", when: taken),
        ]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        let choosing = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        #expect(choosing.confirmTitle == "bring in 1 screenshot")
        #expect(choosing.showChooser)
        await engine.confirm(now: now())
        let sent = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.count == 1)
        #expect(transport.sent[0].fileName == "screenshot_screen.png")
        #expect(transport.sent[0].day == "20261103")
        #expect(transport.sent[0].segment == "143207_1")
        #expect(transport.sent[0].capturedAt == "2026-11-03T14:32:07-07:00")
        #expect(transport.sent[0].takenFrom == "platform")
        #expect(sent.subline == "from Desktop")
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.count == 1)
    }

    @Test func aRefusedTypeIsFinalAndStaysUnsent() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        reader.files = [shot(when: now(), header: Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]), ext: "heic")]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        let snap = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.isEmpty)
        #expect(snap.refusedLine == ScreenshotCopy.refusedLine(1))
        #expect(snap.state == .on)
        #expect(snap.subline == "from Desktop")
    }

    @Test func aFileDeletedBeforeSendCountsAndNeverGoes() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        reader.files = [shot(when: now())]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        reader.files = []
        let snap = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.isEmpty)
        #expect(snap.progress == nil)
        #expect(snap.state == .on)
    }

    @Test func pauseSkipsTheWindowAndResumeDoesNotCatchIt() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        let start = now()
        _ = await engine.allow(now: start, pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: start)
        let pausedAt = start.addingTimeInterval(60)
        _ = await engine.tick(now: pausedAt, pause: ScreenshotPauseFact(paused: true, expiration: nil), journalID: "journal-a", serverURL: nil, paired: true, syncPaused: true)
        reader.files = [shot(hash: "during", when: pausedAt.addingTimeInterval(10))]
        _ = await engine.tick(now: pausedAt.addingTimeInterval(30), pause: ScreenshotPauseFact(paused: true, expiration: nil), journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.isEmpty)
        let resume = pausedAt.addingTimeInterval(120)
        reader.files.append(shot(path: "/Users/a/Desktop/after.png", hash: "after", when: resume))
        _ = await engine.tick(now: resume, pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.map(\.hash) == ["after"])
    }

    @Test func turningOffClearsThePauseSoANewSpanCanBringIt() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        let start = now()
        _ = await engine.allow(now: start, pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: start)
        let pausedAt = start.addingTimeInterval(60)
        _ = await engine.tick(now: pausedAt, pause: ScreenshotPauseFact(paused: true, expiration: nil), journalID: "journal-a", serverURL: nil, paired: true, syncPaused: true)
        reader.files = [shot(hash: "during", when: pausedAt.addingTimeInterval(5))]
        await engine.turnOff()
        _ = await engine.tick(now: pausedAt.addingTimeInterval(10), pause: .running, journalID: "journal-a", serverURL: nil, paired: true, syncPaused: true)
        await engine.turnBackOn(now: pausedAt.addingTimeInterval(20))
        let choosing = await engine.snapshot(now: pausedAt.addingTimeInterval(20), pause: .running, journalID: "journal-a", paired: true)
        #expect(choosing.showChooser)
        #expect(choosing.showReturnNote)
        await engine.confirm(now: pausedAt.addingTimeInterval(20))
        let sent = await engine.tick(now: pausedAt.addingTimeInterval(30), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.map(\.hash) == ["during"])
        #expect(sent.state == .on)
    }

    @Test func aMovedFolderIsNotReadUntilAllow() async throws {
        let reader = FakeShots()
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: FakeShotTransport(), timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: nil, paired: true)
        let listed = reader.listCount
        reader.folder = ScreenshotFolder(path: "/Users/a/Documents", name: "Documents", isDesktop: false)
        let snap = await engine.tick(now: now(), pause: .running, journalID: nil, serverURL: nil, paired: true, syncPaused: false)
        #expect(reader.listCount == listed)
        #expect(snap.state == .needsAttention)
        #expect(snap.pageNotice == ScreenshotCopy.locationMoved("Documents"))
        #expect(snap.action == .allowScreenshotFolder)
    }

    @Test func aDifferentJournalAsksAgain() async throws {
        let reader = FakeShots()
        reader.files = [shot(when: now())]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: FakeShotTransport(), timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        let snap = await engine.tick(now: now(), pause: .running, journalID: "journal-b", serverURL: nil, paired: true, syncPaused: true)
        #expect(snap.showChooser)
        #expect(snap.showReturnNote)
        #expect(snap.switchOn)
    }

    @Test func anOlderJournalHoldsTheShots() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        transport.capability = []
        reader.files = [shot(when: now())]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        let snap = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.isEmpty)
        #expect(snap.state == .on)
        #expect(snap.pageNotice == ScreenshotCopy.waitingForJournal)
        #expect(snap.subline == "from Desktop")
    }

    @Test func aheadWaitsAndInvalidIsFinal() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        transport.answers = [.ahead]
        reader.files = [
            shot(hash: "aa", when: now()),
            shot(path: "/Users/a/Desktop/two.png", hash: "bb", when: now().addingTimeInterval(1)),
        ]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.map(\.hash) == ["aa"])
        transport.answers = [.invalid, .delivered]
        let done = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.map(\.hash) == ["aa", "aa", "bb"])
        #expect(done.refusedLine == ScreenshotCopy.refusedLine(1))
        #expect(done.state == .on)
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.count == 3)
    }

    @Test func anOldTotalsFileStillDecodesAndAHashCountsOnce() throws {
        let dir = try directory()
        let json = """
        {"version":1,"audio":{"total_seconds":1,"started":"2026-03-03","last":null,"segments":[],"remainder_ms":0},"screen":{"total_seconds":0,"started":"2026-03-03","last":null,"segments":[],"remainder_ms":0},"terminal":{"total_seconds":0,"started":"2026-03-03","last":null,"coverage":[],"carried":false},"browsers":{"total":0,"started":"2026-03-03","last":null,"tabs":{}},"obsidian":{"total":0,"started":"2026-03-03","last":null,"notes":[],"baseline":true}}
        """
        try json.write(to: dir.appendingPathComponent("source-totals.json"), atomically: true, encoding: .utf8)
        let totals = SourceTotals(directory: dir, clock: SourceTotals.Clock(now: now(), timeZone: denver))
        let view = try #require(totals.view())
        #expect(view.screenshotsTotal == 0)
        #expect(view.screenshotsStarted == "2026-03-03")
        #expect(view.audioSeconds == 1)
        #expect(totals.applyScreenshot(hash: "aa") == .applied)
        #expect(totals.applyScreenshot(hash: "aa") == .unchanged)
        #expect(totals.view()?.screenshotsTotal == 1)
    }
}

private final class FakeShots: ScreenshotReading, @unchecked Sendable {
    var folder = ScreenshotFolder(path: "/Users/a/Desktop", name: "Desktop", isDesktop: true)
    var files: [ScreenshotCandidate] = []
    var listCount = 0

    func systemFolder() -> ScreenshotFolder { folder }
    func homePath() -> String { "/Users/a" }
    func list(_ folder: ScreenshotFolder, now: Date) -> ScreenshotList {
        listCount += 1
        return .files(files)
    }
}

private final class FakeShotTransport: ScreenshotTransport, @unchecked Sendable {
    var capability = ["screenshots"]
    var answers: [ScreenshotAnswer] = [.delivered]
    var sent: [ScreenshotUpload] = []

    func capabilities(serverURL: String) async throws -> [String] { capability }

    func send(_ upload: ScreenshotUpload, serverURL: String) async -> ScreenshotAnswer {
        sent.append(upload)
        if answers.isEmpty { return .delivered }
        return answers.removeFirst()
    }
}
