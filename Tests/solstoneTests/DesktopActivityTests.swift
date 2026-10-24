// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreGraphics
import Testing
@testable import solstone

@Suite("DesktopActivityTests")
struct DesktopActivityTests {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("activity-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func artifacts(_ root: URL) -> [URL] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix("_desktop_activity.jsonl") }
    }

    private func rows(_ root: URL) throws -> [DesktopActivityRow] {
        try artifacts(root).flatMap { file in
            try Data(contentsOf: file).split(separator: 0x0A).map { try JSONDecoder().decode(DesktopActivityRow.self, from: Data($0)) }
        }.sorted { $0.ts < $1.ts }
    }

    private func suite() throws -> (UserDefaults, String) {
        let name = "desktop-activity-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private static let activityKeys = ["isActivityEnabled", "activityTitlesEnabled", "activityURLsEnabled", "activityContinuesThroughPause"]

    @Test func activityTitlesAndAddressesDefaultOnAndOnlyOwnerChoicesAreSaved() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let original = AppConfig.load(from: defaults)
        #expect(original.isActivityEnabled && original.activityTitlesEnabled && original.activityURLsEnabled)
        #expect(!original.activityContinuesThroughPause && !original.activityAccessibilityEnabled)
        let settings = DesktopActivitySettings(original)
        #expect(settings.enabled && settings.titles && settings.urls && !settings.accessibility)

        // Saving a config nobody changed writes none of these, so a missing key keeps the code default.
        try original.save(to: defaults)
        #expect(Self.activityKeys.allSatisfy { defaults.object(forKey: $0) == nil })

        var config = AppConfig.load(from: defaults)
        config.activityTitlesEnabled = false
        config.activityContinuesThroughPause = true
        try config.save(to: defaults)
        #expect(defaults.object(forKey: "activityTitlesEnabled") as? Bool == false)
        #expect(defaults.object(forKey: "activityContinuesThroughPause") as? Bool == true)
        #expect(defaults.object(forKey: "isActivityEnabled") == nil && defaults.object(forKey: "activityURLsEnabled") == nil)
        let restored = AppConfig.load(from: defaults)
        #expect(!restored.activityTitlesEnabled && restored.activityURLsEnabled)
        #expect(restored.isActivityEnabled && restored.activityContinuesThroughPause)
    }

    @Test func savedActivityValuesFromEarlierBuildsAreDiscardedOnce() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // What an earlier build saved on first run, plus owner settings that must survive.
        for key in ["isActivityEnabled", "activityTitlesEnabled", "activityURLsEnabled"] { defaults.set(false, forKey: key) }
        defaults.set(true, forKey: "activityAccessibilityEnabled")
        defaults.set(false, forKey: "isMicrophoneCaptureEnabled")
        defaults.set(["fixture"], forKey: "excludedTitlePatterns")

        AppConfig.adoptActivityFollowsScreenIfNeeded(defaults)
        var migrated = AppConfig.load(from: defaults)
        #expect(migrated.isActivityEnabled && migrated.activityTitlesEnabled && migrated.activityURLsEnabled)
        #expect(migrated.activityAccessibilityEnabled)
        #expect(!migrated.isMicrophoneCaptureEnabled && migrated.excludedTitlePatterns == ["fixture"])

