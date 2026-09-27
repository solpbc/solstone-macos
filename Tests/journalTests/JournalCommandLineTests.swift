// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import journal

@Suite("JournalCommandLine")
struct JournalCommandLineTests {
    private let executable = "/Applications/journal.app/Contents/MacOS/journal"

    @Test func appLaunchesStayWithTheApp() {
        let launches: [[String]] = [
            [executable],
            [executable, "-psn_0_1234567"],
            [executable, "-NSDocumentRevisionsDebugMode", "YES"],
            [executable, "-AppleLanguages", "(en)"],
            [executable, "-ApplePersistenceIgnoreState", "YES"],
        ]
        for arguments in launches {
            #expect(JournalCommandLine.route(arguments: arguments) == .app, "\(arguments)")
        }
    }

    @Test func commandLinesGoToTheJournalCommand() {
        let commandLines: [[String]] = [
            [executable, "--version"],
            [executable, "--help"],
            [executable, "-h"],
            [executable, "-V"],
            [executable, "doctor"],
            [executable, "install-provider", "local"],
        ]
        for arguments in commandLines {
            #expect(JournalCommandLine.route(arguments: arguments) == .commandLine, "\(arguments)")
        }
    }

    @Test func commandLineIsTheBundledRuntimeJournal() {
        let url = JournalCommandLine.commandLineURL(executableURL: URL(fileURLWithPath: executable))
        #expect(url.path == "/Applications/journal.app/Contents/Resources/solstone-runtime/bin/journal")
    }

    @Test func commandLineResolvesThroughALinkToTheApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-command-line-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("journal.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let app = macOS.appendingPathComponent("journal")
        try Data().write(to: app)
        let link = root.appendingPathComponent("bin/journal")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)

        let url = JournalCommandLine.commandLineURL(executableURL: link)
        let contents = app.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        #expect(url.path == contents.appendingPathComponent("Resources/solstone-runtime/bin/journal").path)
    }
}
