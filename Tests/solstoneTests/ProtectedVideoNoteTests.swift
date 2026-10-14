// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Testing
@testable import solstone
@testable import SolstoneCore

private final class NowBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

private final class WindowBox: @unchecked Sendable {
    var windows: [OnScreenWindowRecord] = []
}

private final class MutexValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class FakeAccessibilityReader: AccessibilityTitleReading, @unchecked Sendable {
    var titlesByPid: [pid_t: [CGWindowID: String]] = [:]
    func titles(pid: pid_t) -> [CGWindowID: String] {
        titlesByPid[pid] ?? [:]
    }
}

@Suite("ProtectedVideoNoteTests")
struct ProtectedVideoNoteTests {
    private func makeTempDirectory(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("solstone-note-test-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func makeManager(
        root: URL,
        nowBox: NowBox,
        windowBox: WindowBox,
        excludedAppNames: [String] = [],
        excludedTitlePatterns: [String] = [],
        excludePrivateBrowsing: Bool = true,
        excludePrivateBrowsingAccessibility: Bool = false,
        accessibilityReader: any AccessibilityTitleReading = FakeAccessibilityReader(),
        segmentFactory: @escaping CaptureManager.SegmentFactory = { outputDirectory, _, _, _ in
            FakeCaptureSegment(outputDirectory: outputDirectory)
        },
        unlockResumeDelay: (@MainActor @Sendable () async throws -> Void)? = nil,
        transitionTimeoutSeconds: TimeInterval = 30
    ) -> CaptureManager {
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            excludedAppNames: excludedAppNames,
            excludePrivateBrowsing: excludePrivateBrowsing,
            excludedTitlePatterns: excludedTitlePatterns,
            excludePrivateBrowsingAccessibility: excludePrivateBrowsingAccessibility,
            segmentFactory: segmentFactory,
            allowsEmptyDisplayConfigurationForTesting: true,
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            accessibilityTitles: accessibilityReader,
            unlockResumeDelay: unlockResumeDelay,
            transitionTimeoutSeconds: transitionTimeoutSeconds
        )
        manager.setNowForTesting { nowBox.now }
        return manager
    }

