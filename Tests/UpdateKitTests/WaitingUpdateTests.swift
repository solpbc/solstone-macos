// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Sparkle
import Testing
@testable import UpdateKit

/// An update waiting for the app to restart: Sparkle's scheduler keeps running, a newer
/// release replaces the waiting one, and the owner is asked to restart after the threshold.
@Suite("Waiting update", .serialized)
@MainActor
struct WaitingUpdateTests {
    private let feedURL = "https://updates.solstone.app/journal-macos/appcast.xml"
    private let publicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
    private let isolatedDefaults = IsolatedUserDefaults()

    // MARK: - Reading the feed

    @Test func newestEligibleBuildReadsTheCapturedFeed() throws {
        let feed = try capturedFeed()

        #expect(UpdateFeedProbe.newestEligibleBuild(inAppcast: feed, systemVersion: "27.2.0") == "127")
        // Every item asks for macOS 15 or later.
        #expect(UpdateFeedProbe.newestEligibleBuild(inAppcast: feed, systemVersion: "14.6.0") == nil)
    }

    @Test func feedReadStaysOnTheUpdateOrigin() throws {
        let origin = UpdateFeedProbe.approvedOrigin(feedOverride: nil)
        let allowed = try #require(URL(string: "https://updates.solstone.app/journal-macos/appcast.xml"))

        #expect(UpdateFeedProbe.isApproved(allowed, origin: origin))
        for refused in [
            "http://updates.solstone.app/journal-macos/appcast.xml",
            "https://updates.solstone.app.example.com/appcast.xml",
            "https://updates.solstone.app:8443/appcast.xml",
            "https://user@updates.solstone.app/appcast.xml",
            "https://solstone.app/appcast.xml",
        ] {
            #expect(!UpdateFeedProbe.isApproved(try #require(URL(string: refused)), origin: origin), "\(refused)")
        }

        let staging = UpdateFeedProbe.approvedOrigin(feedOverride: "https://staging.updates.solstone.app/feed.xml")
        #expect(UpdateFeedProbe.isApproved(try #require(URL(string: "https://staging.updates.solstone.app/x.dmg")), origin: staging))
        #expect(!UpdateFeedProbe.isApproved(allowed, origin: staging))
    }

    // MARK: - Sparkle's daily resume of a waiting update

    @Test func aNewerReleaseReplacesTheStagedUpdateThroughSparklesOwnCheck() async throws {
        let harness = try makeHarness(feed: try capturedFeed())
        let staged = try appcastItem(version: "2.0.73", build: "125")
        stage(staged, in: harness)

        let choice = LockedValue<Int>()
        harness.userDriver.showUpdateFound(with: staged, state: try state(.installing, userInitiated: false)) {
            choice.set($0.rawValue)
        }
        try await waitUntil(timeout: .seconds(5)) { choice.current != nil }

        #expect(choice.current == SPUUserUpdateChoice.skip.rawValue)
        #expect(harness.controller.reconciledStatus.replacedForBuild == "127")
        #expect(!harness.controller.hasLiveUpdateReply)

        // The one request: the feed address with Sparkle's user agent and nothing else.
        let request = try #require(harness.requests.current?.first)
        #expect(request.url?.absoluteString == feedURL)
        #expect(request.allHTTPHeaderFields == ["User-Agent": harness.spy.userAgentString])
        #expect(request.httpMethod == "GET")

        // Sparkle recorded the cancelled version as skipped, under the key a live run showed it
        // writes (`SUSkippedVersion`); that record is removed before
        // Sparkle's own check runs, so it can't hide a release later.
        isolatedDefaults.defaults.set("125", forKey: "SUSkippedVersion")
        harness.runScheduled()

        #expect(harness.spy.checkForUpdatesInBackgroundCallCount == 1)
        #expect(isolatedDefaults.defaults.object(forKey: "SUSkippedVersion") == nil)

        // Sparkle stages the newest; it is the one waiting now.
        stage(try appcastItem(version: "2.0.75", build: "127"), in: harness)
        #expect(harness.controller.stagedVersion == "2.0.75")
    }

