// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SolBinaryLocator")
struct SolBinaryLocatorTests {
    @Test func findSolBinary_prefersRuntimeRootPath() async {
        let runtimePath = SolstoneRuntimeLayout().solBinary.path

        let found = await SolBinaryLocator.findSolBinary(fileExists: { path in
            path == runtimePath
        })

        #expect(found == runtimePath)
        #expect(found?.hasSuffix("/sol/runtime/bin/sol") == true)
    }

    @Test func findSolBinary_fallsBackToLegacyLocalBinSol() async {
        let runtimePath = SolstoneRuntimeLayout().solBinary.path
        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/sol").path

        let found = await SolBinaryLocator.findSolBinary(fileExists: { path in
            path != runtimePath && path == legacyPath
        })

        #expect(found == legacyPath)
    }

    @Test func findSolBinary_fallsBackToWhich_whenNothingExists() async {
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(stdout: Data("/opt/homebrew/bin/sol\n".utf8)))

        let found = await SolBinaryLocator.findSolBinary(
            runner: runner,
            fileExists: { _ in false }
        )

        #expect(found == "/opt/homebrew/bin/sol")
        #expect(runner.invocations.map(\.executable.path) == ["/usr/bin/which"])
        #expect(runner.invocations.map(\.arguments) == [["sol"]])
    }

    @Test func findSolBinary_returnsPreferredPathWhenExists() async {
        let preferred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/sol").path
        guard FileManager.default.fileExists(atPath: preferred) else {
            return
        }

        let found = await SolBinaryLocator.findSolBinary()
        #expect(found == preferred)
    }

    @Test func findSolBinary_returnsSolPathWhenPresent() async {
        let found = await SolBinaryLocator.findSolBinary()
        guard let found else {
            return
        }

        #expect(found.hasSuffix("/sol"))
    }
}
