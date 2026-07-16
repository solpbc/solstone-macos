// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalRuntime

@Suite("LaunchdServiceRetirement")
struct LaunchdServiceRetirementTests {
    @Test func parsesRunningProgramArgumentsPrintShape() {
        let output = """
        domain = gui/501
        path = /Users/jer/Library/LaunchAgents/com.example.solstone-test.plist
        state = running
        program = /Users/jer/.local/bin/journal
        arguments = {
            /Users/jer/.local/bin/journal
            start
            5015
        }
        pid = 30493
        properties = inferred program
        """

        guard case .loaded(let job) = parseLaunchdPrint(exitCode: 0, output: output) else {
            Issue.record("expected loaded job")
            return
        }

        #expect(job.path == testPlistPath)
        #expect(job.state == .running)
        #expect(job.program == "/Users/jer/.local/bin/journal")
        #expect(job.arguments == ["/Users/jer/.local/bin/journal", "start", "5015"])
        #expect(job.pid == 30493)
    }

    @Test func parsesNotRunningProgramArgumentsPrintShapeWithoutPID() {
        let output = """
        path = /Users/jer/Library/LaunchAgents/com.example.solstone-test.plist
        state = not running
        program = /Users/jer/.local/bin/journal
        arguments = {
            /Users/jer/.local/bin/journal
            start
            5015
        }
        properties = inferred program
        """

        guard case .loaded(let job) = parseLaunchdPrint(exitCode: 0, output: output) else {
            Issue.record("expected loaded job")
            return
        }

        #expect(job.state == .notRunning)
        #expect(job.pid == nil)
    }

    @Test func decisionTableBlocksEveryAmbiguousCell() {
        let plist = matchingPlist()
        let loaded = matchingLoadedJob()
        let cases: [(LaunchdPlistState, LaunchdPrintState, LaunchdRootProof, ExpectedDecision)] = [
            (.absent, .loaded(loaded), .matches, .block),
            (.absent, .loaded(loaded), .differs, .block),
            (.absent, .loaded(loaded), .unclassifiable, .block),
            (.absent, .notFound113, .matches, .block),
            (.absent, .notFound113, .differs, .block),
            (.absent, .notFound113, .unclassifiable, .noOp),
            (.absent, .otherError(exitCode: 5, output: ""), .matches, .block),
            (.absent, .otherError(exitCode: 5, output: ""), .differs, .block),
            (.absent, .otherError(exitCode: 5, output: ""), .unclassifiable, .block),

            (.malformed("bad"), .loaded(loaded), .matches, .block),
            (.malformed("bad"), .loaded(loaded), .differs, .block),
            (.malformed("bad"), .loaded(loaded), .unclassifiable, .block),
            (.malformed("bad"), .notFound113, .matches, .block),
            (.malformed("bad"), .notFound113, .differs, .block),
            (.malformed("bad"), .notFound113, .unclassifiable, .block),
            (.malformed("bad"), .otherError(exitCode: 5, output: ""), .matches, .block),
            (.malformed("bad"), .otherError(exitCode: 5, output: ""), .differs, .block),
            (.malformed("bad"), .otherError(exitCode: 5, output: ""), .unclassifiable, .block),

            (.present(plist), .loaded(loaded), .matches, .retire),
            (.present(plist), .loaded(loaded), .differs, .block),
            (.present(plist), .loaded(loaded), .unclassifiable, .block),
            (.present(plist), .notFound113, .matches, .retire),
            (.present(plist), .notFound113, .differs, .block),
            (.present(plist), .notFound113, .unclassifiable, .block),
            (.present(plist), .otherError(exitCode: 5, output: ""), .matches, .block),
            (.present(plist), .otherError(exitCode: 5, output: ""), .differs, .block),
            (.present(plist), .otherError(exitCode: 5, output: ""), .unclassifiable, .block)
        ]

        for (plistState, printState, rootProof, expected) in cases {
            #expect(expected.matches(decideLaunchdOwnership(
                plistState: plistState,
                printState: printState,
                rootProof: rootProof
            )))
        }
    }

    @Test func loadedJobContradictingPlistBlocksEvenWhenRootMatches() {
        let mismatchedJob = LaunchdLoadedJob(
            path: testPlistPath,
            state: .running,
            program: "/bin/sleep",
            arguments: ["/bin/sleep", "30"],
            pid: 30493
        )

        let decision = decideLaunchdOwnership(
            plistState: .present(matchingPlist()),
            printState: .loaded(mismatchedJob),
            rootProof: .matches
        )

        #expect(ExpectedDecision.block.matches(decision))
    }
}

private enum ExpectedDecision {
    case noOp
    case retire
    case block

    func matches(_ decision: LaunchdOwnershipDecision) -> Bool {
        switch (self, decision) {
        case (.noOp, .noOp), (.retire, .retire), (.block, .block):
            return true
        default:
            return false
        }
    }
}

private let testPlistPath = "/Users/jer/Library/LaunchAgents/com.example.solstone-test.plist"
private let testLabel = "com.example.solstone-test"

private func matchingPlist() -> LaunchdPlist {
    LaunchdPlist(
        path: testPlistPath,
        label: testLabel,
        programArguments: ["/Users/jer/.local/bin/journal", "start", "5015"],
        standardOutPath: "/Users/jer/journal/health/service.log"
    )
}

private func matchingLoadedJob() -> LaunchdLoadedJob {
    LaunchdLoadedJob(
        path: testPlistPath,
        state: .running,
        program: "/Users/jer/.local/bin/journal",
        arguments: ["/Users/jer/.local/bin/journal", "start", "5015"],
        pid: 30493
    )
}
