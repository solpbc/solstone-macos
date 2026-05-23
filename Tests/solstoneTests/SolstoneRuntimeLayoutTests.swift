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

    @Test func pathConstantsHaveStableSuffixes() {
        let layout = makeLayout()

        #expect(layout.pythonDir.path.hasSuffix("/python"))
        #expect(layout.cacheDir.path.hasSuffix("/cache"))
        #expect(layout.toolsDir.path.hasSuffix("/tools"))
        #expect(layout.binDir.path.hasSuffix("/bin"))
        #expect(layout.solBinary.path.hasSuffix("/bin/sol"))
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
