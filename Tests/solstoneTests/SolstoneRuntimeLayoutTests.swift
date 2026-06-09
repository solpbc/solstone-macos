// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SolstoneRuntimeLayout")
struct SolstoneRuntimeLayoutTests {
    @Test func uvEnvironmentContainsAllFiveUVKeys() {
        let environment = makeLayout().uvEnvironment()

        for key in uvKeys {
            #expect(environment[key] != nil)
        }
    }

    @Test func uvEnvironmentMapsKeysToMatchingSubdirs() {
        let layout = makeLayout()
        let environment = layout.uvEnvironment()

        #expect(environment["UV_PYTHON_INSTALL_DIR"] == layout.pythonDir.path)
        #expect(environment["UV_PYTHON_CACHE_DIR"] == layout.pythonDir.path)
        #expect(environment["UV_CACHE_DIR"] == layout.cacheDir.path)
        #expect(environment["UV_TOOL_DIR"] == layout.toolsDir.path)
        #expect(environment["UV_TOOL_BIN_DIR"] == layout.binDir.path)
    }

    @Test func uvEnvironmentPreservesInheritedPATHAndHOME() {
        let inherited = ProcessInfo.processInfo.environment
        let environment = makeLayout().uvEnvironment()

        if let path = inherited["PATH"] {
            #expect(environment["PATH"] == path)
        }
        if let home = inherited["HOME"] {
            #expect(environment["HOME"] == home)
        }
    }

    @Test func ensureCreatedIsIdempotent() throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let layout = SolstoneRuntimeLayout(rootURL: root)

        try layout.ensureCreated()
        try layout.ensureCreated()

        for dir in [layout.rootURL, layout.pythonDir, layout.cacheDir, layout.toolsDir, layout.binDir] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @Test func versionedModeKeepsPythonAndCacheAtRoot() {
        let root = URL(fileURLWithPath: "/tmp/solstone-runtime-layout-tests/runtime", isDirectory: true)
        let layout = SolstoneRuntimeLayout(rootURL: root, mode: .versioned("0.4.8"))

        #expect(layout.pythonDir.path == root.appendingPathComponent("python").path)
        #expect(layout.cacheDir.path == root.appendingPathComponent("cache").path)
        #expect(layout.toolsDir.path == root.appendingPathComponent("versions/0.4.8/tools").path)
        #expect(layout.binDir.path == root.appendingPathComponent("versions/0.4.8/bin").path)
        #expect(layout.solBinary.path == root.appendingPathComponent("versions/0.4.8/bin/sol").path)
        #expect(layout.journalBinary.path == root.appendingPathComponent("versions/0.4.8/bin/journal").path)
    }

    @Test func ensureCreatedForVersionedDoesNotCreatePerVersionSharedDirs() throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let layout = SolstoneRuntimeLayout(rootURL: root, mode: .versioned("0.4.8"))

        try layout.ensureCreated()

        for dir in [layout.rootURL, layout.pythonDir, layout.cacheDir, layout.toolsDir, layout.binDir] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
        let versionRoot = root.appendingPathComponent("versions/0.4.8", isDirectory: true)
        for forbidden in ["python", "cache", "model", "models"] {
            #expect(!FileManager.default.fileExists(atPath: versionRoot.appendingPathComponent(forbidden).path))
        }
    }

    @Test func readActiveVersionHandlesExpectedSymlinks() throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let layout = SolstoneRuntimeLayout(rootURL: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("versions/0.4.8", isDirectory: true),
            withIntermediateDirectories: true
        )

        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: root) == nil)
        try FileManager.default.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "versions/0.4.8")
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: root) == "0.4.8")

        try FileManager.default.removeItem(at: layout.currentLink)
        try FileManager.default.createSymbolicLink(
            at: layout.currentLink,
            withDestinationURL: root.appendingPathComponent("versions/0.4.8", isDirectory: true)
        )
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: root) == "0.4.8")
    }

    @Test func readActiveVersionRejectsDanglingAndOutsideTargets() throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let layout = SolstoneRuntimeLayout(rootURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try FileManager.default.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "versions/missing")
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: root) == nil)

        try FileManager.default.removeItem(at: layout.currentLink)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("elsewhere", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "elsewhere")
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: root) == nil)
    }

    @Test func solCandidatePathsPreferActiveVersionThenFlat() throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("runtime", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let layout = SolstoneRuntimeLayout(rootURL: root, mode: .versioned("0.4.8"))
        try layout.ensureCreated()
        try FileManager.default.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "versions/0.4.8")

        #expect(SolstoneRuntimeLayout.solCandidatePaths(rootURL: root) == [
            root.appendingPathComponent("versions/0.4.8/bin/sol").path,
            root.appendingPathComponent("bin/sol").path
        ])
    }

    @Test func pathConstantsHaveStableSuffixes() {
        let layout = makeLayout()

        #expect(layout.pythonDir.path.hasSuffix("/python"))
        #expect(layout.cacheDir.path.hasSuffix("/cache"))
        #expect(layout.toolsDir.path.hasSuffix("/tools"))
        #expect(layout.binDir.path.hasSuffix("/bin"))
        #expect(layout.solBinary.path.hasSuffix("/bin/sol"))
        #expect(layout.journalBinary.path.hasSuffix("/bin/journal"))
    }

    @Test func versionedPathConstantsHaveStableSuffixes() {
        let root = URL(fileURLWithPath: "/tmp/solstone-runtime-layout-tests/runtime", isDirectory: true)
        let layout = SolstoneRuntimeLayout(rootURL: root, mode: .versioned("0.4.8"))

        #expect(layout.versionsDir.path.hasSuffix("/versions"))
        #expect(layout.currentLink.path.hasSuffix("/current"))
        #expect(layout.pythonDir.path.hasSuffix("/python"))
        #expect(layout.cacheDir.path.hasSuffix("/cache"))
        #expect(layout.toolsDir.path.hasSuffix("/versions/0.4.8/tools"))
        #expect(layout.binDir.path.hasSuffix("/versions/0.4.8/bin"))
        #expect(layout.solBinary.path.hasSuffix("/versions/0.4.8/bin/sol"))
        #expect(layout.journalBinary.path.hasSuffix("/versions/0.4.8/bin/journal"))
    }

    @Test func bundledPythonURLResolvesInsideAppResources() {
        let bundleURL = URL(fileURLWithPath: "/tmp/Solstone.app", isDirectory: true)

        #expect(SolstoneRuntimeLayout.bundledPythonURL(bundleURL: bundleURL).path == "/tmp/Solstone.app/Contents/Resources/python/bin/python3.13")
    }

    private var uvKeys: [String] {
        [
            "UV_PYTHON_INSTALL_DIR",
            "UV_PYTHON_CACHE_DIR",
            "UV_CACHE_DIR",
            "UV_TOOL_DIR",
            "UV_TOOL_BIN_DIR"
        ]
    }

    private func makeLayout() -> SolstoneRuntimeLayout {
        SolstoneRuntimeLayout(rootURL: URL(fileURLWithPath: "/tmp/solstone-runtime-layout-tests/runtime", isDirectory: true))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-runtime-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
