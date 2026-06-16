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
