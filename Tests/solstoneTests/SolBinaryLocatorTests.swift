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

    @Test func findSolBinary_prefersActiveVersionedRuntimePath() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let layout = SolstoneRuntimeLayout(rootURL: root, mode: .versioned("0.4.8"))
        try layout.ensureCreated()
        try Data("sol\n".utf8).write(to: layout.solBinary)
        try layout.activate()

        let found = await SolBinaryLocator.findSolBinary(rootURL: root)

        #expect(found == layout.solBinary.path)
    }

    @Test func findSolBinary_fallsBackToFlatRuntimeWithoutCurrent() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let layout = SolstoneRuntimeLayout(rootURL: root)
        try layout.ensureCreated()
        try Data("sol\n".utf8).write(to: layout.solBinary)

        let found = await SolBinaryLocator.findSolBinary(rootURL: root)

        #expect(found == layout.solBinary.path)
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

    @Test func findSolBinary_returnsPreferredPathWhenExists() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let preferred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/sol").path

        let found = await SolBinaryLocator.findSolBinary(rootURL: root, fileExists: { path in
            path == preferred
        })

        #expect(found == preferred)
    }

    @Test func findSolBinary_returnsSolPathWhenPresent() async {
        let found = await SolBinaryLocator.findSolBinary()
        guard let found else {
            return
        }

        #expect(found.hasSuffix("/sol"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solbinarylocator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