        // An owner's off after the migration stays off, however often the app starts again.
        migrated.isActivityEnabled = false
        migrated.activityURLsEnabled = false
        try migrated.save(to: defaults)
        AppConfig.adoptActivityFollowsScreenIfNeeded(defaults)
        AppConfig.adoptActivityFollowsScreenIfNeeded(defaults)
        let later = AppConfig.load(from: defaults)
        #expect(!later.isActivityEnabled && !later.activityURLsEnabled && later.activityTitlesEnabled)
    }

    @Test func activityFollowsScreenAndPauseUnlessTurnedOffOrKeptOn() {
        func runs(_ config: AppConfig, paused: Bool = false, stopped: Bool = false) -> Bool {
            config.isActivitySourceOn && !config.activityHeld(paused: paused, stopped: stopped)
        }
        let following = AppConfig()
        #expect(runs(following))
        #expect(!runs(following, paused: true) && !runs(following, stopped: true))
        #expect(!runs(AppConfig(isScreenCaptureEnabled: false)))

        var off = AppConfig(); off.isActivityEnabled = false
        var offKeptOn = off; offKeptOn.activityContinuesThroughPause = true
        for config in [off, offKeptOn] {
            #expect(!runs(config) && !runs(config, paused: true) && !runs(config, stopped: true))
        }

        var keptOn = AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false)
        keptOn.activityContinuesThroughPause = true
        #expect(runs(keptOn) && runs(keptOn, paused: true) && runs(keptOn, stopped: true))
    }

    @Test @MainActor func pauseClosesActivityUnlessItIsKeptOnThroughPause() async throws {
        for keptOn in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let state = State()
            var config = AppConfig()
            if keptOn { config.activityContinuesThroughPause = true }
            let selected = config
            let app = DesktopActivityApp(pid: 42, name: "Fixture", bundleID: "example.fixture")
            let source = DesktopActivitySource(storage: StorageManager(baseDirectory: root.appendingPathComponent("captures")),
                eligibility: { !selected.activityHeld(paused: state.paused, stopped: false) }, locked: { false }, foreground: { app },
                reader: { _, _, _ in DesktopActivityObservation(rows: [DesktopActivityRow(kind: "foreground", method: "nsworkspace", app: "Fixture")]) },
                now: { state.now })
            source.configure(config)
            await source.sample()?.value
            state.now.addTimeInterval(7); state.paused = true
            // What the pause hook does.
            source.invalidate(); await source.sample()?.value
            state.now.addTimeInterval(7)
            await source.sample()?.value
            source.invalidate()
            let result = try rows(root)
            #expect(source.paused != keptOn)
            #expect(result.count == (keptOn ? 2 : 1))
            #expect(result.allSatisfy { $0.end_ts - $0.ts == 7_000 })
        }
    }

    @Test @MainActor func screenOffTurnsActivityOffUnlessKeptOnThroughPause() async throws {
        for keptOn in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let app = DesktopActivityApp(pid: 42, name: "Fixture", bundleID: "example.fixture")
            let source = DesktopActivitySource(storage: StorageManager(baseDirectory: root.appendingPathComponent("captures")),
                eligibility: { true }, locked: { false }, foreground: { app },
                reader: { _, _, _ in DesktopActivityObservation(rows: [DesktopActivityRow(kind: "foreground", method: "nsworkspace", app: "Fixture")]) })
            var config = AppConfig(isScreenCaptureEnabled: false)
            if keptOn { config.activityContinuesThroughPause = true }
            source.configure(config)
            await source.sample()?.value
            source.invalidate()
            #expect(source.enabled == keptOn)
            #expect(artifacts(root).isEmpty != keptOn)
        }
    }

    @Test func addressesRetainOnlyWebOriginAndPath() {
        #expect(desktopActivityURL("https://name:password@example.com:8443/a%20b?q=secret#token") == "https://example.com:8443/a%20b")
        #expect(desktopActivityURL("https://example.com/second") == "https://example.com/second")
        #expect(desktopActivityURL("file:///secret") == nil)
        #expect(desktopActivityURL("unfinished address") == nil)
    }

    private struct NoAccessibility: AccessibilityTitleReading {
        func titles(pid: pid_t) -> [CGWindowID: String] { [:] }
    }

    @Test func noteKeepsUnknownAndWithholdsOnlyConfirmedPrivate() {
        var cache: [ProtectedVideoCacheKey: TitleVerdict] = [:]
        func included(_ app: String, _ title: String) -> Bool {
            protectedVideoObservationIncluded(
                match: ProtectedVideoMatch(windowID: 1, pid: 42, ownerName: app, title: title, service: "Fixture"),
                excludedAppNames: [], excludedTitlePatterns: [], excludePrivateBrowsing: true,
                excludePrivateBrowsingAccessibility: true, accessibilityReader: NoAccessibility(), verdictCache: &cache)
        }
        #expect(included("Google Chrome", "Fixture"))
        #expect(included("Firefox", ""))
        #expect(!included("Firefox", "Fixture — Private Browsing"))
    }

    @Test @MainActor func activityOnlyMenubarReflectsCollectionAndPause() throws {
        var config = AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false)
        config.activityContinuesThroughPause = true
        let state = AppState.forSnapshot(config: config)
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let eligibility = State()
        let source = DesktopActivitySource(storage: StorageManager(baseDirectory: root.appendingPathComponent("captures")),
            eligibility: { eligibility.eligible }, locked: { false }, foreground: { nil })
        state.activitySource = source
        source.configure(config)
        #expect(state.observationRowState == .observing)
        eligibility.eligible = false
        source.invalidate()
        #expect(state.observationRowState == .paused)
    }

    @Test @MainActor func turningOffLastMediaSourceLeavesKeptOnActivityEligible() async throws {
        var config = AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false)
        config.activityContinuesThroughPause = true
        let state = AppState.forSnapshot(config: config)
        state.configSaver = { _ in }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        state.captureManager.seedRecordingForTesting(currentSegment: FakeCaptureSegment(outputDirectory: root), sources: .screen)
        state.isRecording = true
        await state.applySelectedSourcesToRunningSession()
        #expect(!state.capture.isExplicitlyStopped && !state.capture.isUserStopped)
    }

    @Test func checkpointSurvivesRestartAndDoesNotExtendAcrossDowntime() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(baseDirectory: root.appendingPathComponent("captures"))
        let store = DesktopActivityStore(storage: storage)
        let row = DesktopActivityRow(kind: "foreground", method: "nsworkspace", app: "Fixture")
        let start: Int64 = 1_800_000_001_000
        try store.observe([row], at: start)
        try store.observe([row], at: start + 5_000)
        let recovered = DesktopActivityStore(storage: storage)
        try recovered.recover()
        let result = try rows(root)
        #expect(result.count == 1)
        #expect(result.first?.ts == start && result.first?.end_ts == start + 5_000)
        try DesktopActivityStore(storage: storage).recover()
        #expect(artifacts(root).count == 1)
    }

    @Test func intervalsSplitWithoutOverlapAtSegmentBoundary() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopActivityStore(storage: StorageManager(baseDirectory: root.appendingPathComponent("captures")))
        let row = DesktopActivityRow(kind: "activity", method: "quartz", state: "idle")
        let boundary: Int64 = 1_800_000_300_000
        try store.observe([row], at: boundary - 1_000)
        try store.observe([row], at: boundary + 2_000)
        try store.end(at: boundary + 3_000)
        let result = try rows(root)
        #expect(result.count == 2)
        #expect(result[0].ts == boundary - 1_000 && result[0].end_ts == boundary)
        #expect(result[1].ts == boundary && result[1].end_ts == boundary + 3_000)
        #expect(result.allSatisfy { $0.app == nil && $0.title == nil && $0.url == nil })
    }

    @Test func withheldWindowDoesNotStrandEarlierRowsPastCadence() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopActivityStore(storage: StorageManager(baseDirectory: root.appendingPathComponent("captures")))
        let start: Int64 = 1_800_000_001_000
        try store.observe([DesktopActivityRow(kind: "foreground", method: "nsworkspace", app: "Earlier")], at: start)
        try store.observe([], at: start + 4_000)
        #expect(artifacts(root).isEmpty)
        try store.observe([], at: 1_800_000_300_000)
        let result = try rows(root)
        #expect(result.count == 1)
        #expect(result[0].end_ts == start + 4_000)
    }

    @Test func failedCheckpointWriteKeepsLastCommittedObservation() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(baseDirectory: root.appendingPathComponent("captures"))
        let store = DesktopActivityStore(storage: storage)
        let row = DesktopActivityRow(kind: "foreground", method: "nsworkspace", app: "Earlier")
        try store.observe([row], at: 1_800_000_001_000)
        let failing = DesktopActivityStore(storage: storage, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        #expect(throws: (any Error).self) { try failing.recover() }
        try DesktopActivityStore(storage: storage).recover()
        let result = try rows(root)
        #expect(result.count == 1 && result[0].app == "Earlier")
    }

    @Test func uploadProofRequiresCurrentMatchingActivityBytes() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("120000_batch_desktop_activity.jsonl")
        try Data("old".utf8).write(to: file)
        let proof = IngestAcknowledgedFileProof(submitted: file.lastPathComponent, sha256: "old-hash", size: 3)
        #expect(proof.matchesLocalFileForRemoval(file, sha256Calculator: { _ in "old-hash" }))
        try Data("new".utf8).write(to: file)
        #expect(!proof.matchesLocalFileForRemoval(file, sha256Calculator: { _ in "new-hash" }))
        #expect(IngestAcknowledgment.isUploadMediaName(file.lastPathComponent, segment: "120000_1"))
    }

    @MainActor private final class State {
        var eligible = true
        var paused = false
        var locked = false
        var now = Date(timeIntervalSince1970: 1_800_000_001)
    }

    @Test @MainActor func sourceOnlyPauseClosesAtBoundaryAndResumeStartsFresh() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = State()
        let app = DesktopActivityApp(pid: 42, name: "Fixture", bundleID: "example.fixture")
        let source = DesktopActivitySource(storage: StorageManager(baseDirectory: root.appendingPathComponent("captures")),
            eligibility: { state.eligible }, locked: { state.locked }, foreground: { app },
            reader: { _, _, _ in DesktopActivityObservation(rows: [DesktopActivityRow(kind: "foreground", method: "nsworkspace", app: "Fixture")]) },
            now: { state.now })
        var config = AppConfig(); config.isActivityEnabled = true
        source.configure(config)
        await source.sample()?.value
        state.now.addTimeInterval(7); state.eligible = false
        source.invalidate()
        state.now.addTimeInterval(100)
        await source.sample()?.value
        var result = try rows(root)
        #expect(result.count == 1 && result[0].end_ts - result[0].ts == 7_000)
        state.eligible = true
        await source.sample()?.value
        state.now.addTimeInterval(4)
        source.invalidate()
        result = try rows(root)
        #expect(result.count == 2)
        #expect(result[1].ts - result[0].end_ts == 100_000)
        #expect(result[1].end_ts - result[1].ts == 4_000)
    }

    @Test @MainActor func pauseRejectsLateBackgroundResult() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let state = State()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let app = DesktopActivityApp(pid: 42, name: "Fixture", bundleID: "example.fixture")
        let source = DesktopActivitySource(storage: StorageManager(baseDirectory: root.appendingPathComponent("captures")),
            eligibility: { state.eligible }, locked: { false }, foreground: { app },
            reader: { _, _, _ in
                signal.yield(); release.wait()
                return DesktopActivityObservation(rows: [DesktopActivityRow(kind: "foreground", method: "ax", app: "Fixture", title: "late")])
            })
        var config = AppConfig(); config.isActivityEnabled = true
        source.configure(config)
        let task = source.sample()
        for await _ in started { break }
        state.eligible = false; source.invalidate()
        release.signal()
        await task?.value
        #expect(artifacts(root).isEmpty)
    }
}