    @Test func theStagedUpdateKeepsWaitingWhenNothingNewerIsOut() async throws {
        let harness = try makeHarness(feed: try capturedFeed())
        let staged = try appcastItem(version: "2.0.75", build: "127")
        stage(staged, in: harness)
        harness.clock.advance(by: 86_400)

        let choice = LockedValue<Int>()
        harness.userDriver.showUpdateFound(with: staged, state: try state(.installing, userInitiated: false)) {
            choice.set($0.rawValue)
        }
        try await waitUntil(timeout: .seconds(5)) { choice.current != nil }

        #expect(choice.current == SPUUserUpdateChoice.dismiss.rawValue)
        #expect(harness.controller.updateIsStaged)
        #expect(harness.controller.reconciledStatus.lastCheck?.checkedAt == harness.clock.now)
        #expect(harness.controller.reconciledStatus.replacedForBuild == nil)
        harness.runScheduled()
        #expect(harness.spy.checkForUpdatesInBackgroundCallCount == 0)
    }

    @Test func aFeedBuildCausesAtMostOneReplacement() async throws {
        let harness = try makeHarness(feed: try capturedFeed())
        let staged = try appcastItem(version: "2.0.73", build: "125")
        stage(staged, in: harness)
        // An earlier replacement for 127 ended with Sparkle staging 125 again.
        var status = harness.controller.reconciledStatus
        status.replacedForBuild = "127"
        isolatedDefaults.defaults.set(try JSONEncoder().encode(status), forKey: "solstone.updates.status")
        let reloaded = try makeHarness(feed: try capturedFeed())

        let choice = LockedValue<Int>()
        reloaded.userDriver.showUpdateFound(with: staged, state: try state(.installing, userInitiated: false)) {
            choice.set($0.rawValue)
        }
        try await waitUntil(timeout: .seconds(5)) { choice.current != nil }

        #expect(choice.current == SPUUserUpdateChoice.dismiss.rawValue)
    }

    @Test func installNowDuringTheFeedReadIsTheOwnersAnswer() async throws {
        let gate = LoaderGate()
        let harness = try makeHarness(feed: try capturedFeed(), gate: gate)
        let staged = try appcastItem(version: "2.0.73", build: "125")
        stage(staged, in: harness)

        let choices = LockedValue<[Int]>()
        choices.set([])
        harness.userDriver.showUpdateFound(with: staged, state: try state(.installing, userInitiated: false)) { choice in
            choices.set((choices.current ?? []) + [choice.rawValue])
        }
        try await waitUntil(timeout: .seconds(5)) { gate.waiting }

        harness.controller.installStagedUpdate()
        try await waitUntil(timeout: .seconds(5)) { choices.current == [SPUUserUpdateChoice.install.rawValue] }
        gate.release()
        try await Task.sleep(for: .milliseconds(200))

        #expect(choices.current == [SPUUserUpdateChoice.install.rawValue])
        #expect(harness.spy.checkForUpdatesInBackgroundCallCount == 0)
    }

    @Test func theOwnersOwnCheckIsNotAnsweredForThem() async throws {
        let harness = try makeHarness(feed: try capturedFeed())
        let staged = try appcastItem(version: "2.0.73", build: "125")
        stage(staged, in: harness)

        var choices: [SPUUserUpdateChoice] = []
        harness.userDriver.showUpdateFound(with: staged, state: try state(.installing, userInitiated: true)) {
            choices.append($0)
        }
        try await Task.sleep(for: .milliseconds(200))

        #expect(choices.isEmpty)
        #expect(harness.controller.hasLiveUpdateReply)
        #expect(harness.requests.current?.isEmpty ?? true)
    }

    @Test func aScheduledUpdateNotYetDownloadedEndsTheSessionWithoutAFeedRead() throws {
        let harness = try makeHarness(feed: try capturedFeed())
        let found = try appcastItem(version: "2.0.75", build: "127")
        harness.delegate.updater?(harness.sparkleUpdater, didFindValidUpdate: found)

        var choices: [SPUUserUpdateChoice] = []
        harness.userDriver.showUpdateFound(with: found, state: try state(.notDownloaded, userInitiated: false)) {
            choices.append($0)
        }

        #expect(choices == [.dismiss])
        #expect(harness.controller.durableUpdateStatus == .available(version: "2.0.75", releaseNotes: nil))
        #expect(harness.requests.current?.isEmpty ?? true)
    }

