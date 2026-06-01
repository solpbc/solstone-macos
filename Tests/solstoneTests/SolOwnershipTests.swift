// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SolOwnership")
struct SolOwnershipTests {
    @Test func classifyNoCandidatesReturnsAbsent() {
        #expect(SolOwnership.classify(candidates: [], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: false) == .absent)
    }

    @Test func classifyRuntimeOnlyWithoutCredsIsAppManaged() {
        let candidate = (path: "/tmp/runtime/bin/sol", resolved: "/tmp/runtime/bin/sol")

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: false) == .appManaged(solPath: candidate.path))
    }

    @Test func classifyRuntimeOnlyWithCredsIsAppManaged() {
        let candidate = (path: "/tmp/runtime/bin/sol", resolved: "/tmp/runtime/bin/sol")

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: true) == .appManaged(solPath: candidate.path))
    }

    @Test func classifyExternalOnlyWithoutCredsIsExternal() {
        let candidate = (path: "/opt/homebrew/bin/sol", resolved: "/opt/homebrew/bin/sol")

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: false) == .externallyManaged(solPath: candidate.path))
    }

    @Test func classifyExternalOnlyWithCredsIsExternal() {
        let candidate = (path: "/opt/homebrew/bin/sol", resolved: "/opt/homebrew/bin/sol")

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: true) == .externallyManaged(solPath: candidate.path))
    }

    @Test func classifyRuntimeAndExternalWithCredsPrefersExternal() {
        let runtime = (path: "/tmp/runtime/bin/sol", resolved: "/tmp/runtime/bin/sol")
        let external = (path: "/opt/homebrew/bin/sol", resolved: "/opt/homebrew/bin/sol")

        #expect(SolOwnership.classify(candidates: [runtime, external], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: true) == .externallyManaged(solPath: external.path))
    }

    @Test func classifyRuntimeAndExternalWithoutCredsPrefersRuntime() {
        let runtime = (path: "/tmp/runtime/bin/sol", resolved: "/tmp/runtime/bin/sol")
        let external = (path: "/opt/homebrew/bin/sol", resolved: "/opt/homebrew/bin/sol")

        #expect(SolOwnership.classify(candidates: [runtime, external], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: false) == .appManaged(solPath: runtime.path))
    }

    @Test func prefixRuleRejectsSubstringRuntimeRoot() {
        #expect(!SolOwnership.isUnderRoot("/tmp/runtime-x/bin/sol", root: "/tmp/runtime"))
        #expect(SolOwnership.classify(
            candidates: [(path: "/tmp/runtime-x/bin/sol", resolved: "/tmp/runtime-x/bin/sol")],
            runtimeRoot: "/tmp/runtime",
            hasLocalJournalCreds: false
        ) == .externallyManaged(solPath: "/tmp/runtime-x/bin/sol"))
    }

    @Test func resolverIncludesRuntimeLocalAndWhichCandidates() async {
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(stdout: Data("/opt/which/sol\n".utf8)))
        let runtimePath = SolstoneRuntimeLayout().solBinary.path
        let home = URL(fileURLWithPath: "/tmp/solownership-home")
        let preferred = home.appendingPathComponent(".local/bin/sol").path
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { path in path == runtimePath || path == preferred },
            homeDirectory: home
        )

        let ownership = await resolver(true)

        #expect(ownership == .externallyManaged(solPath: preferred))
        #expect(runner.invocations.map(\.executable.path) == ["/usr/bin/which"])
        #expect(runner.invocations.map(\.arguments) == [["sol"]])
    }

    @Test func resolverClassifiesSymlinkedLocalBinByResolvedTarget() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let targetDir = root.appendingPathComponent("repo/.venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let target = targetDir.appendingPathComponent("sol")
        try Data("sol\n".utf8).write(to: target)
        let link = localBin.appendingPathComponent("sol")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(exitCode: 1))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home
        )

        let ownership = await resolver(true)

        #expect(ownership == .externallyManaged(solPath: link.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
