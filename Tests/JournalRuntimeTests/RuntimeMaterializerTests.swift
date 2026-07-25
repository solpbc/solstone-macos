// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import JournalRuntime

@Suite("RuntimeMaterializer")
struct RuntimeMaterializerTests {
    @Test func sweepKeepsCrossVersionLiveKey() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = "0.6.4_py20260510_aaaaaaaaaaaaaaaa"
        let live = "0.6.1_py20260510_bbbbbbbbbbbbbbbb"
        let orphan = "0.6.0_py20260101_cccccccccccccccc"
        try createDirectories([current, live, orphan], in: root)

        RuntimeMaterializer.sweepRuntimeGenerations(
            in: root,
            currentKey: current,
            pinnedKeys: [live],
            skipGenerationGC: false,
            fileManager: .default
        )

        #expect(directoryExists(current, in: root))
        #expect(directoryExists(live, in: root))
        #expect(!directoryExists(orphan, in: root))
    }

    @Test func runtimeGenerationGrammarIsAnchoredAndStrict() {
        #expect(RuntimeMaterializer.isRuntimeGenerationDirectory(name: "0.6.4_py20260510_aaaaaaaaaaaaaaaa"))
        #expect(RuntimeMaterializer.isRuntimeGenerationDirectory(name: "0.6.1_py20260510_bbbbbbbbbbbbbbbb"))
        #expect(RuntimeMaterializer.isRuntimeGenerationDirectory(name: "0.5.0_py20251231_0123456789abcdef"))
        #expect(!RuntimeMaterializer.isRuntimeGenerationDirectory(name: "0.6.4_py"))
        #expect(!RuntimeMaterializer.isRuntimeGenerationDirectory(name: "0.6.4_python_notes"))
        #expect(!RuntimeMaterializer.isRuntimeGenerationDirectory(name: ".tmp-abc123"))
        #expect(!RuntimeMaterializer.isRuntimeGenerationDirectory(name: "python"))
        #expect(!RuntimeMaterializer.isRuntimeGenerationDirectory(name: "0.6.4_py20260510_aaaaaaaaaaaaaaa"))
        #expect(!RuntimeMaterializer.isRuntimeGenerationDirectory(name: "0.6.4_py20260510_aaaaaaaaaaaaaaaaa"))
        #expect(!RuntimeMaterializer.isRuntimeGenerationDirectory(name: "0.6.4_py20260510_AAAAAAAAAAAAAAAA"))
    }

    @Test func sweepIgnoresMalformedRuntimeLikeNames() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = "0.6.4_py20260510_aaaaaaaaaaaaaaaa"
        let orphan = "0.6.0_py20260101_cccccccccccccccc"
        let malformed = "0.6.4_python_notes"
        try createDirectories([current, orphan, malformed], in: root)

        RuntimeMaterializer.sweepRuntimeGenerations(
            in: root,
            currentKey: current,
            pinnedKeys: [],
            skipGenerationGC: false,
            fileManager: .default
        )

        #expect(directoryExists(current, in: root))
        #expect(!directoryExists(orphan, in: root))
        #expect(directoryExists(malformed, in: root))
    }

    @Test func sweepPreservesSharedInfrastructureAndVisibleSiblings() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = "0.6.4_py20260510_aaaaaaaaaaaaaaaa"
        let orphan = "0.6.0_py20260101_cccccccccccccccc"
        let shared = ["python", "cache", "tools", "bin", "versions", "notes"]
        try createDirectories(shared + [current, orphan], in: root)

        RuntimeMaterializer.sweepRuntimeGenerations(
            in: root,
            currentKey: current,
            pinnedKeys: [],
            skipGenerationGC: false,
            fileManager: .default
        )

        for name in shared {
            #expect(directoryExists(name, in: root))
        }
        // The `current` symlink is not seeded here; its name fails the generation grammar.
        #expect(directoryExists(current, in: root))
        #expect(!directoryExists(orphan, in: root))
    }

    @Test func sweepToleratesDeleteFailureAndContinues() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = "0.6.4_py20260510_aaaaaaaaaaaaaaaa"
        let failingOrphan = "0.6.0_py20260101_cccccccccccccccc"
        let deletableOrphan = "0.6.0_py20260101_dddddddddddddddd"
        try createDirectories([current, failingOrphan, deletableOrphan], in: root)
        let fileManager = RemovalFailingFileManager(failingName: failingOrphan)

        RuntimeMaterializer.sweepRuntimeGenerations(
            in: root,
            currentKey: current,
            pinnedKeys: [],
            skipGenerationGC: false,
            fileManager: fileManager
        )

        #expect(directoryExists(current, in: root))
        #expect(directoryExists(failingOrphan, in: root))
        #expect(!directoryExists(deletableOrphan, in: root))
    }

    @Test func sweepHandlesEmptyOnlyCurrentAndMissingRoots() throws {
        let emptyRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let currentOnlyRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: currentOnlyRoot) }
        let current = "0.6.4_py20260510_aaaaaaaaaaaaaaaa"
        try createDirectories([current], in: currentOnlyRoot)
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-runtime-materializer-missing-\(UUID().uuidString)", isDirectory: true)

        RuntimeMaterializer.sweepRuntimeGenerations(
            in: emptyRoot,
            currentKey: current,
            pinnedKeys: [],
            skipGenerationGC: false,
            fileManager: .default
        )
        RuntimeMaterializer.sweepRuntimeGenerations(
            in: currentOnlyRoot,
            currentKey: current,
            pinnedKeys: [],
            skipGenerationGC: false,
            fileManager: .default
        )
        RuntimeMaterializer.sweepRuntimeGenerations(
            in: missingRoot,
            currentKey: current,
            pinnedKeys: [],
            skipGenerationGC: false,
            fileManager: .default
        )

        #expect(directoryExists(current, in: currentOnlyRoot))
        #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    }

    @Test func materializeRelocatesRawAndPolyglotExportedEntriesAndLeavesPythonLinkUntouched() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        let runtimeChildren = try FileManager.default.contentsOfDirectory(atPath: fixture.runtimeRoot.path)
        #expect(!runtimeChildren.contains { $0.hasPrefix(".tmp-") })
        let rootPath = runtime.layout.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        for name in ["journal", "mlx-vlm-server", "sol", "solstone"] {
            try assertRelocatedExportedEntry(named: name, in: runtime, rootPath: rootPath)
        }
        try assertRelocatedUvPolyglotEntry(named: "journal", in: runtime)
        try assertRelocatedUvPolyglotEntry(named: "mlx-vlm-server", in: runtime)

        let pythonLink = runtime.layout.binDir.appendingPathComponent("python3.13")
        let pythonDestination = try FileManager.default.destinationOfSymbolicLink(atPath: pythonLink.path)
        #expect(pythonDestination == fixture.bundledPython.path)
        #expect(pythonLink.resolvingSymlinksInPath().standardizedFileURL.path == fixture.bundledPython.standardizedFileURL.path)
        #expect(!runner.invocations.contains { $0.executable.lastPathComponent == "mlx-vlm-server" })
    }

    @Test func materializeFailsClosedWhenDiscoveredExportedEntryDanglesDuringStaging() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: fixture.runtimeRoot,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                let tempRoot = try #require(children.first { $0.lastPathComponent.hasPrefix(".tmp-") })
                let layout = SolstoneRuntimeLayout(rootURL: tempRoot)
                let ghost = layout.binDir.appendingPathComponent("ghost")
                try FileManager.default.createSymbolicLink(
                    atPath: ghost.path,
                    withDestinationPath: tempRoot.appendingPathComponent("tools/solstone-journal/bin/ghost").path
                )
            } catch {
                Issue.record("failed to create dangling staged exported entry: \(error.localizedDescription)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail on dangling discovered exported entry")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
    }

    @Test func materializeRematerializesFinalRuntimeWithDanglingDiscoveredExportedEntry() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)
        let firstRuntime = try await materializer.materialize(excludingLiveKey: nil)
        let initialInstallCount = toolInstallCount(in: runner)

        let broken = firstRuntime.layout.binDir.appendingPathComponent("mlx-vlm-server")
        try FileManager.default.removeItem(at: broken)
        try FileManager.default.createSymbolicLink(
            atPath: broken.path,
            withDestinationPath: firstRuntime.layout.rootURL.appendingPathComponent("missing-mlx-vlm-server").path
        )

        let healedRuntime = try await materializer.materialize(excludingLiveKey: nil)

        #expect(toolInstallCount(in: runner) == initialInstallCount + 1)
        let rootPath = healedRuntime.layout.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        try assertRelocatedExportedEntry(named: "mlx-vlm-server", in: healedRuntime, rootPath: rootPath)
    }

    @Test func materializeRoundTripsUvTrampolineInterpreterPathWithSpacesAndSingleQuotes() async throws {
        let fixture = try makeMaterializerFixture(runtimeRootComponents: ["a b", "it's"])
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        let journal = runtime.layout.binDir.appendingPathComponent("journal").resolvingSymlinksInPath().standardizedFileURL
        let lines = try String(contentsOf: journal, encoding: .utf8).components(separatedBy: "\n")
        let expectedInterpreter = runtime.layout.rootURL
            .appendingPathComponent("tools/solstone-journal/bin/python")
            .standardizedFileURL
            .path
        #expect(lines.count >= 2)
        #expect(lines[1] == "'''exec' \(shellSingleQuotedForTest(expectedInterpreter)) \"$0\" \"$@\"")
    }

    @Test func relocatedRawSolExecutesSentinelViaShell() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)
        let sol = runtime.layout.binDir.appendingPathComponent("sol").resolvingSymlinksInPath().standardizedFileURL
        let result = try runShell(sol, arguments: ["--version"])

        #expect(result.status == 0)
        #expect(result.stdout == "solstone \(BundleConfig.solstonePinVersion)\n")
    }

    @Test func materializeLeavesRawLaunchersByteIdenticalAcrossRelocation() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let recorder = DataMapRecorder()
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "snapshot raw launchers") { layout in
                for name in ["sol", "solstone"] {
                    recorder.record(try Data(contentsOf: Self.materializedTool(named: name, in: layout)), for: name)
                }
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        for name in ["sol", "solstone"] {
            let relocated = runtime.layout.binDir.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            #expect(try Data(contentsOf: relocated) == recorder.data(for: name))
        }
    }

    @Test func materializeClassifiesMalformedPolyglotLikeScriptAsRawAndDoesNotRewrite() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let recorder = DataMapRecorder()
        let malformed = Data("""
        #!/bin/sh
        '''exec' /not/a/uv/trampoline "$0" "$@"
        echo "almost"

        """.utf8)
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "write malformed exported entry") { layout in
                let solstone = Self.materializedTool(named: "solstone", in: layout)
                try malformed.write(to: solstone)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: solstone.path)
                recorder.record(malformed, for: "solstone")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        let relocated = runtime.layout.binDir.appendingPathComponent("solstone").resolvingSymlinksInPath().standardizedFileURL
        #expect(try Data(contentsOf: relocated) == recorder.data(for: "solstone"))
    }

    @Test func materializeProbesRequiredRawSolAndPolyglotJournalEntrypoints() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        _ = try await materializer.materialize(excludingLiveKey: nil)

        let versionInvocations = runner.invocations.filter { $0.arguments == ["--version"] }
        #expect(versionInvocations.filter { $0.executable.lastPathComponent == "sol" }.count == 1)
        #expect(versionInvocations.filter { $0.executable.lastPathComponent == "journal" }.count == 2)
        #expect(!versionInvocations.contains { $0.executable.lastPathComponent == "solstone" })
    }

    @Test func materializeFailsWhenExportedEntryDangles() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let expected = StringRecorder()
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "create dangling exported entry") { layout in
                let entry = layout.binDir.appendingPathComponent("ghost")
                let target = Self.materializedTool(named: "ghost", in: layout)
                try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: target.path)
                expected.record("entrypoint ghost target missing or dangling: \(entry.resolvingSymlinksInPath().standardizedFileURL.path)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        try await expectMaterializeVerificationFailure(materializer, expected: expected)
    }

    @Test func materializeFailsWhenExportedEntryEscapesStagingByAbsolutePath() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let expected = StringRecorder()
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "create absolute escape") { layout in
                let outside = fixture.workspace.appendingPathComponent("outside-absolute")
                try Self.writeExecutableShell(at: outside, body: "echo outside\n")
                let entry = layout.binDir.appendingPathComponent("absolute-escape")
                try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: outside.path)
                expected.record("entrypoint absolute-escape symlink target escapes staging root: \(outside.path)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        try await expectMaterializeVerificationFailure(materializer, expected: expected)
    }

    @Test func materializeFailsWhenExportedEntryEscapesStagingWithDotDot() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let expected = StringRecorder()
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "create dot-dot escape") { layout in
                let outside = fixture.runtimeRoot.appendingPathComponent("outside-dotdot")
                try Self.writeExecutableShell(at: outside, body: "echo outside\n")
                let rawDestination = layout.rootURL.path + "/../outside-dotdot"
                let entry = layout.binDir.appendingPathComponent("dotdot-escape")
                try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: rawDestination)
                expected.record("entrypoint dotdot-escape symlink target escapes staging root: \(rawDestination)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        try await expectMaterializeVerificationFailure(materializer, expected: expected)
    }

    @Test func materializeFailsWhenExportedEntryEscapesStagingThroughSymlinkChain() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let expected = StringRecorder()
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "create symlink-chain escape") { layout in
                let outsideDir = fixture.workspace.appendingPathComponent("outside-chain", isDirectory: true)
                try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
                try Self.writeExecutableShell(at: outsideDir.appendingPathComponent("chain-escape"), body: "echo outside\n")
                let link = layout.toolsDir.appendingPathComponent("escape-link")
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outsideDir.path)
                let rawDestination = link.path + "/chain-escape"
                let entry = layout.binDir.appendingPathComponent("chain-escape")
                try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: rawDestination)
                expected.record("entrypoint chain-escape symlink target escapes staging root: \(rawDestination)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        try await expectMaterializeVerificationFailure(materializer, expected: expected)
    }

    @Test func materializeFailsWhenExportedEntryIsNotSymlink() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let expected = StringRecorder()
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "create non-symlink exported entry") { layout in
                let entry = layout.binDir.appendingPathComponent("not-symlink")
                try Self.writeExecutableShell(at: entry, body: "echo regular\n")
                expected.record("entrypoint not-symlink is not a symlink: \(entry.path)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        try await expectMaterializeVerificationFailure(materializer, expected: expected)
    }

    @Test func materializeFailsWhenRelocatedEntryHasAbsoluteDestination() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let outside = fixture.workspace.appendingPathComponent("outside-relocated-absolute")
        try Self.writeExecutableShell(at: outside, body: "echo absolute\n")
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "create entry for absolute relocation") { layout in
                let target = Self.materializedTool(named: "absolute-after-relocation", in: layout)
                try Self.writeExecutableShell(at: target, body: "echo absolute\n")
                let entry = layout.binDir.appendingPathComponent("absolute-after-relocation")
                try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: target.path)
            }
        }
        let fileManager = AbsoluteRelocationFileManager(
            absoluteLeafName: "absolute-after-relocation",
            absoluteDestination: outside
        )
        let materializer = makeMaterializer(fixture: fixture, runner: runner, fileManager: fileManager)

        let expected = StringRecorder("entrypoint absolute-after-relocation is not a relative symlink after relocation: \(outside.path)")
        try await expectMaterializeVerificationFailure(materializer, expected: expected)
    }

    @Test func materializeRollsBackFinalGenerationWhenPostRenameProbeFails() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let priorKey = "0.1.0_py20240101_8888888888888888"
        let orphanKey = "0.1.0_py20240101_9999999999999999"
        try createDirectories([priorKey, orphanKey], in: fixture.runtimeRoot)
        try writeExternalScript(named: "sol", in: fixture.wrapperDir, body: "external sol\n", mode: 0o755)
        try writeExternalScript(named: "journal", in: fixture.wrapperDir, body: "external journal\n", mode: 0o755)
        let aliasSnapshots = try snapshotAliases(["sol", "journal"], in: fixture.wrapperDir)
        let runner = FakeSubprocessRunner()
        runner.preferQueuedVersionResponses = true
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        let wrongVersion = Data("solstone 0.0.0\n".utf8)
        runner.enqueue("--version", .success(stdout: wrongVersion, exitCode: 1))
        runner.enqueue("--version", .success(stdout: wrongVersion, exitCode: 1))
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail on post-rename probe")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed(let message) = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
            let expectedMessages = [
                "entrypoint journal did not execute and report the pinned version after relocation: exit=1 parsed=0.0.0",
                "entrypoint sol did not execute and report the pinned version after relocation: exit=1 parsed=0.0.0"
            ]
            #expect(expectedMessages.contains(message))
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }

        try assertAliasSnapshotsUnchanged(aliasSnapshots, in: fixture.wrapperDir)
        let runtimeChildren = try FileManager.default.contentsOfDirectory(atPath: fixture.runtimeRoot.path)
        #expect(!runtimeChildren.contains { $0.hasPrefix(".tmp-") })
        #expect(Set(runtimeChildren) == Set([priorKey, orphanKey]))
        #expect(directoryExists(priorKey, in: fixture.runtimeRoot))
        #expect(directoryExists(orphanKey, in: fixture.runtimeRoot))
    }

    @Test func installPassesLeafWheelAndSolstoneExecutablesToUvToolInstall() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        _ = try await materializer.materialize(excludingLiveKey: nil)

        let install = try #require(runner.invocations.first {
            $0.arguments.starts(with: ["tool", "install"])
        })
        // exact adjacent flag+value pair, so a malformed flag cannot pass
        let pairIndex = install.arguments.indices.first { i in
            i + 1 < install.arguments.count
                && install.arguments[i] == "--with-executables-from"
                && install.arguments[i + 1] == "solstone"
        }
        #expect(pairIndex != nil)
        let spec = try #require(install.arguments.dropFirst(2).first)
        let retiredJournalExtra = "[" + "journal" + "]"
        #expect(URL(fileURLWithPath: spec).lastPathComponent.hasPrefix("solstone_journal-\(BundleConfig.solstonePinVersion)-"))
        #expect(!spec.contains(retiredJournalExtra))
        #expect(Array(install.arguments.dropFirst(3)) == [
            "--with-executables-from",
            "solstone",
            "--find-links",
            fixture.wheelhouse.path,
            "--no-index",
            "--offline",
            "--python",
            fixture.bundledPython.path,
            "--no-python-downloads",
            "--force"
        ])
    }

    @Test func materializeCreatesAbsentAliasesForBothNames() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let recorder = AliasEventRecorder()
        let materializer = makeMaterializer(fixture: fixture, runner: runner, aliasLogSink: { recorder.record($0) })

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        for alias in aliasTargets(for: runtime) {
            try assertManagedWrapper(named: alias.name, in: fixture.wrapperDir, target: alias.target)
        }
        #expect(recorder.events.filter { $0.outcome == .created }.map(\.alias).sorted() == ["journal", "sol"])
    }

    @Test func materializeRefreshesOldAppOwnedAliasesForBothNamesAndCollectsOldGeneration() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let oldKey = "0.1.0_py20240101_aaaaaaaaaaaaaaaa"
        let oldLayout = try createRuntimeGeneration(oldKey, in: fixture.runtimeRoot)
        try writeManagedWrapper(named: "sol", in: fixture.wrapperDir, target: oldLayout.solBinary)
        try writeManagedWrapper(named: "journal", in: fixture.wrapperDir, target: oldLayout.journalBinary)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        for alias in aliasTargets(for: runtime) {
            try assertManagedWrapper(named: alias.name, in: fixture.wrapperDir, target: alias.target)
        }
        #expect(!directoryExists(oldKey, in: fixture.runtimeRoot))
    }

    @Test func materializeCurrentAliasesAreTrueNoopByMtimeSentinel() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)
        let runtime = try await materializer.materialize(excludingLiveKey: nil)
        let sentinel = Date(timeIntervalSince1970: 1_700_000_000)
        for alias in aliasTargets(for: runtime) {
            try FileManager.default.setAttributes(
                [.modificationDate: sentinel],
                ofItemAtPath: wrapperURL(named: alias.name, in: fixture.wrapperDir).path
            )
        }
        let before = try aliasTargets(for: runtime).map { alias in
            (alias.name, try modificationDate(of: wrapperURL(named: alias.name, in: fixture.wrapperDir)))
        }

        _ = try await materializer.materialize(excludingLiveKey: nil)

        let after = try aliasTargets(for: runtime).map { alias in
            (alias.name, try modificationDate(of: wrapperURL(named: alias.name, in: fixture.wrapperDir)))
        }
        #expect(before.map(\.0) == after.map(\.0))
        #expect(before.map(\.1) == after.map(\.1))
    }

    @Test func materializePreservesPlainExternalScriptsForBothNamesAndStillReturnsRuntime() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try writeExternalScript(named: "sol", in: fixture.wrapperDir, body: "external sol\n", mode: 0o744)
        try writeExternalScript(named: "journal", in: fixture.wrapperDir, body: "external journal\n", mode: 0o700)
        let before = try snapshotAliases(["sol", "journal"], in: fixture.wrapperDir)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let recorder = AliasEventRecorder()
        let materializer = makeMaterializer(fixture: fixture, runner: runner, aliasLogSink: { recorder.record($0) })

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        try assertAliasSnapshotsUnchanged(before, in: fixture.wrapperDir)
        #expect(runtime.layout.solBinary.path == runtime.layout.rootURL.appendingPathComponent("bin/sol").path)
        #expect(runtime.layout.journalBinary.path == runtime.layout.rootURL.appendingPathComponent("bin/journal").path)
        assertSkippedAliasEvents(recorder.events, aliases: ["journal", "sol"], reason: .unmarked)
    }

    @Test func materializePreservesExternalSymlinkLeavesAndTargets() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let externalDir = fixture.workspace.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let solTarget = externalDir.appendingPathComponent("sol")
        let journalTarget = externalDir.appendingPathComponent("journal")
        try Data("external sol target\n".utf8).write(to: solTarget)
        try Data("external journal target\n".utf8).write(to: journalTarget)
        try FileManager.default.createDirectory(at: fixture.wrapperDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: wrapperURL(named: "sol", in: fixture.wrapperDir).path, withDestinationPath: solTarget.path)
        try FileManager.default.createSymbolicLink(atPath: wrapperURL(named: "journal", in: fixture.wrapperDir).path, withDestinationPath: journalTarget.path)
        let before = try symlinkSnapshots(["sol", "journal"], in: fixture.wrapperDir)
        let targetBytes = try [solTarget, journalTarget].map { try Data(contentsOf: $0) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let recorder = AliasEventRecorder()
        let materializer = makeMaterializer(fixture: fixture, runner: runner, aliasLogSink: { recorder.record($0) })

        _ = try await materializer.materialize(excludingLiveKey: nil)

        try assertSymlinkSnapshotsUnchanged(before, in: fixture.wrapperDir)
        #expect(try Data(contentsOf: solTarget) == targetBytes[0])
        #expect(try Data(contentsOf: journalTarget) == targetBytes[1])
        assertSkippedAliasEvents(recorder.events, aliases: ["journal", "sol"], reason: .symlink)
    }

    @Test func materializeTreatsNoncanonicalMarkerBodiesAsExternalForBothNames() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let target = fixture.runtimeRoot.appendingPathComponent("0.1.0_py20240101_bbbbbbbbbbbbbbbb/bin/sol").path
        for name in ["sol", "journal"] {
            try writeExternalScript(
                named: name,
                in: fixture.wrapperDir,
                body: "#!/bin/sh\n\(ManagedWrapper.appOwnedChildMarker)\necho nope\nexec \(ManagedWrapper.shellSingleQuoted(target)) \"$@\"\n",
                mode: 0o755
            )
        }
        let before = try snapshotAliases(["sol", "journal"], in: fixture.wrapperDir)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let recorder = AliasEventRecorder()
        let materializer = makeMaterializer(fixture: fixture, runner: runner, aliasLogSink: { recorder.record($0) })

        _ = try await materializer.materialize(excludingLiveKey: nil)

        try assertAliasSnapshotsUnchanged(before, in: fixture.wrapperDir)
        assertSkippedAliasEvents(recorder.events, aliases: ["journal", "sol"], reason: .noncanonicalBody)
    }

    @Test func materializeTreatsDecodeFailuresAsExternalAndStillReturnsRuntime() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try FileManager.default.createDirectory(at: fixture.wrapperDir, withIntermediateDirectories: true)
        for name in ["sol", "journal"] {
            let url = wrapperURL(named: name, in: fixture.wrapperDir)
            try Data([0xFF, 0x00, 0xFE]).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let before = try snapshotAliases(["sol", "journal"], in: fixture.wrapperDir)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let recorder = AliasEventRecorder()
        let materializer = makeMaterializer(fixture: fixture, runner: runner, aliasLogSink: { recorder.record($0) })

        _ = try await materializer.materialize(excludingLiveKey: nil)

        try assertAliasSnapshotsUnchanged(before, in: fixture.wrapperDir)
        assertSkippedAliasEvents(recorder.events, aliases: ["journal", "sol"], reason: .decodeError)
    }

    @Test func materializeLeavesUnreadableRegularWrappersUntouched() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try writeExternalScript(named: "sol", in: fixture.wrapperDir, body: "external sol\n", mode: 0o600)
        try writeExternalScript(named: "journal", in: fixture.wrapperDir, body: "external journal\n", mode: 0o600)
        let before = try snapshotAliases(["sol", "journal"], in: fixture.wrapperDir)
        for name in ["sol", "journal"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: wrapperURL(named: name, in: fixture.wrapperDir).path
            )
        }
        defer {
            for name in ["sol", "journal"] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: wrapperURL(named: name, in: fixture.wrapperDir).path
                )
            }
        }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        _ = try await materializer.materialize(excludingLiveKey: nil)

        for name in ["sol", "journal"] {
            #expect(try permissions(of: wrapperURL(named: name, in: fixture.wrapperDir)) == 0o000)
        }
        for snapshot in before {
            let url = wrapperURL(named: snapshot.name, in: fixture.wrapperDir)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #expect(try Data(contentsOf: url) == snapshot.data)
        }
    }

    @Test func materializeTreatsNonRegularLeavesAsExternalAndSkipsGenerationGC() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let orphanKey = "0.1.0_py20240101_cccccccccccccccc"
        try createDirectories([orphanKey], in: fixture.runtimeRoot)
        try FileManager.default.createDirectory(at: wrapperURL(named: "sol", in: fixture.wrapperDir), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.wrapperDir, withIntermediateDirectories: true)
        let fifo = wrapperURL(named: "journal", in: fixture.wrapperDir)
        #expect(Darwin.mkfifo(fifo.path, 0o644) == 0)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let recorder = AliasEventRecorder()
        let materializer = makeMaterializer(fixture: fixture, runner: runner, aliasLogSink: { recorder.record($0) })

        _ = try await materializer.materialize(excludingLiveKey: nil)

        #expect(directoryExists("sol", in: fixture.wrapperDir))
        #expect(isFIFO(fifo))
        #expect(directoryExists(orphanKey, in: fixture.runtimeRoot))
        assertSkippedAliasEvents(recorder.events, aliases: ["journal", "sol"], reason: .notRegularFile)
    }

    @Test func materializeReturnsRuntimeWhenLeafMetadataFails() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try writeExternalScript(named: "sol", in: fixture.wrapperDir, body: "external sol\n", mode: 0o755)
        try writeExternalScript(named: "journal", in: fixture.wrapperDir, body: "external journal\n", mode: 0o755)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.wrapperDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.wrapperDir.path) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let recorder = AliasEventRecorder()
        let materializer = makeMaterializer(fixture: fixture, runner: runner, aliasLogSink: { recorder.record($0) })

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        #expect(runtime.layout.rootURL.path.hasPrefix(fixture.runtimeRoot.path))
        assertSkippedAliasEvents(recorder.events, aliases: ["journal", "sol"], reason: .metadataError)
    }

    @Test func materializeHandlesMixedOwnershipOnFreshAndReusePaths() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try writeExternalScript(named: "sol", in: fixture.wrapperDir, body: "external sol\n", mode: 0o755)
        let externalSol = try snapshotAliases(["sol"], in: fixture.wrapperDir)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        try assertAliasSnapshotsUnchanged(externalSol, in: fixture.wrapperDir)
        try assertManagedWrapper(named: "journal", in: fixture.wrapperDir, target: runtime.layout.journalBinary)

        let oldKey = "0.1.0_py20240101_dddddddddddddddd"
        let oldLayout = try createRuntimeGeneration(oldKey, in: fixture.runtimeRoot)
        try writeManagedWrapper(named: "journal", in: fixture.wrapperDir, target: oldLayout.journalBinary)

        _ = try await materializer.materialize(excludingLiveKey: nil)

        try assertAliasSnapshotsUnchanged(externalSol, in: fixture.wrapperDir)
        try assertManagedWrapper(named: "journal", in: fixture.wrapperDir, target: runtime.layout.journalBinary)
    }

    @Test func materializeRepairsCanonicalWrappersAtWrongMode() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)
        let runtime = try await materializer.materialize(excludingLiveKey: nil)
        for alias in aliasTargets(for: runtime) {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wrapperURL(named: alias.name, in: fixture.wrapperDir).path)
        }

        _ = try await materializer.materialize(excludingLiveKey: nil)

        for alias in aliasTargets(for: runtime) {
            try assertManagedWrapper(named: alias.name, in: fixture.wrapperDir, target: alias.target, mode: 0o755)
        }
    }

    @Test func materializeInjectedModeFailureLeavesPriorBytesAndMode() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)
        let runtime = try await materializer.materialize(excludingLiveKey: nil)
        for alias in aliasTargets(for: runtime) {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wrapperURL(named: alias.name, in: fixture.wrapperDir).path)
        }
        let before = try snapshotAliases(["sol", "journal"], in: fixture.wrapperDir)
        let failingMaterializer = makeMaterializer(
            fixture: fixture,
            runner: runner,
            fileManager: AttributeFailingFileManager()
        )

        _ = try await failingMaterializer.materialize(excludingLiveKey: nil)

        try assertAliasSnapshotsUnchanged(before, in: fixture.wrapperDir)
    }

    @Test func materializePinsFailedSiblingOldGenerationWhileCollectingUnreferencedOrphan() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let oldKey = "0.1.0_py20240101_3333333333333333"
        let orphanKey = "0.1.0_py20240101_4444444444444444"
        let oldLayout = try createRuntimeGeneration(oldKey, in: fixture.runtimeRoot)
        try createDirectories([orphanKey], in: fixture.runtimeRoot)
        try writeManagedWrapper(named: "sol", in: fixture.wrapperDir, target: oldLayout.solBinary, mode: 0o755)
        try writeManagedWrapper(named: "journal", in: fixture.wrapperDir, target: oldLayout.journalBinary, mode: 0o744)
        let priorJournal = try snapshotAliases(["journal"], in: fixture.wrapperDir)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let recorder = AliasEventRecorder()
        let materializer = makeMaterializer(
            fixture: fixture,
            runner: runner,
            fileManager: AttributeFailingFileManager(failingLeafNames: ["journal"]),
            aliasLogSink: { recorder.record($0) }
        )

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        try assertManagedWrapper(named: "sol", in: fixture.wrapperDir, target: runtime.layout.solBinary)
        #expect(directoryExists(runtime.key, in: fixture.runtimeRoot))
        try assertAliasSnapshotsUnchanged(priorJournal, in: fixture.wrapperDir)
        let journalData = try Data(contentsOf: wrapperURL(named: "journal", in: fixture.wrapperDir))
        #expect(ManagedWrapper.canonicalTarget(fromExactScriptData: journalData) == oldLayout.journalBinary.path)
        #expect(directoryExists(oldKey, in: fixture.runtimeRoot))
        #expect(!directoryExists(orphanKey, in: fixture.runtimeRoot))
        #expect(recorder.events.contains {
            $0.alias == "sol" && $0.decision == .appOwned && $0.outcome == .refreshed
        })
        #expect(recorder.events.contains {
            $0.alias == "journal"
                && $0.decision == .appOwned
                && $0.outcome == .error
                && $0.reason == .modeError
        })
    }

    @Test func materializePinsOldGenerationReferencedByExternalScript() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let oldKey = "0.1.0_py20240101_eeeeeeeeeeeeeeee"
        let orphanKey = "0.1.0_py20240101_ffffffffffffffff"
        let oldLayout = try createRuntimeGeneration(oldKey, in: fixture.runtimeRoot)
        try createDirectories([orphanKey], in: fixture.runtimeRoot)
        try writeExternalScript(named: "sol", in: fixture.wrapperDir, body: "#!\(oldLayout.solBinary.path)\n", mode: 0o755)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        #expect(directoryExists(oldKey, in: fixture.runtimeRoot))
        #expect(!directoryExists(orphanKey, in: fixture.runtimeRoot))
        try assertManagedWrapper(named: "journal", in: fixture.wrapperDir, target: runtime.layout.journalBinary)
        #expect(try Data(contentsOf: oldLayout.solBinary) == Data("runtime sol\n".utf8))
    }

    @Test func materializePinsGenerationReferencesTerminatedByShellPunctuation() async throws {
        let fixture = try makeMaterializerFixture(runtimeRootComponents: ["runtime"])
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let pathKey = "0.1.0_py20240101_5555555555555555"
        let cdKey = "0.1.0_py20240101_6666666666666666"
        let orphanKey = "0.1.0_py20240101_7777777777777777"
        let pathLayout = try createRuntimeGeneration(pathKey, in: fixture.runtimeRoot)
        let cdLayout = try createRuntimeGeneration(cdKey, in: fixture.runtimeRoot)
        try createDirectories([orphanKey], in: fixture.runtimeRoot)
        try writeExternalScript(
            named: "sol",
            in: fixture.wrapperDir,
            body: "PATH=\(pathLayout.rootURL.path):$PATH\nexec /usr/bin/env sol \"$@\"\n",
            mode: 0o755
        )
        try writeExternalScript(
            named: "journal",
            in: fixture.wrapperDir,
            body: "cd \(cdLayout.rootURL.path); exec ./bin/journal \"$@\"\n",
            mode: 0o755
        )
        let before = try snapshotAliases(["sol", "journal"], in: fixture.wrapperDir)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        _ = try await materializer.materialize(excludingLiveKey: nil)

        try assertAliasSnapshotsUnchanged(before, in: fixture.wrapperDir)
        #expect(directoryExists(pathKey, in: fixture.runtimeRoot))
        #expect(directoryExists(cdKey, in: fixture.runtimeRoot))
        #expect(!directoryExists(orphanKey, in: fixture.runtimeRoot))
    }

    @Test func materializePinsOldGenerationReferencedBySymlinkResolution() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let oldKey = "0.1.0_py20240101_1111111111111111"
        let orphanKey = "0.1.0_py20240101_2222222222222222"
        let oldLayout = try createRuntimeGeneration(oldKey, in: fixture.runtimeRoot)
        try createDirectories([orphanKey], in: fixture.runtimeRoot)
        try FileManager.default.createDirectory(at: fixture.wrapperDir, withIntermediateDirectories: true)
        let relative = try relativePath(from: fixture.wrapperDir, to: oldLayout.solBinary)
        try FileManager.default.createSymbolicLink(atPath: wrapperURL(named: "sol", in: fixture.wrapperDir).path, withDestinationPath: relative)
        let before = try symlinkSnapshots(["sol"], in: fixture.wrapperDir)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        _ = try await materializer.materialize(excludingLiveKey: nil)

        try assertSymlinkSnapshotsUnchanged(before, in: fixture.wrapperDir)
        #expect(directoryExists(oldKey, in: fixture.runtimeRoot))
        #expect(!directoryExists(orphanKey, in: fixture.runtimeRoot))
    }

    @Test func materializeFailsWhenLeafWheelMissing() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try FileManager.default.removeItem(at: fixture.wheelhouse.appendingPathComponent(leafWheelName()))

        try await expectWheelhouseInvalid(
            fixture: fixture,
            containing: "expected exactly one solstone_journal-\(BundleConfig.solstonePinVersion)-*.whl, found 0"
        )
    }

    @Test func materializeFailsWhenLeafWheelDuplicated() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try writeWheel(named: "solstone_journal-\(BundleConfig.solstonePinVersion)-2-py3-none-any.whl", in: fixture.wheelhouse)

        try await expectWheelhouseInvalid(
            fixture: fixture,
            containing: "expected exactly one solstone_journal-\(BundleConfig.solstonePinVersion)-*.whl, found 2"
        )
    }

    @Test func materializeFailsWhenModelsWheelMissing() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try FileManager.default.removeItem(at: fixture.wheelhouse.appendingPathComponent(modelsWheelName()))

        try await expectWheelhouseInvalid(
            fixture: fixture,
            containing: "expected exactly one solstone_journal_models-*.whl, found 0"
        )
    }

    @Test func materializeFailsWhenModelsWheelDuplicated() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try writeWheel(named: "solstone_journal_models-1.0.1-py3-none-any.whl", in: fixture.wheelhouse)

        try await expectWheelhouseInvalid(
            fixture: fixture,
            containing: "expected exactly one solstone_journal_models-*.whl, found 2"
        )
    }

    @Test func materializeStillFailsWhenSolstoneWheelMissing() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try FileManager.default.removeItem(at: fixture.wheelhouse.appendingPathComponent(solstoneWheelName()))

        try await expectWheelhouseInvalid(
            fixture: fixture,
            containing: "expected exactly one solstone-\(BundleConfig.solstonePinVersion)-*.whl, found 0"
        )
    }

    @Test func materializeStillFailsWhenSolstoneWheelDuplicated() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        try writeWheel(named: "solstone-\(BundleConfig.solstonePinVersion)-2-py3-none-any.whl", in: fixture.wheelhouse)

        try await expectWheelhouseInvalid(
            fixture: fixture,
            containing: "expected exactly one solstone-\(BundleConfig.solstonePinVersion)-*.whl, found 2"
        )
    }

    @Test func materializeFailsClosedWhenSolExecutableMissing() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let expected = StringRecorder()
        runner.materializedExposureOverride = ["journal", "mlx-vlm-server"]
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "record missing sol path") { layout in
                let rawTempRoot = fixture.runtimeRoot.appendingPathComponent(layout.rootURL.lastPathComponent, isDirectory: true)
                expected.record("sol executable missing at \(SolstoneRuntimeLayout(rootURL: rawTempRoot).solBinary.path)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail when sol executable is missing")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed(let message) = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
            #expect(message == (try expected.require()))
            #expect(message != "staged runtime verification failed")
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
    }

    @Test func materializeInstallTimeoutSurfacesDistinctReasonQuickly() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let timeout: Duration = .milliseconds(20)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success(delay: timeout))
        let materializer = makeMaterializer(fixture: fixture, runner: runner, installTimeout: timeout)

        let started = Date()
        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail on install timeout")
        } catch let error as RuntimeMaterializerError {
            guard case .installFailed(let message) = error else {
                Issue.record("expected installFailed, got \(error)")
                return
            }
            #expect(message.hasPrefix("journal runtime install timed out"))
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func materializeVersionTimeoutSurfacesDistinctReasonQuickly() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let timeout: Duration = .milliseconds(20)
        let runner = FakeSubprocessRunner()
        runner.preferQueuedVersionResponses = true
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(delay: timeout))
        let materializer = makeMaterializer(fixture: fixture, runner: runner, verifyTimeout: timeout)

        let started = Date()
        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail on version timeout")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed(let message) = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
            #expect(message.hasPrefix("journal runtime version check timed out"))
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func materializeHostImportTimeoutSurfacesDistinctReasonQuickly() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let timeout: Duration = .milliseconds(20)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        runner.enqueue("-c", .success(delay: timeout))
        let materializer = makeMaterializer(fixture: fixture, runner: runner, verifyTimeout: timeout)

        let started = Date()
        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail on host import timeout")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed(let message) = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
            #expect(message.hasPrefix("journal runtime host import check timed out"))
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func materializePythonTimeoutSurfacesDistinctReasonQuickly() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let timeout: Duration = .milliseconds(20)
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        runner.enqueue("-c", .success())
        runner.enqueue("-c", .success(delay: timeout))
        let materializer = makeMaterializer(fixture: fixture, runner: runner, verifyTimeout: timeout)

        let started = Date()
        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail on python timeout")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed(let message) = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
            #expect(message.hasPrefix("journal runtime python check timed out"))
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test func materializeSurfacesSpecificReasonWhenJournalExecutableMissing() async throws {
        let fixture = try makeMaterializerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        let expected = StringRecorder()
        runner.materializedExposureOverride = ["sol", "solstone"]
        runner.enqueue("tool", .success())
        runner.onMaterializedToolBinaries {
            Self.withStagedLayout(runtimeRoot: fixture.runtimeRoot, operation: "record missing journal path") { layout in
                let rawTempRoot = fixture.runtimeRoot.appendingPathComponent(layout.rootURL.lastPathComponent, isDirectory: true)
                expected.record("journal executable missing at \(SolstoneRuntimeLayout(rootURL: rawTempRoot).journalBinary.path)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail when journal executable is missing")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed(let message) = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
            #expect(message == (try expected.require()))
            #expect(message != "staged runtime verification failed")
        }
    }

    private func createDirectories(_ names: [String], in root: URL) throws {
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func directoryExists(_ name: String, in root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: root.appendingPathComponent(name, isDirectory: true).path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    private func aliasTargets(for runtime: MaterializedRuntime) -> [(name: String, target: URL)] {
        [
            ("sol", runtime.layout.solBinary),
            ("journal", runtime.layout.journalBinary)
        ]
    }

    private func wrapperURL(named name: String, in wrapperDir: URL) -> URL {
        wrapperDir.appendingPathComponent(name)
    }

    private func writeManagedWrapper(named name: String, in wrapperDir: URL, target: URL, mode: Int = 0o755) throws {
        let url = wrapperURL(named: name, in: wrapperDir)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try ManagedWrapper.canonicalScriptData(forTarget: target.path).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func writeExternalScript(named name: String, in wrapperDir: URL, body: String, mode: Int) throws {
        let url = wrapperURL(named: name, in: wrapperDir)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func assertManagedWrapper(named name: String, in wrapperDir: URL, target: URL, mode: Int = 0o755) throws {
        let url = wrapperURL(named: name, in: wrapperDir)
        #expect(try Data(contentsOf: url) == ManagedWrapper.canonicalScriptData(forTarget: target.path))
        #expect(try permissions(of: url) == mode)
    }

    private struct AliasSnapshot: Equatable {
        let name: String
        let data: Data
        let mode: Int
    }

    private func snapshotAliases(_ names: [String], in wrapperDir: URL) throws -> [AliasSnapshot] {
        try names.map { name in
            let url = wrapperURL(named: name, in: wrapperDir)
            return AliasSnapshot(name: name, data: try Data(contentsOf: url), mode: try permissions(of: url))
        }
    }

    private func assertAliasSnapshotsUnchanged(_ snapshots: [AliasSnapshot], in wrapperDir: URL) throws {
        for snapshot in snapshots {
            let url = wrapperURL(named: snapshot.name, in: wrapperDir)
            #expect(try Data(contentsOf: url) == snapshot.data)
            #expect(try permissions(of: url) == snapshot.mode)
        }
    }

    private func assertSkippedAliasEvents(
        _ events: [RuntimeAliasLogEvent],
        aliases: [String],
        reason: ManagedWrapper.AliasReason
    ) {
        let skipped = events.filter { $0.outcome == .skipped }.sorted { $0.alias < $1.alias }
        #expect(skipped.map(\.alias) == aliases.sorted())
        #expect(skipped.allSatisfy { $0.decision == .external && $0.reason == reason })
    }

    private struct SymlinkSnapshot: Equatable {
        let name: String
        let inode: UInt64
        let destination: String
    }

    private func symlinkSnapshots(_ names: [String], in wrapperDir: URL) throws -> [SymlinkSnapshot] {
        try names.map { name in
            let url = wrapperURL(named: name, in: wrapperDir)
            return SymlinkSnapshot(
                name: name,
                inode: try inodeOfLeaf(url),
                destination: try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            )
        }
    }

    private func assertSymlinkSnapshotsUnchanged(_ snapshots: [SymlinkSnapshot], in wrapperDir: URL) throws {
        for snapshot in snapshots {
            let url = wrapperURL(named: snapshot.name, in: wrapperDir)
            #expect(try inodeOfLeaf(url) == snapshot.inode)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == snapshot.destination)
        }
    }

    private func createRuntimeGeneration(_ key: String, in root: URL) throws -> SolstoneRuntimeLayout {
        let layout = SolstoneRuntimeLayout(rootURL: root.appendingPathComponent(key, isDirectory: true))
        try FileManager.default.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        try Data("runtime sol\n".utf8).write(to: layout.solBinary)
        try Data("runtime journal\n".utf8).write(to: layout.journalBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.solBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.journalBinary.path)
        return layout
    }

    private func permissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attrs[.posixPermissions] as? NSNumber).intValue & 0o7777
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attrs[.modificationDate] as? Date)
    }

    private func inodeOfLeaf(_ url: URL) throws -> UInt64 {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return metadata.st_ino
    }

    private func isFIFO(_ url: URL) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFIFO
    }

    private func relativePath(from base: URL, to target: URL) throws -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < baseComponents.count,
              commonCount < targetComponents.count,
              baseComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }
        let ups = Array(repeating: "..", count: baseComponents.count - commonCount)
        let downs = Array(targetComponents.dropFirst(commonCount))
        let components = ups + downs
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    private func expectWheelhouseInvalid(
        fixture: (
            workspace: URL,
            runtimeRoot: URL,
            wheelhouse: URL,
            wrapperDir: URL,
            bundledPython: URL
        ),
        containing expected: String
    ) async throws {
        let runner = FakeSubprocessRunner()
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail with wheelhouseInvalid")
        } catch let error as RuntimeMaterializerError {
            guard case .wheelhouseInvalid(let message) = error else {
                Issue.record("expected wheelhouseInvalid, got \(error)")
                return
            }
            #expect(message.contains(expected))
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
    }

    private func solstoneWheelName() -> String {
        "solstone-\(BundleConfig.solstonePinVersion)-py3-none-any.whl"
    }

    private func leafWheelName() -> String {
        "solstone_journal-\(BundleConfig.solstonePinVersion)-py3-none-any.whl"
    }

    private func modelsWheelName() -> String {
        "solstone_journal_models-1.0.0-py3-none-any.whl"
    }

    private func writeWheel(named name: String, in wheelhouse: URL) throws {
        try Data("wheel\n".utf8).write(to: wheelhouse.appendingPathComponent(name))
    }

    private func makeMaterializerFixture(runtimeRootComponents: [String] = ["runtime dir with space and ' quote"]) throws -> (
        workspace: URL,
        runtimeRoot: URL,
        wheelhouse: URL,
        wrapperDir: URL,
        bundledPython: URL
    ) {
        let workspace = try makeTemporaryDirectory()
        let runtimeRoot = runtimeRootComponents.reduce(workspace) { root, component in
            root.appendingPathComponent(component, isDirectory: true)
        }
        let wheelhouse = workspace.appendingPathComponent("wheelhouse", isDirectory: true)
        let wrapperDir = workspace.appendingPathComponent("wrappers", isDirectory: true)
        let bundledPython = workspace
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3.13")
        try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("manifest\n".utf8).write(to: wheelhouse.appendingPathComponent("MANIFEST.sha256"))
        try writeWheel(named: solstoneWheelName(), in: wheelhouse)
        try writeWheel(named: leafWheelName(), in: wheelhouse)
        try writeWheel(named: modelsWheelName(), in: wheelhouse)
        try Data([0xFF, 0x00, 0xFE]).write(to: bundledPython)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledPython.path)
        return (workspace, runtimeRoot, wheelhouse, wrapperDir, bundledPython)
    }

    private func makeMaterializer(
        fixture: (
            workspace: URL,
            runtimeRoot: URL,
            wheelhouse: URL,
            wrapperDir: URL,
            bundledPython: URL
        ),
        runner: FakeSubprocessRunner,
        installTimeout: Duration = .seconds(180),
        verifyTimeout: Duration = .seconds(120),
        fileManager: FileManager = .default,
        aliasLogSink: (@Sendable (RuntimeAliasLogEvent) -> Void)? = nil
    ) -> RuntimeMaterializer {
        RuntimeMaterializer(
            runtimeRootURL: fixture.runtimeRoot,
            uvBinaryURL: URL(fileURLWithPath: "/usr/bin/uv"),
            bundledPythonURL: fixture.bundledPython,
            wheelhouseURL: fixture.wheelhouse,
            wrapperDirURL: fixture.wrapperDir,
            installTimeout: installTimeout,
            verifyTimeout: verifyTimeout,
            runner: runner,
            fileManager: fileManager,
            aliasLogSink: aliasLogSink
        )
    }

    private func assertRelocatedExportedEntry(named name: String, in runtime: MaterializedRuntime, rootPath: String) throws {
        let entry = runtime.layout.binDir.appendingPathComponent(name)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        #expect(!destination.hasPrefix("/"))
        #expect(!pathContainsStagingSegment(destination))
        let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(FileManager.default.isExecutableFile(atPath: resolved.path))
        #expect(pathIsUnderRoot(resolved.path, rootPath: rootPath))
        #expect(!pathContainsStagingSegment(resolved.path))
    }

    private func assertRelocatedUvPolyglotEntry(named name: String, in runtime: MaterializedRuntime) throws {
        let resolved = runtime.layout.binDir.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        let script = try String(contentsOf: resolved, encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        #expect(lines.first == "#!/bin/sh")
        guard lines.count >= 2 else {
            Issue.record("exported entry \(name) missing uv trampoline line")
            return
        }
        #expect(lines[1].hasPrefix("'''exec' '"))
        #expect(!lines.contains { pathContainsStagingSegment($0) })
    }

    private static func withStagedLayout(
        runtimeRoot: URL,
        operation: String,
        _ body: @Sendable (SolstoneRuntimeLayout) throws -> Void
    ) {
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: runtimeRoot,
                includingPropertiesForKeys: nil,
                options: []
            )
            let tempRoot = try #require(children.first { $0.lastPathComponent.hasPrefix(".tmp-") })
            try body(SolstoneRuntimeLayout(rootURL: tempRoot))
        } catch {
            Issue.record("failed to \(operation): \(error.localizedDescription)")
        }
    }

    private static func materializedTool(named name: String, in layout: SolstoneRuntimeLayout) -> URL {
        layout.toolsDir
            .appendingPathComponent("solstone-journal", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func writeExecutableShell(at url: URL, body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runShell(_ script: URL, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func expectMaterializeVerificationFailure(
        _ materializer: RuntimeMaterializer,
        expected: StringRecorder
    ) async throws {
        try await expectMaterializeVerificationFailure(
            materializer,
            expectedPrefixRecorder: expected,
            buildExpected: { $0 }
        )
    }

    private func expectMaterializeVerificationFailure(
        _ materializer: RuntimeMaterializer,
        expectedPrefixRecorder: StringRecorder,
        buildExpected: (String) -> String
    ) async throws {
        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail verification")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed(let message) = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
            #expect(message == buildExpected(try expectedPrefixRecorder.require()))
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
    }

    private func toolInstallCount(in runner: FakeSubprocessRunner) -> Int {
        runner.invocations.filter { $0.arguments.starts(with: ["tool", "install"]) }.count
    }

    private func pathContainsStagingSegment(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".tmp-") }
    }

    private func pathIsUnderRoot(_ path: String, rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func shellSingleQuotedForTest(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-runtime-materializer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RemovalFailingFileManager: FileManager {
    private let failingName: String

    init(failingName: String) {
        self.failingName = failingName
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == failingName {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

private final class AttributeFailingFileManager: FileManager {
    private let failingLeafNames: Set<String>

    init(failingLeafNames: Set<String> = ["sol", "journal"]) {
        self.failingLeafNames = failingLeafNames
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if failingLeafNames.contains(where: { path.contains(".\($0).") }) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private final class AbsoluteRelocationFileManager: FileManager {
    private let absoluteLeafName: String
    private let absoluteDestination: URL

    init(absoluteLeafName: String, absoluteDestination: URL) {
        self.absoluteLeafName = absoluteLeafName
        self.absoluteDestination = absoluteDestination
        super.init()
    }

    override func createSymbolicLink(atPath path: String, withDestinationPath destPath: String) throws {
        if URL(fileURLWithPath: path).lastPathComponent == absoluteLeafName,
           destPath.hasPrefix("../") {
            try super.createSymbolicLink(atPath: path, withDestinationPath: absoluteDestination.path)
            return
        }
        try super.createSymbolicLink(atPath: path, withDestinationPath: destPath)
    }
}

private final class AliasEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RuntimeAliasLogEvent] = []

    var events: [RuntimeAliasLogEvent] {
        lock.withLock { recorded }
    }

    func record(_ event: RuntimeAliasLogEvent) {
        lock.withLock {
            recorded.append(event)
        }
    }
}

private final class DataMapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func record(_ data: Data, for key: String) {
        lock.withLock {
            values[key] = data
        }
    }

    func data(for key: String) throws -> Data {
        try lock.withLock {
            try #require(values[key])
        }
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) {
        self.value = value
    }

    func record(_ value: String) {
        lock.withLock {
            self.value = value
        }
    }

    func require() throws -> String {
        try lock.withLock {
            try #require(value)
        }
    }
}