    @Test func aFailedFeedReadLeavesTheUpdateWaiting() async throws {
        let harness = try makeHarness(feed: nil)
        let staged = try appcastItem(version: "2.0.73", build: "125")
        stage(staged, in: harness)
        let checkedAt = harness.controller.reconciledStatus.lastCheck?.checkedAt
        harness.clock.advance(by: 86_400)

        let choice = LockedValue<Int>()
        harness.userDriver.showUpdateFound(with: staged, state: try state(.installing, userInitiated: false)) {
            choice.set($0.rawValue)
        }
        try await waitUntil(timeout: .seconds(5)) { choice.current != nil }

        #expect(choice.current == SPUUserUpdateChoice.dismiss.rawValue)
        #expect(harness.controller.updateIsStaged)
        #expect(harness.controller.reconciledStatus.lastCheck?.checkedAt == checkedAt)
    }

    @Test func aDownloadedUpdateWaitingForAnAdministratorStartsTheWaitingClock() async throws {
        let harness = try makeHarness(feed: try capturedFeed())
        let downloaded = try appcastItem(version: "2.0.75", build: "127")
        harness.delegate.updater?(harness.sparkleUpdater, didFindValidUpdate: downloaded)

        let choice = LockedValue<Int>()
        harness.userDriver.showUpdateFound(with: downloaded, state: try state(.downloaded, userInitiated: false)) {
            choice.set($0.rawValue)
        }
        try await waitUntil(timeout: .seconds(5)) { choice.current != nil }

        #expect(choice.current == SPUUserUpdateChoice.dismiss.rawValue)
        #expect(harness.controller.reconciledStatus.waitingSince == harness.clock.now)
        #expect(harness.controller.durableUpdateStatus == .available(version: "2.0.75", releaseNotes: nil))
    }

    // MARK: - The restart prompt

    @Test func theOwnerIsAskedOnceTheUpdateHasWaitedThreeDaysEvenAcrossReplacements() async throws {
        let harness = try makeHarness(feed: try capturedFeed())
        let started = harness.clock.now
        stage(try appcastItem(version: "2.0.73", build: "125"), in: harness)
        #expect(harness.controller.reconciledStatus.waitingSince == started)

        // A day later a newer release replaces it; the clock keeps the first date.
        harness.clock.advance(by: 86_400)
        stage(try appcastItem(version: "2.0.75", build: "127"), in: harness)
        #expect(harness.controller.reconciledStatus.waitingSince == started)

        harness.clock.set(started.addingTimeInterval(UpdateController.restartPromptThreshold - 3_600))
        harness.controller.evaluateRestartPrompt()
        #expect(harness.prompts.isEmpty)

        harness.clock.set(started.addingTimeInterval(UpdateController.restartPromptThreshold))
        harness.runScheduled()
        #expect(harness.prompts.map(\.version) == ["2.0.75"])
        #expect(harness.spy.checkForUpdatesCallCount == 0)
    }

    @Test func laterWaitsAnotherThresholdAndRestartNowInstallsTheStagedUpdate() async throws {
        let harness = try makeHarness(feed: try capturedFeed())
        let started = harness.clock.now
        stage(try appcastItem(version: "2.0.75", build: "127"), in: harness)

        harness.clock.set(started.addingTimeInterval(UpdateController.restartPromptThreshold))
        harness.controller.evaluateRestartPrompt()
        try #require(harness.prompts.count == 1)
        harness.prompts[0].respond(false)
        #expect(harness.spy.checkForUpdatesCallCount == 0)

        harness.clock.advance(by: 86_400)
        harness.controller.evaluateRestartPrompt()
        #expect(harness.prompts.count == 1)

        harness.clock.set(started.addingTimeInterval(2 * UpdateController.restartPromptThreshold))
        harness.controller.evaluateRestartPrompt()
        try #require(harness.prompts.count == 2)
        harness.prompts[1].respond(true)

        // Install now resumes Sparkle's session for the staged update; nothing quits by itself.
        #expect(harness.spy.checkForUpdatesCallCount == 1)
    }

    @Test func restartNowWaitsOutABusySparkleSessionInsteadOfDroppingThePress() async throws {
        let harness = try makeHarness(feed: try capturedFeed())
        stage(try appcastItem(version: "2.0.75", build: "127"), in: harness)
        harness.runScheduled()
        harness.spy.sessionInProgress = true

        harness.controller.installWaitingUpdate()
        harness.runScheduled()
        #expect(harness.spy.checkForUpdatesCallCount == 0)

        harness.spy.sessionInProgress = false
        harness.runScheduled()
        #expect(harness.spy.checkForUpdatesCallCount == 1)
    }

