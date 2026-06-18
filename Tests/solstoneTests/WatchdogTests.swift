// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SolstoneCore

@Suite("Watchdog")
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

    @Test func adoptBranchUsesRunningBundleIDs() {
        #expect(shouldAdopt(runningBundleIDs: ["app.solstone.observer"], target: "app.solstone.observer"))
        #expect(!shouldAdopt(runningBundleIDs: ["com.other"], target: "app.solstone.observer"))
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

    @Test func plistKeysMatchLaunchAgentContract() throws {
        let plist = try loadWatchdogPlist()

        #expect(plist["Label"] as? String == "app.solstone.observer.watchdog")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/solstone-watchdog")
        #expect(plist["RunAtLoad"] as? Bool == true)

        let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])
        #expect(keepAlive["SuccessfulExit"] as? Bool == false)

        #expect(plist["ThrottleInterval"] as? Int == 30)
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["app.solstone.observer"])
    }

    private func loadWatchdogPlist() throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot.appendingPathComponent("Sources/solstone/app.solstone.observer.watchdog.plist")
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
