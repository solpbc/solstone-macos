// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SolstoneTrustVerifier")
struct SolstoneTrustVerifierTests {
    @Test func verifiesCodesignAndAssertsSolstoneIdentity() throws {
        let calls = LockedArray<[String]>([])
        let verifier = SolstoneTrustVerifier { executable, arguments in
            calls.append([executable] + arguments)
            if arguments.first == "-dvvv" {
                return SolstoneProcessResult(
                    terminationStatus: 0,
                    combinedOutput: """
                    Identifier=app.solstone.observer
                    TeamIdentifier=7QCG8V4M6H
                    """
                )
            }
            return SolstoneProcessResult(terminationStatus: 0, combinedOutput: "")
        }

        try verifier.verifySolstoneApp(at: URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true))

        #expect(calls.all == [
            ["/usr/bin/codesign", "--verify", "--strict", "--deep", "--verbose=2", "/Applications/solstone.app"],
            ["/usr/bin/codesign", "-dvvv", "/Applications/solstone.app"]
        ])
    }

    @Test func verifyFailureStopsBeforeDetails() {
        let calls = LockedCounter()
        let verifier = SolstoneTrustVerifier { _, _ in
            calls.increment()
            return SolstoneProcessResult(terminationStatus: 1, combinedOutput: "bad signature")
        }

        #expect(throws: SolstoneTrustVerificationError.verifyFailed("bad signature")) {
            try verifier.verifySolstoneApp(at: URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true))
        }
        #expect(calls.count == 1)
    }

    @Test func detailsMustMatchBundleIdentifierAndTeamIdentifier() {
        let wrongBundle = SolstoneTrustVerifier { _, arguments in
            if arguments.first == "-dvvv" {
                return SolstoneProcessResult(
                    terminationStatus: 0,
                    combinedOutput: "Identifier=example.other\nTeamIdentifier=7QCG8V4M6H"
                )
            }
            return SolstoneProcessResult(terminationStatus: 0, combinedOutput: "")
        }
        let wrongTeam = SolstoneTrustVerifier { _, arguments in
            if arguments.first == "-dvvv" {
                return SolstoneProcessResult(
                    terminationStatus: 0,
                    combinedOutput: "Identifier=app.solstone.observer\nTeamIdentifier=OTHERTEAM"
                )
            }
            return SolstoneProcessResult(terminationStatus: 0, combinedOutput: "")
        }

        #expect(throws: SolstoneTrustVerificationError.bundleIdentifierMismatch) {
            try wrongBundle.verifySolstoneApp(at: URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true))
        }
        #expect(throws: SolstoneTrustVerificationError.teamIdentifierMismatch) {
            try wrongTeam.verifySolstoneApp(at: URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true))
        }
    }
}