    @Test func runningTheNewestClearsTheWaitingClock() throws {
        let harness = try makeHarness(feed: try capturedFeed())
        stage(try appcastItem(version: "2.0.75", build: "127"), in: harness)
        #expect(harness.controller.reconciledStatus.waitingSince != nil)

        harness.delegate.updater?(
            harness.sparkleUpdater,
            didFinishUpdateCycleFor: .updatesInBackground,
            error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        )

        #expect(harness.controller.reconciledStatus.waitingSince == nil)
        #expect(harness.controller.reconciledStatus.restartPromptedAt == nil)
    }

    // MARK: - Harness

    private func stage(_ item: SUAppcastItem, in harness: WaitingHarness) {
        harness.delegate.updater?(harness.sparkleUpdater, didFindValidUpdate: item)
        let handled = harness.delegate.updater?(
            harness.sparkleUpdater,
            willInstallUpdateOnQuit: item,
            immediateInstallationBlock: {}
        )
        #expect(handled == false)
    }

    private func makeHarness(feed: Data?, gate: LoaderGate? = nil) throws -> WaitingHarness {
        try WaitingHarness(feedURL: feedURL, publicKey: publicKey, defaults: isolatedDefaults.defaults, feed: feed, gate: gate)
    }

    private func capturedFeed() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "journal-appcast-261111", withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func appcastItem(version: String, build: String) throws -> SUAppcastItem {
        try #require(SUAppcastItem(dictionary: [
            "title": "journal \(version)",
            "sparkle:version": build,
            "sparkle:shortVersionString": version,
            "enclosure": [
                "url": "https://updates.solstone.app/journal-macos/journal-\(version)-build-\(build).dmg",
                "length": "42",
                "sparkle:version": build,
                "sparkle:shortVersionString": version,
            ],
        ]))
    }

    private func state(_ stage: SPUUserUpdateStage, userInitiated: Bool) throws -> SPUUserUpdateState {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        archiver.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return try #require(SPUUserUpdateState(coder: unarchiver) as SPUUserUpdateState?)
    }
}

@MainActor
private final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_794_000_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }

    func set(_ date: Date) {
        now = date
    }
}

private final class LoaderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    var waiting: Bool { lock.withLock { isWaiting } }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                isWaiting = true
            }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class WaitingHarness {
    struct Prompt {
        let version: String
        let respond: @MainActor (Bool) -> Void
    }

    let spy: SpyUpdater
    let clock: TestClock
    let requests: LockedValue<[URLRequest]>
    var prompts: [Prompt] = []
    private var scheduled: [@MainActor () -> Void] = []
    let controller: UpdateController
    let userDriver: SparkleUserDriver
    let delegate: any SPUUpdaterDelegate
    let sparkleUpdater: SPUUpdater

    init(feedURL: String, publicKey: String, defaults: UserDefaults, feed: Data?, gate: LoaderGate?) throws {
        var capturedUserDriver: SparkleUserDriver?
        var capturedDelegate: (any SPUUpdaterDelegate)?
        let spy = SpyUpdater(automaticallyDownloadsUpdates: true)
        let clock = TestClock()
        let requests = LockedValue<[URLRequest]>()
        requests.set([])
        self.spy = spy
        self.clock = clock
        self.requests = requests
        var promptSink: ((Prompt) -> Void)?
        var scheduleSink: ((@escaping @MainActor () -> Void) -> Void)?

        controller = UpdateController(
            feedURL: feedURL,
            publicKey: publicKey,
            runningVersion: { "2.0.59" },
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            restartPrompt: { version, respond in promptSink?(Prompt(version: version, respond: respond)) },
            defaults: defaults,
            feedLoader: { request in
                requests.set((requests.current ?? []) + [request])
                if let gate { await gate.wait() }
                guard let feed else { throw URLError(.notConnectedToInternet) }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (feed, response)
            },
            now: { clock.now },
            scheduleAfter: { _, work in scheduleSink?(work) }
        ) { userDriver, delegate in
            capturedUserDriver = userDriver
            capturedDelegate = delegate
            return spy
        }
        userDriver = try #require(capturedUserDriver)
        delegate = try #require(capturedDelegate)
        sparkleUpdater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: delegate)
        promptSink = { [weak self] in self?.prompts.append($0) }
        scheduleSink = { [weak self] in self?.scheduled.append($0) }
    }

    /// Runs the delayed work the controller asked for, as if its delay had passed.
    func runScheduled() {
        let work = scheduled
        scheduled = []
        work.forEach { $0() }
    }
}
