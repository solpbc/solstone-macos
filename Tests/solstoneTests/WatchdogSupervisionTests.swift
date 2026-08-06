// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import Testing
@testable import SolstoneCore
@testable import solstone_watchdog

@Suite("Watchdog supervision", .serialized)
@MainActor
struct WatchdogSupervisionTests {
    @Test func exitReasonLiteralsResolveToTheirClasses() {
        #expect(ExitReason(markerString: "ordinary-quit")?.watchdogExitClass == .ownerIntent)
        #expect(ExitReason(markerString: "external-quit")?.watchdogExitClass == .ownerIntent)
        #expect(ExitReason(markerString: "settings-restart")?.watchdogExitClass == .selfRelaunch(bound: .seconds(120)))
        #expect(ExitReason(markerString: "sparkle-update")?.watchdogExitClass == .selfRelaunch(bound: .seconds(300)))
        #expect(ExitReason(markerString: "placement-repair")?.watchdogExitClass == .selfRelaunch(bound: .seconds(120)))
        #expect(ExitReason(markerString: "updater-install")?.watchdogExitClass == .selfRelaunch(bound: .seconds(300)))
    }

    @Test func watchdogSupervisionPolicyInvariantsHold() {
        #expect(WatchdogSupervisionPolicy.stabilityWindow + WatchdogSupervisionPolicy.firstBackoff >= WatchdogSupervisionPolicy.backoffCeiling)
        #expect(WatchdogSupervisionPolicy.inFlightTimeout < WatchdogSupervisionPolicy.backoffCeiling)
    }

