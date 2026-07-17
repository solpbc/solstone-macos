// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing

@Suite("RuntimeLayoutCleanupRegressionTests")
struct RuntimeLayoutCleanupRegressionTests {
    @Test func deletedRuntimeLayoutAndMigrationSymbolsDoNotAppearInSources() throws {
        let banned = [
            "SolstoneRuntimeLayout.active(",
            "readActiveVersion",
            "solCandidatePaths",
            "currentLink",
            "versionsDir",
            "versionRoot",
            ".versioned",
            "Mode.versioned",
            "LegacyJournalMigrat",
            "legacyManaged",
            "SolOwnership.isUnderRoot"
        ]

        let matches = try matchesInSolstoneSources(banned: banned)

        #expect(matches.isEmpty)
    }

    @Test func activeRuntimeFallbackPathsDoNotAppearInSources() throws {
        let banned = [
            "runtime/current",
            "runtime/versions",
            "runtime/bin/journal",
            "runtime/bin/sol"
        ]

        let matches = try matchesInSolstoneSources(banned: banned)

        #expect(matches.isEmpty)
    }

    @Test func journalRuntimeProbeDefaultsDoNotNameRuntimeLayout() throws {
        let source = try String(contentsOfFile: "Sources/JournalRuntime/JournalHealthCheck.swift", encoding: .utf8)

        #expect(!source.contains("URL = SolstoneRuntimeLayout"))
    }

    @Test func installModelsUsesMaterializedRuntimeEnvironment() throws {
        let source = try String(contentsOfFile: "Sources/JournalRuntime/SolstoneInstaller.swift", encoding: .utf8)

        #expect(source.contains("private func runInstallModels(runtime: MaterializedRuntime) async"))
        #expect(source.contains("await self?.runInstallModels(runtime: runtime)"))
        #expect(source.contains("runtime.layout.uvEnvironment()"))
        #expect(source.contains("executable: runtime.layout.journalBinary"))
        #expect(!source.contains("SolstoneRuntimeLayout.active(rootURL:"))
    }

    private func matchesInSolstoneSources(banned: [String]) throws -> [String] {
        var matches: [String] = []
        for url in try solstoneSourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in banned where source.contains(token) {
                matches.append("\(url.path): \(token)")
            }
        }
        return matches.sorted()
    }

    private func solstoneSourceFiles() throws -> [URL] {
        var urls: [URL] = []
        for path in ["Sources/solstone", "Sources/JournalRuntime"] {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }
}