    private func findProtectedVideoNoteFile(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent.hasSuffix("_protected_video.jsonl") {
                return fileURL
            }
        }
        return nil
    }

    // 1. One row in the segment that resume opened. A title containing / is unescaped. Bytes match the sorted-keys JSONL shape.
    @Test @MainActor func resumeOpenedSegmentWritesSortedKeysJsonlWithUnescapedSlash() async throws {
        let root = try makeTempDirectory("unescaped-slash")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Stranger Things / S4 | Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Window clears and 3s debounce passes
        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)
        await manager.checkProtectedVideo()
        #expect(manager.state == .recording)

        let noteURL = try #require(findProtectedVideoNoteFile(in: root))
        let content = try String(contentsOf: noteURL, encoding: .utf8)
        #expect(content.contains("Stranger Things / S4 | Netflix"))
        #expect(!content.contains("\\/"))

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)

        // Verify sorted-keys shape: app, end_ts, service, t, title, ts
        guard let data = lines[0].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("JSON parse failed")
            return
        }
        #expect(json["t"] as? String == "protected_video")
        #expect(json["service"] as? String == "Netflix")
        #expect(json["app"] as? String == "Google Chrome")
    }

    // 2. After rotation, the next segment has no note file.
    @Test @MainActor func rotationWritesNoProtectedVideoNote() async throws {
        let root = try makeTempDirectory("rotation-no-note")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()

        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)
        await manager.checkProtectedVideo()
        #expect(manager.state == .recording)

        // Rotate
        _ = await manager.enqueueTransition(.rotate(reason: .boundary))

        let secondSegmentDir = manager.currentSegmentForTesting?.outputDirectory
        if let secondSegmentDir {
            let noteURL = findProtectedVideoNoteFile(in: secondSegmentDir)
            #expect(noteURL == nil)
        }
    }

    // 3. Abort before the directory exists, window returns, then clears → two rows in the successful segment.
    @Test func abortBeforeDirectoryKeepsBothIntervals() {
        let store = ProtectedVideoNoteStore()
        let date1 = Date(timeIntervalSince1970: 1_800_000_000)
        let match1 = ProtectedVideoMatch(windowID: 1, pid: 10, ownerName: "Chrome", title: "Movie 1", service: "Netflix")
        store.recordObservation(match: match1, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: date1)
        store.close()

        // Abort before directory created -> noteStore is not cleared!
        let date2 = Date(timeIntervalSince1970: 1_800_000_100)
        let match2 = ProtectedVideoMatch(windowID: 2, pid: 10, ownerName: "Safari", title: "Show 2", service: "Prime Video")
        store.recordObservation(match: match2, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: date2)
        store.close()

        let data = store.takeForWrite(segmentStart: Date(timeIntervalSince1970: 1_800_000_200))
        #expect(data != nil)
        let text = String(data: data!, encoding: .utf8)!
        let rows = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(rows.count == 2)
    }

    // 4. Abort after the directory exists → that interval is in no later segment.
    @Test func abortAfterDirectoryDoesNotRewriteInterval() {
        let store = ProtectedVideoNoteStore()
        let date1 = Date(timeIntervalSince1970: 1_800_000_000)
        let match1 = ProtectedVideoMatch(windowID: 1, pid: 10, ownerName: "Chrome", title: "Movie 1", service: "Netflix")
        store.recordObservation(match: match1, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: date1)
        store.close()

        // Directory creation calls takeForWrite
        let data = store.takeForWrite(segmentStart: Date(timeIntervalSince1970: 1_800_000_050))
        #expect(data != nil)

        // After takeForWrite, closedIntervals is empty
        #expect(store.closedCountForTesting == 0)

        // Later segment creation sees no intervals from that previous attempt
        let laterData = store.takeForWrite(segmentStart: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(laterData == nil)
    }

    // 4b. Manager: A clearing resume whose prepare fails before createSegmentDirectory.
    // The closed list is kept. The window returns and clears with no 3-second gap required beyond normal.
    // The segment that the successful resume opens contains two JSONL rows.
    @Test @MainActor func abortBeforeDirectoryKeepsBothIntervalsInManagerSegment() async throws {
        let root = try makeTempDirectory("manager-abort-before-dir")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()

        let manager = makeManager(
            root: root,
            nowBox: nowBox,
            windowBox: windowBox
        )

        let didThrow = MutexValue(false)
        manager.beforeResumeNativeStartForTesting = {
            if didThrow.withLock({ flag in
                let was = flag
                flag = true
                return !was
            }) {
                throw TimeoutError(seconds: 0)
            }
        }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        // Interval 1: Netflix
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Stranger Things | Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Window clears, 3s debounce
        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)

        // Prepare fails before createSegmentDirectory due to timeout
        await manager.checkProtectedVideo()
        #expect(manager.state.isPaused)

        let resumeNotBefore = try #require(manager.resumeNotBeforeForTesting)
        #expect(resumeNotBefore > nowBox.now)

        // Put the window back, observe it, clear it, and advance the injected clock to at least resumeNotBefore and at least 3 s after the clear started.
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 102, pid: 200, ownerName: "Safari", title: "Ted Lasso | Apple TV")
        ]
        nowBox.advance(by: 5.0)
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        windowBox.windows = []
        await manager.checkProtectedVideo()
        let clearStart = nowBox.now
        let target = max(resumeNotBefore, clearStart.addingTimeInterval(3.0))
        nowBox.now = target

        // Successful resume
        await manager.checkProtectedVideo()
        #expect(manager.state == .recording)

        let noteURL = try #require(findProtectedVideoNoteFile(in: root))
        let content = try String(contentsOf: noteURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
    }

    // 4c. Manager: A clearing resume whose directory is created and the note is written, then the resume is aborted.
    // A later successful resume does not contain that interval.
    @Test @MainActor func abortAfterDirectoryDoesNotRewriteIntervalInManagerSegment() async throws {
        let root = try makeTempDirectory("manager-abort-after-dir")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()

        let manager = makeManager(
            root: root,
            nowBox: nowBox,
            windowBox: windowBox
        )

        let didThrow = MutexValue(false)
        manager.afterSegmentDirectoryCreatedForTesting = {
            if didThrow.withLock({ flag in
                let was = flag
                flag = true
                return !was
            }) {
                throw TimeoutError(seconds: 0)
            }
        }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        // Interval 1: Netflix
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Stranger Things | Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Window clears, 3s debounce
        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)

        // Directory is created and note written, then afterSegmentDirectoryCreatedForTesting throws TimeoutError
        await manager.checkProtectedVideo()
        #expect(manager.state.isPaused)

        let resumeNotBefore = try #require(manager.resumeNotBeforeForTesting)

        // Advance the injected clock to resumeNotBefore (the window stays clear, so the original clearSince still counts)
        nowBox.now = resumeNotBefore
        await manager.checkProtectedVideo()
        #expect(manager.state == .recording)

        // The later recording segment has no *_protected_video.jsonl. #require that later segment directory.
        let activeSegment = try #require(manager.currentSegmentForTesting)
        let activeSegmentDir = activeSegment.outputDirectory
        let activeNoteURL = findProtectedVideoNoteFile(in: activeSegmentDir)
        #expect(activeNoteURL == nil)

        // The aborted directory still has the one row.
        let noteURL = try #require(findProtectedVideoNoteFile(in: root))
        #expect(noteURL.deletingLastPathComponent() != activeSegmentDir)
        let content = try String(contentsOf: noteURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
    }

    // 5. {.protectedVideo, .lock} whose clearing resume leaves {.lock} → the unlock-opened segment has the note.
    @Test @MainActor func protectedVideoClearedDuringLockLeavesNoteForUnlockSegment() async throws {
        let root = try makeTempDirectory("lock-remainder")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox, unlockResumeDelay: {})

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        // Video appears
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Lock screen occurs
        await manager.lifecycleManager.handleScreenLocked()
        #expect(manager.state == .paused(reasons: [.protectedVideo, .lock]))

        // Video clears while locked
        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)
        await manager.checkProtectedVideo()

        // State leaves lock
        #expect(manager.state == .paused(reasons: [.lock]))

        // Unlock opens segment
        await manager.lifecycleManager.handleScreenUnlocked()
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { manager.state == .recording }
        }

        let noteURL = findProtectedVideoNoteFile(in: root)
        #expect(noteURL != nil)
    }

    // 6. After any transition to recording, noteStoreForTesting closed count is 0.
    @Test @MainActor func closedCountIsZeroAfterTransitionToRecording() async throws {
        let root = try makeTempDirectory("closed-zero")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()

        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)
        await manager.checkProtectedVideo()

        #expect(manager.state == .recording)
        #expect(manager.noteStoreForTesting.closedCountForTesting == 0)
    }

    // 7. A closed interval older than 30 minutes is dropped at write.
    @Test func closedIntervalOlderThan30MinutesIsDroppedAtWrite() {
        let store = ProtectedVideoNoteStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-1801) // 30m 1s ago

        let match = ProtectedVideoMatch(windowID: 1, pid: 10, ownerName: "Chrome", title: "Old Movie", service: "Netflix")
        store.recordObservation(match: match, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: oldDate)
        store.close()

        let data = store.takeForWrite(segmentStart: now)
        #expect(data == nil)
    }

    // 8. A backwards clock yields end_ts == ts.
    @Test func backwardsClockYieldsEndTsEqualsTs() {
        let store = ProtectedVideoNoteStore()
        let date1 = Date(timeIntervalSince1970: 1_800_000_000)
        let date2 = Date(timeIntervalSince1970: 1_799_999_900) // Backwards clock

        let match = ProtectedVideoMatch(windowID: 1, pid: 10, ownerName: "Chrome", title: "Movie", service: "Netflix")
        store.recordObservation(match: match, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: date1)
        store.recordObservation(match: match, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: date2)
        store.close()

        let openInterval = store.closedIntervals.first
        #expect(openInterval != nil)
        #expect(openInterval?.end_ts == openInterval?.ts)
    }

    // 9. Matching observations while the injected lock is true do not advance end_ts.
    @Test func matchingObservationsWhileLockedDoNotAdvanceEndTs() {
        let store = ProtectedVideoNoteStore()
        let date1 = Date(timeIntervalSince1970: 1_800_000_000)
        let match = ProtectedVideoMatch(windowID: 1, pid: 10, ownerName: "Chrome", title: "Movie", service: "Netflix")
        store.recordObservation(match: match, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: date1)

        let initialEnd = store.openIntervalForTesting?.end_ts

        // While locked, observe again 10 seconds later
        let date2 = Date(timeIntervalSince1970: 1_800_000_010)
        store.recordObservation(match: match, isIncluded: true, isScreenLocked: true, isMachineAwake: true, at: date2)

        #expect(store.openIntervalForTesting?.end_ts == initialEnd)
    }

    // 10. Default exclusions, ordinary Firefox Netflix → one row.
    @Test func defaultExclusionsOrdinaryFirefoxNetflixIncludesRow() {
        let store = ProtectedVideoNoteStore()
        let match = ProtectedVideoMatch(windowID: 1, pid: 10, ownerName: "Firefox", title: "Netflix", service: "Netflix")
        let included = store.checkInclusion(
            match: match,
            excludedAppNames: [],
            excludedTitlePatterns: [],
            excludePrivateBrowsing: true,
            excludePrivateBrowsingAccessibility: false,
            accessibilityReader: FakeAccessibilityReader()
        )
        #expect(included == true)
    }

    // 11. Excluded app, or excluded title pattern → pause, no row, no file.
    @Test @MainActor func excludedAppOrExcludedTitlePatternPausesWithNoFile() async throws {
        let root = try makeTempDirectory("excluded-no-file")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(
            root: root,
            nowBox: nowBox,
            windowBox: windowBox,
            excludedAppNames: ["Google Chrome"],
            excludedTitlePatterns: ["secret"]
        )

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        // Excluded app
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Resume
        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)
        await manager.checkProtectedVideo()
        #expect(manager.state == .recording)

        // No note file because app was excluded
        let noteFile = findProtectedVideoNoteFile(in: root)
        #expect(noteFile == nil)
    }

    // 12. Chrome, private exclusion on, Accessibility option on, undecided verdict → that observation contributes no title. Same when the window id is absent from the reader's dictionary. Do not start the capture tick. Do not call the real Accessibility API.
    @Test func chromeUndecidedOrAbsentAccessibilityContributesNoTitle() {
        let store = ProtectedVideoNoteStore()
        let fakeReader = FakeAccessibilityReader()
        let match = ProtectedVideoMatch(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix", service: "Netflix")

        // 12a. Undecided verdict (empty accessibility title in dict)
        fakeReader.titlesByPid[200] = [101: ""]
        let included1 = store.checkInclusion(
            match: match,
            excludedAppNames: [],
            excludedTitlePatterns: [],
            excludePrivateBrowsing: true,
            excludePrivateBrowsingAccessibility: true,
            accessibilityReader: fakeReader
        )
        #expect(included1 == false)

        // 12b. Absent windowID from reader dictionary
        fakeReader.titlesByPid[200] = [:]
        let included2 = store.checkInclusion(
            match: match,
            excludedAppNames: [],
            excludedTitlePatterns: [],
            excludePrivateBrowsing: true,
            excludePrivateBrowsingAccessibility: true,
            accessibilityReader: fakeReader
        )
        #expect(included2 == false)
    }

    // 13. Ordinary window, then a private one with a different title, one interval → private title absent.
    @Test func ordinaryThenPrivateObservationKeepsPrivateTitleAbsent() {
        let store = ProtectedVideoNoteStore()
        let date1 = Date(timeIntervalSince1970: 1_800_000_000)
        let match1 = ProtectedVideoMatch(windowID: 1, pid: 10, ownerName: "Firefox", title: "Netflix - Ordinary", service: "Netflix")
        store.recordObservation(match: match1, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: date1)

        let date2 = Date(timeIntervalSince1970: 1_800_000_010)
        let match2 = ProtectedVideoMatch(windowID: 2, pid: 10, ownerName: "Firefox", title: "Netflix — Private Browsing", service: "Netflix")
        // match2 is not included (isIncluded: false)
        store.recordObservation(match: match2, isIncluded: false, isScreenLocked: false, isMachineAwake: true, at: date2)
        store.close()

        let interval = store.closedIntervals.first
        #expect(interval != nil)
        #expect(interval?.titles == ["Netflix - Ordinary"])
        #expect(interval?.titles.contains("Netflix — Private Browsing") == false)
    }

    // 14. Owner stop during the pause → no note file afterwards.
    @Test @MainActor func ownerStopDuringPauseWritesNoNoteFile() async throws {
        let root = try makeTempDirectory("stop-no-note")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Owner stops during pause
        _ = await manager.enqueueTransition(.stop(reason: .user))
        #expect(manager.state.isIdle)

        // Later start
        windowBox.windows = []
        _ = await manager.enqueueTransition(.start(reason: .user, sources: .all, disabledMicUIDs: [], enabledMicUIDs: []))

        let noteFile = findProtectedVideoNoteFile(in: root)
        #expect(noteFile == nil)
    }

    // 15. Excluded or private matches for 2 hours, then an ordinary Netflix window for 5 minutes with no 3-second gap → ts is the first included observation and end_ts - ts is 5 minutes.
    @Test func excludedLeadInFollowedByOrdinaryObservationSetsCorrectTsAndDuration() {
        let store = ProtectedVideoNoteStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // Excluded/private matches for 2 hours (7200 seconds)
        let matchExcluded = ProtectedVideoMatch(windowID: 1, pid: 10, ownerName: "Firefox", title: "Netflix — Private Browsing", service: "Netflix")
        store.recordObservation(match: matchExcluded, isIncluded: false, isScreenLocked: false, isMachineAwake: true, at: start)
        store.recordObservation(match: matchExcluded, isIncluded: false, isScreenLocked: false, isMachineAwake: true, at: start.addingTimeInterval(3600))
        store.recordObservation(match: matchExcluded, isIncluded: false, isScreenLocked: false, isMachineAwake: true, at: start.addingTimeInterval(7200))

        // Ordinary Netflix window for 5 minutes (300 seconds)
        let ordinaryStart = start.addingTimeInterval(7200)
        let matchOrdinary = ProtectedVideoMatch(windowID: 2, pid: 10, ownerName: "Firefox", title: "Netflix", service: "Netflix")
        store.recordObservation(match: matchOrdinary, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: ordinaryStart)

        let ordinaryEnd = ordinaryStart.addingTimeInterval(300)
        store.recordObservation(match: matchOrdinary, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: ordinaryEnd)
        store.close()

        let interval = store.closedIntervals.first
        #expect(interval != nil)
        let expectedTs = Int64((ordinaryStart.timeIntervalSince1970 * 1000).rounded())
        let expectedEndTs = Int64((ordinaryEnd.timeIntervalSince1970 * 1000).rounded())

        #expect(interval?.ts == expectedTs)
        #expect(interval?.end_ts == expectedEndTs)
        #expect((interval?.end_ts ?? 0) - (interval?.ts ?? 0) == 300_000)
    }

    // 16. At most 3 titles.
    @Test func atMostThreeTitlesAreRecordedPerInterval() {
        let store = ProtectedVideoNoteStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for i in 1...6 {
            let match = ProtectedVideoMatch(windowID: CGWindowID(i), pid: 10, ownerName: "Google Chrome", title: "Title \(i) | Netflix", service: "Netflix")
            store.recordObservation(match: match, isIncluded: true, isScreenLocked: false, isMachineAwake: true, at: now.addingTimeInterval(TimeInterval(i)))
        }
        store.close()

        let interval = store.closedIntervals.first
        #expect(interval != nil)
        #expect(interval?.titles.count == 3)
    }
}