    @Test func ordinaryQuitSuppressesIndefinitelyAcrossFakeTime() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "ordinary-quit", pid: 41)
        harness.setCandidates([])

        harness.tick()
        harness.tick(advance: .milliseconds(1_500))
        harness.tick(advance: .seconds(36_000))

        #expect(harness.launchCount == 0)
        #expect(harness.transitions.contains { $0.destination == .suppressed(until: nil) })
    }

    @Test func boundedExitReasonsSuppressUntilTheirDeadline() throws {
        let cases: [(String, Duration)] = [
            ("settings-restart", .seconds(120)),
            ("placement-repair", .seconds(120)),
            ("sparkle-update", .seconds(300)),
            ("updater-install", .seconds(300)),
            ("unknown", .seconds(300))
        ]
        for (reason, bound) in cases {
            let harness = try WatchdogHarness(startWithOwner: true)
            defer { harness.removeDirectory() }
            harness.writeMarker(reason: reason, pid: 41)
            harness.setCandidates([])
            harness.tick()
            harness.tick(advance: .milliseconds(1_500))
            harness.tick(advance: bound - .milliseconds(1))
            #expect(harness.launchCount == 0, "\(reason) launched early")
            harness.tick(advance: .milliseconds(1))
            #expect(harness.launchCount == 1, "\(reason) did not launch at its deadline")
        }
    }

    @Test func markerSurvivesFirstMissAndSuppressesOnSecond() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "ordinary-quit", pid: 41)
        harness.setCandidates([])

        harness.tick()
        #expect(FileManager.default.fileExists(atPath: harness.markerURL.path))
        harness.tick(advance: .milliseconds(1_500))

        #expect(!FileManager.default.fileExists(atPath: harness.markerURL.path))
        #expect(harness.launchCount == 0)
    }

    @Test func mismatchedMarkerIsInvalidatedThenOwnerRetries() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "ordinary-quit", pid: 99)
        harness.setCandidates([])

        harness.tick()
        harness.tick(advance: .milliseconds(1_500))
        harness.tick(advance: .seconds(2))

        #expect(harness.launchCount == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.markerURL.path))
    }

    @Test func foreignCopyDoesNotPreventTwoReadOwnerExitConfirmation() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "ordinary-quit", pid: 41)
        harness.setCandidates([harness.foreignCandidate])

        harness.tick()
        #expect(FileManager.default.fileExists(atPath: harness.markerURL.path))
        harness.tick(advance: .milliseconds(1_500))

        #expect(harness.launchCount == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.markerURL.path))
        #expect(harness.records.count == 1)
    }

    @Test func neverCompletingAttemptWaitsUntilTimeoutBeforeSecondInvocation() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }

        #expect(harness.launchCount == 1)
        harness.tick(advance: .seconds(59))
        #expect(harness.launchCount == 1)
        harness.tick(advance: .seconds(1))
        #expect(harness.launchCount == 1)
        harness.tick(advance: .seconds(2))
        #expect(harness.launchCount == 2)
    }

    @Test func supervisionStateChangesEmitExactlyOneStructuredEvent() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        let initialCount = harness.transitions.count
        harness.setCandidates([])
        harness.tick()
        #expect(harness.transitions.count == initialCount)
        harness.tick(advance: .milliseconds(1_500))
        #expect(harness.transitions.count == initialCount + 1)
        #expect(harness.transitions.last?.cause == .unstableOwnerExit)
    }

    @Test func unstableOwnerRunsUseGrowingBackoff() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }
        let delays: [Duration] = [.seconds(2), .seconds(6), .seconds(18)]
        for (index, delay) in delays.enumerated() {
            harness.completeLatestLaunchWithApp()
            harness.setCandidates([harness.ownerCandidate])
            harness.tick()
            harness.setCandidates([])
            harness.tick(advance: .seconds(3))
            harness.tick(advance: .milliseconds(1_500))
            let retry = try #require(harness.transitions.last?.destination)
            #expect(retry == .retrying(failureCount: index + 1, nextAttemptAt: harness.now + delay))
            harness.tick(advance: delay)
        }
    }

    @Test func ownerPathAppearanceLeavesSuppressionButForeignCopyDoesNot() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "ordinary-quit", pid: 41)
        harness.setCandidates([]); harness.tick(); harness.tick(advance: .milliseconds(1_500))
        harness.setCandidates([harness.foreignCandidate]); harness.tick()
        #expect(harness.launchCount == 0)
        harness.setCandidates([harness.ownerCandidate]); harness.tick()
        #expect(harness.transitions.last?.destination == .supervising(pid: 41, stableSince: harness.now, consecutiveMisses: 0, failureCount: 0))
        #expect(harness.launchCount == 0)
    }

    @Test func expiredSuppressionAttemptsImmediatelyWithZeroFailures() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "settings-restart", pid: 41)
        harness.setCandidates([]); harness.tick(); harness.tick(advance: .milliseconds(1_500))
        harness.tick(advance: .seconds(120))
        #expect(harness.launchCount == 1)
        #expect(harness.transitions.contains { $0.destination == .retrying(failureCount: 0, nextAttemptAt: harness.now) })
    }

    @Test func markerSurvivesUntilLaterConfirmedOwnerExit() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "ordinary-quit", pid: 41)
        harness.tick(advance: .seconds(10))
        #expect(FileManager.default.fileExists(atPath: harness.markerURL.path))
        harness.setCandidates([]); harness.tick(); harness.tick(advance: .milliseconds(1_500))
        #expect(harness.transitions.last?.destination == .suppressed(until: nil))
    }

    @Test func ownerPIDChangePreservesMarker() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "ordinary-quit", pid: 41)
        harness.setCandidates([harness.ownerCandidate(pid: 42)]); harness.tick()
        #expect(FileManager.default.fileExists(atPath: harness.markerURL.path))
        #expect(harness.launchCount == 0)
    }

    @Test func undecodableMarkerIsInvalidatedThenOwnerRetries() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        try FileManager.default.createDirectory(at: harness.markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: harness.markerURL)
        harness.setCandidates([]); harness.tick(); harness.tick(advance: .milliseconds(1_500)); harness.tick(advance: .seconds(2))
        #expect(harness.launchCount == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.markerURL.path))
    }

    @Test func startupWithoutOwnerDoesNotConsumeOrdinaryQuitMarker() throws {
        let harness = try WatchdogHarness(startWithOwner: false, initialMarker: ("ordinary-quit", 41))
        defer { harness.removeDirectory() }
        #expect(harness.launchCount == 1)
        #expect(FileManager.default.fileExists(atPath: harness.markerURL.path))
    }

    @Test func foreignCopyCyclesDoNotBypassRetryDeadline() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }
        for _ in 0..<3 {
            harness.setCandidates([harness.foreignCandidate]); harness.tick(advance: .seconds(10))
            harness.setCandidates([]); harness.tick()
        }
        #expect(harness.launchCount == 1)
    }

    @Test func stableOwnerRunResetsNextFailureToFirstBackoff() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }
        harness.completeLatestLaunchWithApp(); harness.setCandidates([harness.ownerCandidate]); harness.tick()
        harness.tick(advance: .seconds(120))
        harness.setCandidates([]); harness.tick(); harness.tick(advance: .milliseconds(1_500))
        #expect(harness.launchCount == 2)
        harness.completeLatestLaunchWithApp(); harness.setCandidates([harness.ownerCandidate]); harness.tick()
        harness.setCandidates([]); harness.tick(advance: .seconds(3)); harness.tick(advance: .milliseconds(1_500))
        #expect(harness.transitions.last?.destination == .retrying(failureCount: 1, nextAttemptAt: harness.now + .seconds(2)))
    }

    @Test func retryingContinuesAtBackoffCeilingWithoutGivingUp() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }
        for _ in 0..<50 {
            harness.completeLatestLaunchEmpty()
            harness.tick(advance: .seconds(120))
        }
        harness.completeLatestLaunchEmpty()
        #expect(harness.transitions.last?.destination == .retrying(failureCount: 51, nextAttemptAt: harness.now + .seconds(120)))
        harness.tick(advance: .seconds(120))
        #expect(harness.launchCount == 52)
    }

    @Test func activeAttemptTimeoutIncrementsFailureCount() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }
        harness.tick(advance: .seconds(60))
        #expect(harness.transitions.last?.cause == .attemptTimedOut)
        #expect(harness.transitions.last?.destination == .retrying(failureCount: 1, nextAttemptAt: harness.now + .seconds(2)))
    }

    @Test func supersededAndEmptyLaunchCompletionsSettleCorrectly() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }
        harness.setCandidates([harness.ownerCandidate]); harness.tick()
        let before = harness.transitions
        harness.completeLatestLaunchEmpty()
        #expect(harness.transitions == before)
        harness.setCandidates([]); harness.tick(); harness.tick(advance: .milliseconds(1_500))
        harness.tick(advance: .seconds(2))
        harness.completeLatestLaunchEmpty()
        #expect(harness.transitions.last?.cause == .attemptFailed)
    }

    @Test func pollAfterMonotonicGapIssuesOverdueAttemptImmediately() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }
        harness.tick(advance: .seconds(62))
        #expect(harness.launchCount == 1)
        harness.tick(advance: .seconds(2))
        #expect(harness.launchCount == 2)
    }

    @Test func wallClockChangeDoesNotMoveMonotonicRetryDeadline() throws {
        let harness = try WatchdogHarness(startWithOwner: false)
        defer { harness.removeDirectory() }
        harness.tick(advance: .seconds(60)); harness.moveWallClock(by: -10_000)
        harness.tick(advance: .seconds(2))
        #expect(harness.launchCount == 2)
    }

    @Test func unmarkedOwnerExitRelaunchesAndReturnsToSupervising() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.tick(advance: .seconds(120)); harness.setCandidates([]); harness.tick(); harness.tick(advance: .milliseconds(1_500))
        #expect(harness.launchCount == 1)
        harness.completeLatestLaunchWithApp(); harness.setCandidates([harness.ownerCandidate]); harness.tick()
        #expect(harness.transitions.last?.destination == .supervising(pid: 41, stableSince: harness.now, consecutiveMisses: 0, failureCount: 0))
    }

    @Test func ownerPIDChangeAdoptsWithoutLaunchAcrossExitClasses() throws {
        for reason in ["ordinary-quit", "settings-restart", "sparkle-update"] {
            let harness = try WatchdogHarness(startWithOwner: true)
            defer { harness.removeDirectory() }
            harness.writeMarker(reason: reason, pid: 41)
            harness.setCandidates([harness.ownerCandidate(pid: 42)]); harness.tick()
            #expect(harness.launchCount == 0)
            #expect(harness.transitions.last?.cause == .ownerPIDChanged)
        }
    }

    @Test func supervisionTransitionsDoNotWriteStateRecords() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.setCandidates([]); harness.tick(); harness.tick(advance: .milliseconds(1_500)); harness.tick(advance: .seconds(2))
        #expect(harness.records.isEmpty)
    }

    @Test func ownerMarkerAndForeignCopyCompositionDoesNotLaunch() throws {
        let harness = try WatchdogHarness(startWithOwner: true)
        defer { harness.removeDirectory() }
        harness.writeMarker(reason: "ordinary-quit", pid: 41)
        harness.setCandidates([harness.foreignCandidate]); harness.tick(); harness.tick(advance: .milliseconds(1_500))
        harness.setCandidates([]); harness.tick(advance: .seconds(10))
        #expect(harness.launchCount == 0)
    }
}

