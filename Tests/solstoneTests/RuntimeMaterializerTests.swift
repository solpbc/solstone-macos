// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("RuntimeMaterializer")
struct RuntimeMaterializerTests {
    @Test func sweepKeepsCrossVersionLiveKey() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = "0.6.4_py20260510_aaaaaaaaaaaaaaaa"
        let live = "0.6.1_py20260510_bbbbbbbbbbbbbbbb"
        let orphan = "0.6.0_py20260101_cccccccccccccccc"
        try createDirectories([current, live, orphan], in: root)

        RuntimeMaterializer.sweepRuntimeGenerations(in: root, currentKey: current, liveKey: live, fileManager: .default)

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

        RuntimeMaterializer.sweepRuntimeGenerations(in: root, currentKey: current, liveKey: nil, fileManager: .default)

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

        RuntimeMaterializer.sweepRuntimeGenerations(in: root, currentKey: current, liveKey: nil, fileManager: .default)

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

        RuntimeMaterializer.sweepRuntimeGenerations(in: root, currentKey: current, liveKey: nil, fileManager: fileManager)

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

        RuntimeMaterializer.sweepRuntimeGenerations(in: emptyRoot, currentKey: current, liveKey: nil, fileManager: .default)
        RuntimeMaterializer.sweepRuntimeGenerations(in: currentOnlyRoot, currentKey: current, liveKey: nil, fileManager: .default)
        RuntimeMaterializer.sweepRuntimeGenerations(in: missingRoot, currentKey: current, liveKey: nil, fileManager: .default)

        #expect(directoryExists(current, in: currentOnlyRoot))
        #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    }

    @Test func materializeRelocatesAllDiscoveredConsoleScriptsAndLeavesPythonLinkUntouched() async throws {
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
            try assertRelocatedConsoleScript(named: name, in: runtime, rootPath: rootPath)
        }

        let pythonLink = runtime.layout.binDir.appendingPathComponent("python3.13")
        let pythonDestination = try FileManager.default.destinationOfSymbolicLink(atPath: pythonLink.path)
        #expect(pythonDestination == fixture.bundledPython.path)
        #expect(pythonLink.resolvingSymlinksInPath().standardizedFileURL.path == fixture.bundledPython.standardizedFileURL.path)
        #expect(!runner.invocations.contains { $0.executable.lastPathComponent == "mlx-vlm-server" })
    }

    @Test func materializeFailsClosedWhenDiscoveredConsoleScriptDanglesDuringStaging() async throws {
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
                    withDestinationPath: tempRoot.appendingPathComponent("tools/solstone/bin/ghost").path
                )
            } catch {
                Issue.record("failed to create dangling staged console script: \(error.localizedDescription)")
            }
        }
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        do {
            _ = try await materializer.materialize(excludingLiveKey: nil)
            Issue.record("expected materialize to fail on dangling discovered console script")
        } catch let error as RuntimeMaterializerError {
            guard case .verificationFailed = error else {
                Issue.record("expected verificationFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected RuntimeMaterializerError, got \(error)")
        }
    }

    @Test func materializeRematerializesFinalRuntimeWithDanglingDiscoveredConsoleScript() async throws {
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
        try assertRelocatedConsoleScript(named: "mlx-vlm-server", in: healedRuntime, rootPath: rootPath)
    }

    @Test func materializeRoundTripsUvTrampolineInterpreterPathWithSpacesAndSingleQuotes() async throws {
        let fixture = try makeMaterializerFixture(runtimeRootComponents: ["a b", "it's"])
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        let materializer = makeMaterializer(fixture: fixture, runner: runner)

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        let sol = runtime.layout.binDir.appendingPathComponent("sol").resolvingSymlinksInPath().standardizedFileURL
        let lines = try String(contentsOf: sol, encoding: .utf8).components(separatedBy: "\n")
        let expectedInterpreter = runtime.layout.rootURL
            .appendingPathComponent("tools/solstone/bin/python")
            .standardizedFileURL
            .path
        #expect(lines.count >= 2)
        #expect(lines[1] == "'''exec' \(shellSingleQuotedForTest(expectedInterpreter)) \"$0\" \"$@\"")
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
        try Data("wheel\n".utf8).write(to: wheelhouse.appendingPathComponent("solstone-\(BundleConfig.solstonePinVersion)-py3-none-any.whl"))
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
        runner: FakeSubprocessRunner
    ) -> RuntimeMaterializer {
        RuntimeMaterializer(
            runtimeRootURL: fixture.runtimeRoot,
            uvBinaryURL: URL(fileURLWithPath: "/usr/bin/uv"),
            bundledPythonURL: fixture.bundledPython,
            wheelhouseURL: fixture.wheelhouse,
            wrapperDirURL: fixture.wrapperDir,
            runner: runner
        )
    }

    private func assertRelocatedConsoleScript(named name: String, in runtime: MaterializedRuntime, rootPath: String) throws {
        let entry = runtime.layout.binDir.appendingPathComponent(name)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
        #expect(!destination.hasPrefix("/"))
        #expect(!pathContainsStagingSegment(destination))
        let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(pathIsUnderRoot(resolved.path, rootPath: rootPath))
        #expect(!pathContainsStagingSegment(resolved.path))
        let script = try String(contentsOf: resolved, encoding: .utf8)
        let lines = script.components(separatedBy: "\n")
        #expect(lines.first == "#!/bin/sh")
        guard lines.count >= 2 else {
            Issue.record("console script \(name) missing uv trampoline line")
            return
        }
        #expect(!lines.contains { pathContainsStagingSegment($0) })
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
