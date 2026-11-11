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
        #expect(ScreenshotBytes.uploadName(kind: .heic, fileExtension: "heic") == "screenshot_screen.png")
        #expect(ScreenshotBytes.uploadName(kind: .pdf, fileExtension: "pdf") == "screenshot_screen.png")
        #expect(ScreenshotBytes.refused(byteCount: ScreenshotBytes.maxBytes + 1, pixelCount: 1, kind: .png))
        #expect(ScreenshotBytes.refused(byteCount: 10, pixelCount: ScreenshotBytes.maxPixels + 1, kind: .png))
        #expect(!ScreenshotBytes.refused(byteCount: 10, pixelCount: nil, kind: .png))
        #expect(!ScreenshotBytes.refused(byteCount: ScreenshotBytes.maxBytes + 1, pixelCount: nil, kind: .heic))
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

    @Test func beforeAllowTheFolderSentenceStandsBesideTheAsk() {
        var facts = ScreenshotFacts()
        #expect(presentScreenshots(facts).leavesAlone == ScreenshotCopy.desktopStays("Desktop"))
        #expect(ScreenshotSnapshot.notSetUp.leavesAlone == ScreenshotCopy.desktopStays("Desktop"))
        facts.folderIsDesktop = false
        facts.folderName = "Screenshots"
        #expect(presentScreenshots(facts).leavesAlone == ScreenshotCopy.folderStays("Screenshots"))
    }

    @Test func noAtThePromptIsNotAFaultAndAccessTakenAwayIs() {
        var facts = ScreenshotFacts()
        facts.consented = true
        facts.enabled = true
        facts.access = .denied
        facts.accessHeld = false
        let declined = presentScreenshots(facts)
        #expect(declined.state == .readyToSetUp)
        #expect(declined.subline == nil)
        #expect(declined.switchOn == false)
        #expect(declined.pageNotice == ScreenshotCopy.accessOff("Desktop"))
        #expect(declined.action == .openScreenshotSettings)
        facts.accessHeld = true
        let revoked = presentScreenshots(facts)
        #expect(revoked.state == .needsAttention)
        #expect(revoked.subline == ScreenshotCopy.accessOff("Desktop"))
        #expect(revoked.action == .openScreenshotSettings)
    }

    @Test func aCountThatFailedWaitsToBeSetUp() {
        var facts = ScreenshotFacts()
        facts.consented = true
        facts.enabled = true
        facts.count = .failed
        let failed = presentScreenshots(facts)
        #expect(failed.state == .readyToSetUp)
        #expect(failed.subline == ScreenshotCopy.chooseHowFar)
        #expect(failed.pageNotice == ScreenshotCopy.couldntCount)
        #expect(failed.action == .retryScreenshotCount)
        #expect(failed.showChooser)
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

    @Test func aRunningScreenshotsSourceCanBePausedAndResumed() {
        let idle = withScreenshotsPause((false, false), screenshotsRunning: false, screenshotsPaused: false, computerPaused: false)
        #expect(idle.pause == false && idle.resume == false)
        let running = withScreenshotsPause((false, false), screenshotsRunning: true, screenshotsPaused: false, computerPaused: false)
        #expect(running.pause && !running.resume)
        let paused = withScreenshotsPause((false, false), screenshotsRunning: false, screenshotsPaused: true, computerPaused: true)
        #expect(!paused.pause && paused.resume)
        let recording = withScreenshotsPause((true, false), screenshotsRunning: false, screenshotsPaused: false, computerPaused: false)
        #expect(recording.pause && !recording.resume)
    }

    @Test func theScreenshotToolsOwnLocationWins() {
        #expect(ScreenshotMac.locationSetting(screenshot: "~/Documents/", general: "~/Pictures") == "~/Documents/")
        #expect(ScreenshotMac.locationSetting(screenshot: nil, general: "~/Pictures") == "~/Pictures")
        #expect(ScreenshotMac.locationSetting(screenshot: "", general: nil) == nil)
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

    @Test func aConvertibleTypeIsSentAsPngOnce() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        let heic = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        reader.files = [shot(when: now(), header: heic, ext: "heic", bytes: ScreenshotBytes.maxBytes + 1, pixels: nil)]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        let snap = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.count == 1)
        #expect(transport.sent[0].fileName == "screenshot_screen.png")
        #expect(transport.sent[0].hash == "abc")
        #expect(snap.refusedLine == nil)
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.count == 1)
    }

    @Test func aSizeTheJournalWillNotKeepStaysUnsent() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        reader.files = [shot(when: now(), bytes: ScreenshotBytes.maxBytes + 1)]
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

    @Test func aSecondBackfillCountsOnlyItsOwnScreenshots() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        reader.files = [shot(path: "/Users/a/Desktop/one.png", hash: "one", when: now().addingTimeInterval(-60))]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        await engine.turnOff()
        reader.files += [
            shot(path: "/Users/a/Desktop/two.png", hash: "two", when: now().addingTimeInterval(-50)),
            shot(path: "/Users/a/Desktop/three.png", hash: "three", when: now().addingTimeInterval(-40)),
        ]
        transport.answers = [.ahead]
        await engine.turnBackOn(now: now())
        let choosing = await engine.snapshot(now: now(), pause: .running, journalID: "journal-a", paired: true)
        #expect(choosing.confirmTitle == ScreenshotCopy.confirmTitle(spanFromToday: false, count: 2))
        await engine.confirm(now: now())
        let bringing = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(bringing.progress == ScreenshotCopy.pageProgress(done: 0, total: 2))
    }

    @Test func aDifferentJournalGetsWhatTheFirstOneAlreadyHas() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        reader.files = [shot(path: "/Users/a/Desktop/one.png", hash: "one", when: now().addingTimeInterval(-60))]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.map(\.hash) == ["one"])
        let asking = await engine.tick(now: now(), pause: .running, journalID: "journal-b", serverURL: nil, paired: true, syncPaused: true)
        #expect(asking.confirmTitle == ScreenshotCopy.confirmTitle(spanFromToday: false, count: 1))
        await engine.confirm(now: now())
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-b", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.map(\.hash) == ["one", "one"])
    }

    @Test func aDeliveryIsReported() async throws {
        let reader = FakeShots()
        reader.files = [shot(when: now())]
        let reports = DeliveryReports()
        let engine = ScreenshotEngine(
            directory: try directory(), reader: reader, transport: FakeShotTransport(), timeZone: { self.denver },
            onDelivered: { await reports.add() }
        )
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        for _ in 0..<50 where await reports.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await reports.count == 1)
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await reports.count == 1)
    }

    @Test func aFolderMovedAwayAndBackNeedsNothing() async throws {
        let reader = FakeShots()
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: FakeShotTransport(), timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: nil, paired: true)
        let desktop = reader.folder
        reader.folder = ScreenshotFolder(path: "/Users/a/Documents", name: "Documents", isDesktop: false)
        let moved = await engine.tick(now: now(), pause: .running, journalID: nil, serverURL: nil, paired: true, syncPaused: true)
        #expect(moved.state == .needsAttention)
        reader.folder = desktop
        let back = await engine.tick(now: now(), pause: .running, journalID: nil, serverURL: nil, paired: true, syncPaused: true)
        #expect(back.state != .needsAttention)
        #expect(back.showChooser)
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

    @Test func aNewScreenshotThatWaitsAcrossTicksDoesNotTrap() async throws {
        let reader = FakeShots()
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: FakeShotTransport(), timeZone: { self.denver })
        let start = now()
        _ = await engine.allow(now: start, pause: .running, journalID: "journal-a", paired: false)
        await engine.confirm(now: start)
        reader.files = [shot(hash: "new", when: start.addingTimeInterval(30))]
        _ = await engine.tick(now: start.addingTimeInterval(40), pause: .running, journalID: "journal-a", serverURL: nil, paired: false, syncPaused: false)
        let held = await engine.tick(now: start.addingTimeInterval(55), pause: .running, journalID: "journal-a", serverURL: nil, paired: false, syncPaused: false)
        #expect(held.waiting == 1)
    }

    @Test func screenshotsFromBeforeTheChosenSpanStayOutAfterTheCount() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        let calendar = ScreenshotCalendar.gregorian(in: denver)
        let old = calendar.date(byAdding: .day, value: -60, to: now())!
        reader.files = [
            shot(path: "/Users/a/Desktop/recent.png", hash: "recent", when: now().addingTimeInterval(-3600)),
            shot(path: "/Users/a/Desktop/old.png", hash: "old", when: old),
        ]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.select(span: .last30Days, now: now())
        await engine.confirm(now: now())
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        reader.files.append(shot(path: "/Users/a/Desktop/later.png", hash: "later", when: now().addingTimeInterval(60)))
        let after = await engine.tick(now: now().addingTimeInterval(70), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.map(\.hash) == ["recent", "later"])
        #expect(after.waiting == 0)
    }

    @Test func aJournalThatUpdatesIsAskedAgain() async throws {
        let reader = FakeShots()
        let transport = FakeShotTransport()
        transport.capability = []
        reader.files = [shot(when: now())]
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: transport, timeZone: { self.denver })
        _ = await engine.allow(now: now(), pause: .running, journalID: "journal-a", paired: true)
        await engine.confirm(now: now())
        _ = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        transport.capability = ["screenshots"]
        let soon = await engine.tick(now: now().addingTimeInterval(10), pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false)
        #expect(transport.sent.isEmpty)
        #expect(soon.pageNotice == ScreenshotCopy.waitingForJournal)
        let later = await engine.tick(
            now: now().addingTimeInterval(ScreenshotEngine.capabilityRecheck + 10),
            pause: .running, journalID: "journal-a", serverURL: "http://127.0.0.1:9", paired: true, syncPaused: false
        )
        #expect(transport.sent.count == 1)
        #expect(later.pageNotice == nil)
    }

    @Test func noAtThePromptThenAccessLaterBringsTheChooser() async throws {
        let reader = FakeShots()
        reader.denied = true
        let engine = ScreenshotEngine(directory: try directory(), reader: reader, transport: FakeShotTransport(), timeZone: { self.denver })
        let declined = await engine.turnOn(now: now(), pause: .running, journalID: "journal-a", paired: true)
        #expect(reader.listCount > 0)
        #expect(declined.state == .readyToSetUp)
        #expect(declined.action == .openScreenshotSettings)
        #expect(declined.switchOn == false)
        reader.denied = false
        let granted = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: nil, paired: true, syncPaused: true)
        #expect(granted.showChooser)
        reader.denied = true
        let revoked = await engine.tick(now: now(), pause: .running, journalID: "journal-a", serverURL: nil, paired: true, syncPaused: true)
        #expect(revoked.state == .needsAttention)
        #expect(revoked.action == .openScreenshotSettings)
    }

    @Test func aLedgerSavedBeforeTheNewFieldsStillLoads() async throws {
        let dir = try directory()
        let old = #"{"version":1,"consented":true,"enabled":true,"confirmed":true,"wasOn":true,"path":"/Users/a/Desktop","folderName":"Desktop","isDesktop":true,"ownerChose":false,"systemPathAtConsent":"/Users/a/Desktop","access":"ok","movedName":"Desktop","span":"last30Days","deliveredByJournal":{},"items":[],"pauseWindows":[],"seenCandidates":[]}"#
        try old.write(to: dir.appendingPathComponent("ledger.json"), atomically: true, encoding: .utf8)
        let engine = ScreenshotEngine(directory: dir, reader: FakeShots(), transport: FakeShotTransport(), timeZone: { self.denver })
        let snap = await engine.snapshot(now: now(), pause: .running, journalID: nil, paired: true)
        #expect(snap.state == .on)
        #expect(snap.subline == ScreenshotCopy.fromFolder("Desktop"))
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

private actor DeliveryReports {
    var count = 0
    func add() { count += 1 }
}

private final class FakeShots: ScreenshotReading, @unchecked Sendable {
    var folder = ScreenshotFolder(path: "/Users/a/Desktop", name: "Desktop", isDesktop: true)
    var files: [ScreenshotCandidate] = []
    var listCount = 0
    var denied = false

    func systemFolder() -> ScreenshotFolder { folder }
    func homePath() -> String { "/Users/a" }
    func list(_ folder: ScreenshotFolder, now: Date) -> ScreenshotList {
        listCount += 1
        if denied { return .denied }
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

@Suite("Screenshots reading")
struct ScreenshotReadCacheTests {
    @Test func aFileIsHashedOnceUntilItChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shots-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shot.png")
        let then = Date().addingTimeInterval(-60).rounded()
        func write(_ byte: UInt8, modified: Date) throws -> URLResourceValues {
            var bytes = ScreenshotBytes.pngHeader(width: 2, height: 3)
            bytes.append(contentsOf: [UInt8](repeating: byte, count: 64))
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            // A fresh URL, as each listing gives: a URL keeps the resource values it read first.
            return try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        }
        let cache = ScreenshotReadCache()
        let first = ScreenshotMacReader.read(url, values: try write(1, modified: then), now: Date(), cache: cache)
        let sameKey = ScreenshotMacReader.read(url, values: try write(2, modified: then), now: Date(), cache: cache)
        #expect(first.sha256 != nil)
        #expect(sameKey.sha256 == first.sha256)
        #expect(cache.count == 1)
        let changed = ScreenshotMacReader.read(url, values: try write(2, modified: then.addingTimeInterval(5)), now: Date(), cache: cache)
        #expect(changed.sha256 != first.sha256)
        cache.keep(paths: [])
        #expect(cache.count == 0)
    }
}

private extension Date {
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
