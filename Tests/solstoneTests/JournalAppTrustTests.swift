// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Journal app trust")
@MainActor
struct JournalAppTrustTests {
    private let journalAppURL = URL(fileURLWithPath: "/Applications/journal.app", isDirectory: true)

    @Test func installedVariantOmitsStrict() async throws {
        let calls = LockedArray<[String]>([])
        let verifier = verifier(recording: calls) { _, arguments in
            if arguments.first == "-dvvv" {
                return trustedDetails()
            }
            return emptySuccess()
        }

        try await verifier.verifyJournalApp(at: journalAppURL, variant: .installed)

        #expect(calls.all == [
            ["/usr/bin/codesign", "--verify", "--deep", "--verbose=2", "/Applications/journal.app"],
            ["/usr/bin/codesign", "-dvvv", "/Applications/journal.app"]
        ])
    }

    @Test func installedVerifyFailureStopsBeforeDetails() async {
        let calls = LockedArray<[String]>([])
        let verifier = verifier(recording: calls) { _, _ in
            JournalHandoffProcessResult(terminationStatus: 1, stdout: "", stderr: "bad seal")
        }

        await #expect(throws: JournalHandoffFailure.trustFailed("codesign verify exited 1: bad seal")) {
            try await verifier.verifyJournalApp(at: journalAppURL, variant: .installed)
        }
        #expect(calls.all.count == 1)
    }

    @Test func installedDetailsFailure() async {
        let calls = LockedArray<[String]>([])
        let verifier = verifier(recording: calls) { _, arguments in
            if arguments.first == "-dvvv" {
                return JournalHandoffProcessResult(terminationStatus: 1, stdout: "", stderr: "details failed")
            }
            return emptySuccess()
        }

        await #expect(throws: JournalHandoffFailure.trustFailed("details failed")) {
            try await verifier.verifyJournalApp(at: journalAppURL, variant: .installed)
        }
        #expect(calls.all.count == 2)
    }

    @Test func installedIdentifierAndTeamMustMatch() async {
        let wrongIdentifier = LiveTrustVerifier { _, arguments in
            if arguments.first == "-dvvv" {
                return JournalHandoffProcessResult(
                    terminationStatus: 0,
                    stdout: "Identifier=example.other\nTeamIdentifier=\(JournalHandoffConstants.teamIdentifier)",
                    stderr: ""
                )
            }
            return emptySuccess()
        }
        let wrongTeam = LiveTrustVerifier { _, arguments in
            if arguments.first == "-dvvv" {
                return JournalHandoffProcessResult(
                    terminationStatus: 0,
                    stdout: "Identifier=\(JournalHandoffConstants.journalBundleIdentifier)\nTeamIdentifier=OTHERTEAM",
                    stderr: ""
                )
            }
            return emptySuccess()
        }

        await #expect(throws: JournalHandoffFailure.trustFailed("bundle identifier mismatch")) {
            try await wrongIdentifier.verifyJournalApp(at: journalAppURL, variant: .installed)
        }
        await #expect(throws: JournalHandoffFailure.trustFailed("team identifier mismatch")) {
            try await wrongTeam.verifyJournalApp(at: journalAppURL, variant: .installed)
        }
    }

    @Test func downloadedVariantKeepsStrict() async throws {
        let calls = LockedArray<[String]>([])
        let verifier = verifier(recording: calls) { _, arguments in
            if arguments.first == "-dvvv" {
                return trustedDetails()
            }
            return emptySuccess()
        }

        try await verifier.verifyJournalApp(at: journalAppURL, variant: .downloaded)

        #expect(calls.all == [
            ["/usr/bin/codesign", "--verify", "--strict", "--deep", "--verbose=2", "/Applications/journal.app"],
            ["/usr/bin/codesign", "-dvvv", "/Applications/journal.app"]
        ])
    }

    @Test func downloadedVerifyFailureStopsBeforeDetails() async {
        let calls = LockedArray<[String]>([])
        let verifier = verifier(recording: calls) { _, _ in
            JournalHandoffProcessResult(terminationStatus: 1, stdout: "", stderr: "bad seal")
        }

        await #expect(throws: JournalHandoffFailure.trustFailed("codesign verify exited 1: bad seal")) {
            try await verifier.verifyJournalApp(at: journalAppURL, variant: .downloaded)
        }
        #expect(calls.all.count == 1)
    }

    private func verifier(
        recording calls: LockedArray<[String]>,
        response: @escaping @Sendable (String, [String]) async throws -> JournalHandoffProcessResult
    ) -> LiveTrustVerifier {
        LiveTrustVerifier { executable, arguments in
            calls.append([executable] + arguments)
            return try await response(executable, arguments)
        }
    }
}

private func emptySuccess() -> JournalHandoffProcessResult {
    JournalHandoffProcessResult(terminationStatus: 0, stdout: "", stderr: "")
}

private func trustedDetails() -> JournalHandoffProcessResult {
    JournalHandoffProcessResult(
        terminationStatus: 0,
        stdout: """
        Identifier=\(JournalHandoffConstants.journalBundleIdentifier)
        TeamIdentifier=\(JournalHandoffConstants.teamIdentifier)
        """,
        stderr: ""
    )
}
