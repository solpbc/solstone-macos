// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
@testable import solstone

@Suite struct AppCommandLineTests {
    private func decision(_ words: String...) -> AppCommandLine.Decision {
        AppCommandLine.decision(arguments: ["/Applications/solstone.app/Contents/MacOS/solstone"] + words)
    }

    @Test func aPlainLaunchStartsTheApp() {
        #expect(decision() == .launch)
    }

    @Test func aFrameworkFlagStartsTheApp() {
        #expect(decision("-NSDocumentRevisionsDebugMode", "YES") == .launch)
        #expect(decision("-psn_0_12345") == .launch)
    }

    @Test func anUnknownWordPrintsUsageInsteadOfStarting() {
        #expect(decision("status") == .usage(exitCode: 64))
        #expect(decision("update", "--check") == .usage(exitCode: 64))
        #expect(decision("--version") == .usage(exitCode: 64))
    }

    @Test func askingForHelpSucceeds() {
        #expect(decision("--help") == .usage(exitCode: 0))
        #expect(decision("-h") == .usage(exitCode: 0))
        #expect(decision("help") == .usage(exitCode: 0))
    }
}

@Suite struct AppInstanceLockTests {
    private func lockURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-lock-\(UUID().uuidString)", isDirectory: true)
        return root.appendingPathComponent("Solstone/app.lock")
    }

    @Test func aSecondCopyFindsTheLockHeldUntilTheFirstEnds() throws {
        let url = try lockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

        guard case .acquired(let first) = AppInstanceLock.acquire(at: url) else {
            Issue.record("the first copy did not get the lock")
            return
        }
        #expect(AppInstanceLock.acquire(at: url) == .heldElsewhere)

        close(first)
        guard case .acquired(let next) = AppInstanceLock.acquire(at: url) else {
            Issue.record("the lock did not come free when its holder ended")
            return
        }
        close(next)
    }

    @Test func anUncheckableLockStillLetsTheAppStart() throws {
        let url = try lockURL()
        let parent = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: parent)

        #expect(AppInstanceLock.acquire(at: url) == .unavailable)
        #expect(AppInstanceLock.acquire(at: nil) == .unavailable)
    }
}