@MainActor
private final class WatchdogHarness {
    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [@Sendable (NSRunningApplication?, Error?) -> Void] = []

        func append(_ value: @escaping @Sendable (NSRunningApplication?, Error?) -> Void) {
            lock.withLock { values.append(value) }
        }

        func completeLatest(with app: NSRunningApplication?, error: Error? = nil) {
            lock.withLock { values.last }?(app, error)
        }
    }
    private final class ManualClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Duration = .zero

        func now() -> Duration { lock.withLock { value } }
        func sleep(for duration: Duration) async {}
        func advance(by duration: Duration) { lock.withLock { value += duration } }
    }

    private let root: URL
    private let app: (bundleURL: URL, executableURL: URL)
    private let clock: ManualClock
    private let candidates: LockedValue<[WatchdogRunningCandidate]>
    private let launches: LockedArray<Bool>
    private let stateRecords: LockedArray<WatchdogStateRecord>
    private let transitionEvents: LockedArray<WatchdogSupervisionTransition>
    private let poll: LockedValue<@MainActor @Sendable () -> Void>
    private let wallNow: LockedValue<Date>
    private let completions: CompletionBox
    private let coordinator: WatchdogCoordinator

    init(startWithOwner: Bool, initialMarker: (reason: String, pid: Int32)? = nil) throws {
        root = try Self.makeDirectory()
        app = try Self.makeApp(at: root, named: "observer.app")
        let manualClock = ManualClock()
        let candidateStore = LockedValue<[WatchdogRunningCandidate]>()
        let launchStore = LockedArray<Bool>([])
        let recordStore = LockedArray<WatchdogStateRecord>([])
        let eventStore = LockedArray<WatchdogSupervisionTransition>([])
        let pollStore = LockedValue<@MainActor @Sendable () -> Void>()
        let wallStore = LockedValue<Date>()
        let completionStore = CompletionBox()
        wallStore.set(Date(timeIntervalSinceReferenceDate: 1_000))
        clock = manualClock
        candidates = candidateStore
        launches = launchStore
        stateRecords = recordStore
        transitionEvents = eventStore
        poll = pollStore
        wallNow = wallStore
        completions = completionStore
        let owner = WatchdogRunningCandidate(
            bundleIdentifier: "app.solstone.observer",
            processIdentifier: 41,
            bundleURL: app.bundleURL
        )
        candidateStore.set(startWithOwner ? [owner] : [])
        let executableURL = app.executableURL
        let rootURL = root
        if let initialMarker {
            ExpectedExitMarker.markExpectedExit(
                reason: initialMarker.reason,
                now: wallStore.current ?? Date(timeIntervalSinceReferenceDate: 1_000),
                pid: initialMarker.pid,
                at: rootURL.appendingPathComponent("markers/Solstone/expected-exit.json")
            )
        }
        coordinator = WatchdogCoordinator(dependencies: WatchdogCoordinator.Dependencies(
            writerExecutableURL: { executableURL },
            cachesURL: { rootURL.appendingPathComponent("Caches", isDirectory: true) },
            temporaryDirectoryURL: { rootURL.appendingPathComponent("Temporary", isDirectory: true) },
            volumeIsLocal: { _ in true },
            runningCandidates: { candidateStore.current ?? [] },
            openApplication: { _, completion in
                launchStore.append(true)
                completionStore.append(completion)
            },
            writeStateRecord: { recordStore.append($0) },
            logBootstrapFault: { _ in },
            terminator: { _ in },
            now: { wallStore.current ?? Date(timeIntervalSinceReferenceDate: 1_000) },
            markerURL: { discriminator in rootURL.appendingPathComponent("markers/\(discriminator)/expected-exit.json") },
            clock: manualClock,
            recordSupervisionTransition: { eventStore.append($0) },
            schedulePollTimer: { callback in
                pollStore.set(callback)
                return Timer(timeInterval: 1, repeats: false) { _ in }
            }
        ))
        #expect(coordinator.start() == .polling)
    }

    var markerURL: URL { root.appendingPathComponent("markers/Solstone/expected-exit.json") }
    var ownerCandidate: WatchdogRunningCandidate { ownerCandidate(pid: 41) }
    func ownerCandidate(pid: Int32) -> WatchdogRunningCandidate {
        WatchdogRunningCandidate(bundleIdentifier: "app.solstone.observer", processIdentifier: pid, bundleURL: app.bundleURL)
    }
    var now: Duration { clock.now() }
    var foreignCandidate: WatchdogRunningCandidate {
        WatchdogRunningCandidate(
            bundleIdentifier: "app.solstone.observer",
            processIdentifier: 99,
            bundleURL: root.appendingPathComponent("copy.app", isDirectory: true)
        )
    }
    var launchCount: Int { launches.all.count }
    var records: [WatchdogStateRecord] { stateRecords.all }
    var transitions: [WatchdogSupervisionTransition] { transitionEvents.all }

    func setCandidates(_ values: [WatchdogRunningCandidate]) { candidates.set(values) }
    func completeLatestLaunchWithApp() { completions.completeLatest(with: .current) }
    func completeLatestLaunchEmpty() { completions.completeLatest(with: nil) }
    func moveWallClock(by seconds: TimeInterval) {
        wallNow.set((wallNow.current ?? Date(timeIntervalSinceReferenceDate: 1_000)).addingTimeInterval(seconds))
    }
    func writeMarker(reason: String, pid: Int32) {
        ExpectedExitMarker.markExpectedExit(
            reason: reason,
            now: wallNow.current ?? Date(timeIntervalSinceReferenceDate: 1_000),
            pid: pid,
            at: markerURL
        )
    }
    func tick(advance: Duration = .zero) {
        clock.advance(by: advance)
        let currentWallNow = wallNow.current ?? Date(timeIntervalSinceReferenceDate: 1_000)
        wallNow.set(currentWallNow + TimeInterval(advance.components.seconds) + Double(advance.components.attoseconds) / 1e18)
        poll.current?()
    }
    func removeDirectory() { try? FileManager.default.removeItem(at: root) }

    private static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-supervision-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeApp(at root: URL, named name: String) throws -> (bundleURL: URL, executableURL: URL) {
        let bundleURL = root.appendingPathComponent(name, isDirectory: true)
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/solstone-watchdog")
        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": "solstone-watchdog", "CFBundleIdentifier": "app.solstone.observer"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        return (bundleURL, executableURL)
    }
}
