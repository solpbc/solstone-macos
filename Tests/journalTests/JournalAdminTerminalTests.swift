// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import journal

@Suite("JournalAdminTerminal")
struct JournalAdminTerminalTests {
    @Test func commandLineIsTheRunningCopysBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("admin-terminal-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("somewhere else/journal.app", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: copy)

        #expect(
            JournalAdminTerminal.binDirectory(bundleURL: link).path
                == copy.resolvingSymlinksInPath().path + "/Contents/Resources/solstone-runtime/bin"
        )
    }

    @Test func preparedFilesArePrivateAndTheScriptIsExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("admin-terminal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = try JournalAdminTerminal.prepare(
            binDirectory: URL(fileURLWithPath: "/Applications/journal.app/Contents/Resources/solstone-runtime/bin"),
            temporaryDirectory: root
        )
        func permissions(_ url: URL) throws -> Int {
            try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        let directory = script.deletingLastPathComponent()
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(script) == 0o700)
        #expect(script.pathExtension == "command")
        #expect(try permissions(directory.appendingPathComponent("zsh/.zshenv")) == 0o600)
        #expect(try permissions(directory.appendingPathComponent("bashrc")) == 0o600)
    }
}
