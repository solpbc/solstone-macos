// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreFoundation
import Foundation
import Testing
@testable import SolstoneCore
@testable import solstone_watchdog

@Suite("Watchdog", .serialized)
struct WatchdogTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)
    private let pid: Int32 = 42

    @Test func markerRoundTrips() throws {
        let marker = ExpectedExitMarker(pid: pid, timestamp: now, reason: "quit")

        let decoded = try ExpectedExitMarker.decode(try marker.encoded())

        #expect(decoded == marker)
    }

    @Test func validatorSuppressesFreshMatchingPID() {
        let marker = ExpectedExitMarker(pid: pid, timestamp: now, reason: "quit")

        #expect(ExpectedExitMarker.isExpectedExit(marker: marker, terminatedPID: pid, now: now))
    }

    @Test func validatorRejectsStaleMarker() {
        let marker = ExpectedExitMarker(
            pid: pid,
            timestamp: now.addingTimeInterval(-200),
            reason: "quit"
        )

        #expect(!ExpectedExitMarker.isExpectedExit(marker: marker, terminatedPID: pid, now: now))
    }

    @Test func validatorRejectsPIDMismatch() {
        let marker = ExpectedExitMarker(pid: pid, timestamp: now, reason: "quit")

        #expect(!ExpectedExitMarker.isExpectedExit(marker: marker, terminatedPID: pid + 1, now: now))
    }

    @Test func validatorRejectsNilMarker() {
        #expect(!ExpectedExitMarker.isExpectedExit(marker: nil, terminatedPID: pid, now: now))
    }

    @Test func decisionSuppressesExpectedExit() {
        let marker = ExpectedExitMarker(pid: pid, timestamp: now, reason: "quit")

        let decision = relaunchDecision(
            marker: marker,
            terminatedPID: pid,
            now: now,
            recentRelaunches: []
        )

        #expect(decision == .suppress)
    }

    @Test func decisionRelaunchesWithoutMarker() {
        let decision = relaunchDecision(
            marker: nil,
            terminatedPID: pid,
            now: now,
            recentRelaunches: []
        )

        #expect(decision == .relaunch)
    }

    @Test func decisionRelaunchesForStaleOrMismatchedMarker() {
        let stale = ExpectedExitMarker(
            pid: pid,
            timestamp: now.addingTimeInterval(-200),
            reason: "quit"
        )
        let mismatched = ExpectedExitMarker(pid: pid + 1, timestamp: now, reason: "quit")

        #expect(relaunchDecision(marker: stale, terminatedPID: pid, now: now, recentRelaunches: []) == .relaunch)
        #expect(relaunchDecision(marker: mismatched, terminatedPID: pid, now: now, recentRelaunches: []) == .relaunch)
    }

    @Test func decisionSuppressesFreshSettingsRestartMarkerAfterBoundedWait() {
        let marker = ExpectedExitMarker(
            pid: pid,
            timestamp: now.addingTimeInterval(-30),
            reason: "settings-restart"
        )

        let decision = relaunchDecision(
            marker: marker,
            terminatedPID: pid,
            now: now,
            recentRelaunches: []
        )

        #expect(decision == .suppress)
    }

    @Test func decisionRelaunchesForStaleOrMismatchedSettingsRestartMarker() {
        let stale = ExpectedExitMarker(
            pid: pid,
            timestamp: now.addingTimeInterval(-200),
            reason: "settings-restart"
        )
        let mismatched = ExpectedExitMarker(
            pid: pid + 1,
            timestamp: now.addingTimeInterval(-30),
            reason: "settings-restart"
        )

        #expect(relaunchDecision(marker: stale, terminatedPID: pid, now: now, recentRelaunches: []) == .relaunch)
        #expect(relaunchDecision(marker: mismatched, terminatedPID: pid, now: now, recentRelaunches: []) == .relaunch)
    }

    @Test func decisionThrottleStopsWithinWindowAndRecoversAfterWindow() {
        let recent = [
            now.addingTimeInterval(-1),
            now.addingTimeInterval(-10),
            now.addingTimeInterval(-59)
        ]
        let expired = [
            now.addingTimeInterval(-61),
            now.addingTimeInterval(-90),
            now.addingTimeInterval(-120)
        ]

        #expect(relaunchDecision(marker: nil, terminatedPID: pid, now: now, recentRelaunches: recent) == .throttleStop)
        #expect(relaunchDecision(marker: nil, terminatedPID: pid, now: now, recentRelaunches: expired) == .relaunch)
    }

    @Test func adoptionRequiresMatchingOwnerBundleURL() {
        let ownerURL = URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true)
        let adopted = watchdogAdoptionDecision(
            product: .observer,
            ownerBundleURL: ownerURL,
            candidates: [WatchdogRunningCandidate(
                bundleIdentifier: "app.solstone.observer",
                processIdentifier: pid,
                bundleURL: ownerURL
            )]
        )
        let conflicting = watchdogAdoptionDecision(
            product: .observer,
            ownerBundleURL: ownerURL,
            candidates: [WatchdogRunningCandidate(
                bundleIdentifier: "app.solstone.observer",
                processIdentifier: pid,
                bundleURL: URL(fileURLWithPath: "/Applications/other.app", isDirectory: true)
            )]
        )

        #expect(adopted == .adopt(pid: pid))
        #expect(conflicting == .conflictingCopy(bundleURL: URL(fileURLWithPath: "/Applications/other.app", isDirectory: true), shortVersion: nil, buildVersion: nil))
    }

    @Test func enclosingAppURLFromExecutableInsideBundle() {
        let start = URL(fileURLWithPath: "/Applications/Foo.app/Contents/MacOS/bin")
        #expect(enclosingAppURL(from: start)?.path == "/Applications/Foo.app")
    }

    @Test func enclosingAppURLFromMacOSDir() {
        let start = URL(fileURLWithPath: "/Applications/Foo.app/Contents/MacOS")
        #expect(enclosingAppURL(from: start)?.path == "/Applications/Foo.app")
    }

    @Test func enclosingAppURLFromAppItself() {
        let start = URL(fileURLWithPath: "/Applications/Foo.app")
        #expect(enclosingAppURL(from: start)?.path == "/Applications/Foo.app")
    }

    @Test func enclosingAppURLReturnsNilWithoutAppAncestor() {
        let start = URL(fileURLWithPath: "/usr/local/bin/tool")
        #expect(enclosingAppURL(from: start) == nil)
    }

    @Test func cfURLFixtureDoesNotReachFixedPointWithin64Steps() {
        var current = cfFileURL("/Applications/Foo.app/Contents/MacOS/bin")
        // This confirms the CFURL fixture remains non-native.
        for _ in 0..<64 {
            let parent = current.deletingLastPathComponent()
            #expect(parent.path != current.path)
            current = parent
        }
    }

    @Test func enclosingAppURLReturnsNilForCFURLWithoutAppAncestor() {
        #expect(enclosingAppURL(from: cfFileURL("/usr/local/bin/tool")) == nil)
    }

    @Test func enclosingAppURLFindsCFURLBundleAncestorAsDirectory() {
        let expected = URL(fileURLWithPath: "/Applications/Foo.app", isDirectory: true)

        #expect(enclosingAppURL(from: cfFileURL("/Applications/Foo.app/Contents/MacOS/bin")) == expected)
    }

    @Test func enclosingAppURLFindsAppAfter4096NestedComponents() {
        let components = (0..<4_095).map { "component-\($0)" } + ["Foo.app"]
        let path = "/" + components.joined(separator: "/")
        let expected = URL(fileURLWithPath: path, isDirectory: true)

        #expect(enclosingAppURL(from: cfFileURL(path)) == expected)
    }

    @Test func enclosingAppURLStandardizesCFURLDotSegments() {
        let expected = URL(fileURLWithPath: "/Applications/Foo.app", isDirectory: true)

        #expect(enclosingAppURL(from: cfFileURL("/Applications/Foo.app/Contents/unused/../MacOS/bin")) == expected)
        #expect(enclosingAppURL(from: cfFileURL("/Applications/Foo.app/../bin")) == nil)
    }

    @Test func transitionPresentToAbsentReportsTermination() {
        let transition = observerPresenceTransition(lastKnownPID: pid, currentObserverPID: nil)

        #expect(transition.newLastKnownPID == nil)
        #expect(transition.terminatedPID == pid)
    }

    @Test func transitionAbsentToAbsentReportsNothing() {
        let transition = observerPresenceTransition(lastKnownPID: nil, currentObserverPID: nil)

        #expect(transition.newLastKnownPID == nil)
        #expect(transition.terminatedPID == nil)
    }

    @Test func transitionAbsentToPresentTracksWithoutEvent() {
        let transition = observerPresenceTransition(lastKnownPID: nil, currentObserverPID: pid)

        #expect(transition.newLastKnownPID == pid)
        #expect(transition.terminatedPID == nil)
    }

    @Test func transitionPresentToPresentTracksWithoutEvent() {
        let samePID = observerPresenceTransition(lastKnownPID: pid, currentObserverPID: pid)
        let changedPID = observerPresenceTransition(lastKnownPID: pid, currentObserverPID: pid + 1)

        #expect(samePID.newLastKnownPID == pid)
        #expect(samePID.terminatedPID == nil)
        #expect(changedPID.newLastKnownPID == pid + 1)
        #expect(changedPID.terminatedPID == nil)
    }

    @Test func transitionDoesNotRefireWhileAbsent() {
        var lastKnownPID: Int32? = pid

        let first = observerPresenceTransition(lastKnownPID: lastKnownPID, currentObserverPID: nil)
        #expect(first.terminatedPID == pid)

        lastKnownPID = first.newLastKnownPID
        let second = observerPresenceTransition(lastKnownPID: lastKnownPID, currentObserverPID: nil)

        #expect(second.newLastKnownPID == nil)
        #expect(second.terminatedPID == nil)
    }

    @Test func readAndConsumeRoundTripsAndDeletesMarker() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("expected-exit.json")
        let marker = ExpectedExitMarker(pid: pid, timestamp: now, reason: "quit")
        try marker.encoded().write(to: url)

        let decoded = ExpectedExitMarker.readAndConsume(at: url)

        #expect(decoded == marker)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func observerProductDefinesSolMarkerPath() {
        #expect(WatchdogProduct.observer.targetBundleID == "app.solstone.observer")
        #expect(WatchdogProduct.observer.loggerSubsystem == "app.solstone.observer.watchdog")
        #expect(WatchdogProduct.observer.markerDiscriminator == ExpectedExitMarker.solMarkerDiscriminator)
        #expect(ExpectedExitMarker.markerURL == SolstoneIdentity.applicationSupportURL.appendingPathComponent("expected-exit.json"))
    }

    @Test func journalProductDefinesDistinctMarkerPath() {
        #expect(WatchdogProduct.journal.targetBundleID == "app.solstone.journal")
        #expect(WatchdogProduct.journal.loggerSubsystem == "app.solstone.journal.watchdog")
        #expect(WatchdogProduct.journal.markerDiscriminator == ExpectedExitMarker.journalMarkerDiscriminator)
        #expect(ExpectedExitMarker.markerURL(for: WatchdogProduct.journal.markerDiscriminator) != ExpectedExitMarker.markerURL)
    }

    @Test func expectedExitMarkerAtDerivedJournalPathSuppressesRelaunch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = ExpectedExitMarker.markerURL(
            for: ExpectedExitMarker.journalMarkerDiscriminator,
            applicationSupportBaseURL: directory
        )
        ExpectedExitMarker.markExpectedExit(
            reason: "journal-test-quit",
            now: now,
            pid: pid,
            at: markerURL
        )

        let marker = ExpectedExitMarker.readAndConsume(at: markerURL)
        let decision = relaunchDecision(
            marker: marker,
            terminatedPID: pid,
            now: now,
            recentRelaunches: []
        )

        #expect(decision == .suppress)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test func plistKeysMatchLaunchAgentContract() throws {
        let plist = try loadWatchdogPlist("Sources/solstone/app.solstone.observer.watchdog.plist")

        #expect(plist["Label"] as? String == "app.solstone.observer.watchdog")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/solstone-watchdog")
        #expect(plist["RunAtLoad"] as? Bool == true)

        let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
        #expect(keepAlive["SuccessfulExit"] as? Bool == false)

        #expect(plist["ThrottleInterval"] as? Int == 30)
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["app.solstone.observer"])
    }

    @Test func journalPlistKeepsInertWatchdogEnvironmentContract() throws {
        let plist = try loadWatchdogPlist("Sources/journal/app.solstone.journal.watchdog.plist")

        #expect(plist["Label"] as? String == "app.solstone.journal.watchdog")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/solstone-watchdog")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 30)
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["app.solstone.journal"])

        let environment = try #require(plist["EnvironmentVariables"] as? [String: String])
        #expect(environment["SOLSTONE_WATCHDOG_TARGET_BUNDLE_ID"] == "app.solstone.journal")
        #expect(environment["SOLSTONE_WATCHDOG_LOGGER_SUBSYSTEM"] == "app.solstone.journal.watchdog")
        #expect(environment["SOLSTONE_WATCHDOG_MARKER_DISCRIMINATOR"] == ExpectedExitMarker.journalMarkerDiscriminator)
        #expect(!environment.values.contains { $0.hasPrefix("/") })
    }

    private func loadWatchdogPlist(_ relativePath: String) throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: plistURL)
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(value as? [String: Any])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-watchdog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func cfFileURL(_ path: String) -> URL {
    CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path as CFString, .cfurlposixPathStyle, false)! as URL
}
