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
        let candidate = (path: "/tmp/runtime/bin/sol", resolved: "/tmp/runtime/bin/sol", provenance: SolOwnership.Provenance.bare)

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: false) == .appManaged(solPath: candidate.path))
    }

    @Test func classifyRuntimeOnlyWithCredsIsAppManaged() {
        let candidate = (path: "/tmp/runtime/bin/sol", resolved: "/tmp/runtime/bin/sol", provenance: SolOwnership.Provenance.bare)

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: true) == .appManaged(solPath: candidate.path))
    }

    @Test func classifyVersionedRuntimePathIsAppManaged() {
        let candidate = (path: "/tmp/runtime/versions/0.4.8/bin/sol", resolved: "/tmp/runtime/versions/0.4.8/bin/sol", provenance: SolOwnership.Provenance.bare)

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: false) == .appManaged(solPath: candidate.path))
    }

    @Test func classifyExternalOnlyWithoutCredsIsExternal() {
        let candidate = (path: "/opt/homebrew/bin/sol", resolved: "/opt/homebrew/bin/sol", provenance: SolOwnership.Provenance.bare)

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: false) == .externallyManaged(solPath: candidate.path))
    }

    @Test func classifyExternalOnlyWithCredsIsExternal() {
        let candidate = (path: "/opt/homebrew/bin/sol", resolved: "/opt/homebrew/bin/sol", provenance: SolOwnership.Provenance.bare)

        #expect(SolOwnership.classify(candidates: [candidate], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: true) == .externallyManaged(solPath: candidate.path))
    }

    @Test func classifyRuntimeAndExternalWithCredsPrefersExternal() {
        let runtime = (path: "/tmp/runtime/bin/sol", resolved: "/tmp/runtime/bin/sol", provenance: SolOwnership.Provenance.bare)
        let external = (path: "/opt/homebrew/bin/sol", resolved: "/opt/homebrew/bin/sol", provenance: SolOwnership.Provenance.bare)

        #expect(SolOwnership.classify(candidates: [runtime, external], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: true) == .externallyManaged(solPath: external.path))
    }

    @Test func classifyRuntimeAndExternalWithoutCredsPrefersRuntime() {
        let runtime = (path: "/tmp/runtime/bin/sol", resolved: "/tmp/runtime/bin/sol", provenance: SolOwnership.Provenance.bare)
        let external = (path: "/opt/homebrew/bin/sol", resolved: "/opt/homebrew/bin/sol", provenance: SolOwnership.Provenance.bare)

        #expect(SolOwnership.classify(candidates: [runtime, external], runtimeRoot: "/tmp/runtime", hasLocalJournalCreds: false) == .appManaged(solPath: runtime.path))
    }

    @Test func prefixRuleRejectsSubstringRuntimeRoot() {
        #expect(!SolOwnership.isUnderRoot("/tmp/runtime-x/bin/sol", root: "/tmp/runtime"))
        #expect(SolOwnership.classify(
            candidates: [(path: "/tmp/runtime-x/bin/sol", resolved: "/tmp/runtime-x/bin/sol", provenance: SolOwnership.Provenance.bare)],
            runtimeRoot: "/tmp/runtime",
            hasLocalJournalCreds: false
        ) == .externallyManaged(solPath: "/tmp/runtime-x/bin/sol"))
    }

    @Test func classifyAppOwnedChildUnderRootWithCredsAndExternalPrefersAppManaged() {
        let wrapper = (
            path: "/home/.local/bin/sol",
            resolved: "/tmp/runtime/1.0.0_py_abc/bin/sol",
            provenance: SolOwnership.Provenance.appOwnedChild
        )
        let external = (
            path: "/opt/homebrew/bin/sol",
            resolved: "/opt/homebrew/bin/sol",
            provenance: SolOwnership.Provenance.bare
        )

        #expect(SolOwnership.classify(
            candidates: [wrapper, external],
            runtimeRoot: "/tmp/runtime",
            hasLocalJournalCreds: true
        ) == .appManaged(solPath: wrapper.path))
    }

    @Test func classifyAppOwnedChildOutsideRootDoesNotForceAppManaged() {
        let wrapper = (
            path: "/home/.local/bin/sol",
            resolved: "/opt/homebrew/bin/sol",
            provenance: SolOwnership.Provenance.appOwnedChild
        )

        #expect(SolOwnership.classify(
            candidates: [wrapper],
            runtimeRoot: "/tmp/runtime",
            hasLocalJournalCreds: false
        ) == .externallyManaged(solPath: wrapper.path))
    }

    @Test func resolverIncludesRuntimeLocalAndWhichCandidates() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let layout = try makeRuntimeWithSpace(in: workspace)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let preferred = home.appendingPathComponent(".local/bin/sol")
        try writeText("bare sol\n", to: preferred)
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(stdout: Data("/opt/which/sol\n".utf8)))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: layout.rootURL
        )

        let ownership = await resolver(true)

        #expect(ownership == .externallyManaged(solPath: preferred.path))
        #expect(runner.invocations.map(\.executable.path) == ["/usr/bin/which"])
        #expect(runner.invocations.map(\.arguments) == [["sol"]])
    }

    @Test func resolverPrefersActiveVersionedRuntimeWithoutCreds() async throws {
        let root = try makeTemporaryDirectory()
            .appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let layout = SolstoneRuntimeLayout(rootURL: root, mode: .versioned("0.4.8"))
        try layout.ensureCreated()
        try Data("sol\n".utf8).write(to: layout.solBinary)
        try FileManager.default.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "versions/0.4.8")
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(stdout: Data("/opt/which/sol\n".utf8)))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            rootURL: root
        )

        let ownership = await resolver(false)

        #expect(ownership == .appManaged(solPath: layout.solBinary.path))
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

    @Test func resolverResolvesManagedWrapperThroughToAppManaged() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let layout = try makeRuntimeWithSpace(in: workspace)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let wrapper = home.appendingPathComponent(".local/bin/sol")
        try writeManagedWrapper(at: wrapper, solBin: layout.solBinary.path)
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(exitCode: 1))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: layout.rootURL
        )

        let ownership = await resolver(true)

        #expect(layout.rootURL.path.contains("Application Support"))
        #expect(layout.solBinary.path.contains("Application Support"))
        #expect(ownership == .appManaged(solPath: layout.solBinary.path))
    }

    @Test func resolverClassifiesAppOwnedChildWrapperAsAppManaged() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let layout = try makeRuntimeWithSpace(in: workspace)
        try FileManager.default.removeItem(at: layout.solBinary)
        let keySol = layout.rootURL
            .appendingPathComponent("1.0.0_py_abc/bin", isDirectory: true)
            .appendingPathComponent("sol")
        try writeText("runtime sol\n", to: keySol)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let wrapper = home.appendingPathComponent(".local/bin/sol")
        try writeAppOwnedChildWrapper(at: wrapper, target: keySol.path)
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(stdout: Data("/opt/homebrew/bin/sol\n".utf8)))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: layout.rootURL
        )

        let ownership = await resolver(true)

        #expect(layout.rootURL.path.contains("Application Support"))
        #expect(keySol.path.contains("Application Support"))
        #expect(ownership == .appManaged(solPath: wrapper.path))
    }

    @Test func resolverAppOwnedChildWrapperWinsOverLeftoverVersionedRuntime() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let layout = try makeRuntimeWithSpace(in: workspace)
        try FileManager.default.removeItem(at: layout.solBinary)
        let keySol = layout.rootURL
            .appendingPathComponent("1.0.0_py_abc/bin", isDirectory: true)
            .appendingPathComponent("sol")
        try writeText("runtime sol\n", to: keySol)
        let legacyLayout = SolstoneRuntimeLayout(rootURL: layout.rootURL, mode: .versioned("0.4.8"))
        try legacyLayout.ensureCreated()
        try writeText("legacy runtime sol\n", to: legacyLayout.solBinary)
        try FileManager.default.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "versions/0.4.8")
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let wrapper = home.appendingPathComponent(".local/bin/sol")
        try writeAppOwnedChildWrapper(at: wrapper, target: keySol.path)
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(stdout: Data("/opt/homebrew/bin/sol\n".utf8)))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: layout.rootURL
        )

        let ownership = await resolver(true)

        #expect(ownership == .appManaged(solPath: wrapper.path))
    }

    @Test func appOwnedChildWrapperRoundTripsApostropheTarget() async throws {
        let target = "/Users/o'brien/Library/Application Support/sol/runtime/k/bin/sol"

        for roundTripTarget in [
            "",
            "/Users/sol/Library/Application Support/sol/runtime/k/bin/sol",
            target,
            "/Users/o''brien/Library/Application Support/sol/runtime/k/bin/sol",
        ] {
            #expect(ManagedWrapper.shellSingleUnquoted(ManagedWrapper.shellSingleQuoted(roundTripTarget)) == roundTripTarget)
        }

        let script = ManagedWrapper.script(forTarget: target)
        let execLine = script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("exec ") }
        #expect(execLine.flatMap { ManagedWrapper.execTarget(fromLine: String($0)) } == target)

        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let wrapper = home.appendingPathComponent(".local/bin/sol")
        try writeAppOwnedChildWrapper(at: wrapper, target: target)
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(exitCode: 1))
        let runtimeRoot = URL(fileURLWithPath: "/Users/o'brien/Library/Application Support/sol/runtime", isDirectory: true)
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: runtimeRoot
        )

        let ownership = await resolver(false)

        #expect(ownership == .appManaged(solPath: wrapper.path))
    }

    @Test func resolverClassifiesNonMarkerLocalBinAsExternal() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let layout = try makeRuntimeWithSpace(in: workspace)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let wrapper = home.appendingPathComponent(".local/bin/sol")
        try writeText("#!/bin/bash\nexec /opt/homebrew/bin/sol \"$@\"\n", to: wrapper)
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(exitCode: 1))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: layout.rootURL
        )

        let ownership = await resolver(true)

        #expect(ownership == .externallyManaged(solPath: wrapper.path))
    }

    @Test func resolverKeepsMarkerWrapperWithOutsideRootTargetExternal() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let layout = try makeRuntimeWithSpace(in: workspace)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let wrapper = home.appendingPathComponent(".local/bin/sol")
        let outsideTarget = workspace.appendingPathComponent("outside/bin/sol")
        try writeText("outside sol\n", to: outsideTarget)
        try writeManagedWrapper(at: wrapper, solBin: outsideTarget.path)
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(exitCode: 1))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: layout.rootURL
        )

        let ownership = await resolver(true)

        #expect(ownership == .externallyManaged(solPath: wrapper.path))
    }

    @Test func resolverClassifiesStaleMarkerWrapperAsExternal() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let layout = try makeRuntimeWithSpace(in: workspace)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let wrapper = home.appendingPathComponent(".local/bin/sol")
        let staleTarget = workspace.appendingPathComponent("does not exist/sol")
        try writeManagedWrapper(at: wrapper, solBin: staleTarget.path)
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(exitCode: 1))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: layout.rootURL
        )

        let ownership = await resolver(true)

        #expect(!FileManager.default.fileExists(atPath: staleTarget.path))
        #expect(ownership == .externallyManaged(solPath: wrapper.path))
    }

    @Test func resolverFallsBackToLiteralOnUnparseableSolBin() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let layout = try makeRuntimeWithSpace(in: workspace)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let wrapper = home.appendingPathComponent(".local/bin/sol")
        try writeText(
            "#!/bin/bash\n# sol - managed by 'journal config'. Edits will be overwritten.\nSOL_BIN=\"\(layout.solBinary.path)\"\nexec \"$SOL_BIN\" \"$@\"\n",
            to: wrapper
        )
        let runner = FakeSubprocessRunner()
        runner.enqueue("sol", .success(exitCode: 1))
        let resolver = SolOwnership.defaultResolver(
            runner: runner,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: home,
            rootURL: layout.rootURL
        )

        let ownership = await resolver(true)

        #expect(ownership == .externallyManaged(solPath: wrapper.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRuntimeWithSpace(in workspace: URL) throws -> SolstoneRuntimeLayout {
        let root = workspace
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("sol", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        let layout = SolstoneRuntimeLayout(rootURL: root)
        try layout.ensureCreated()
        try writeText("runtime sol\n", to: layout.solBinary)
        return layout
    }

    private func writeManagedWrapper(
        at url: URL,
        solBin: String,
        marker: String = "# sol - managed by 'journal config'. Edits will be overwritten.\n# managed-version: 7"
    ) throws {
        let body = "#!/bin/bash\n\(marker)\nSOL_BIN='\(solBin)'\nexec \"$SOL_BIN\" \"$@\"\n"
        try writeText(body, to: url)
    }

    private func writeAppOwnedChildWrapper(at url: URL, target: String) throws {
        try writeText(ManagedWrapper.script(forTarget: target) + "\n", to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
