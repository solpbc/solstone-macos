// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import SolstoneCore
import Testing
@testable import solstone

@Suite("On-disk journal discovery", .serialized)
struct OnDiskJournalDiscoveryTests {
    @Test func tomlParserUnescapesExpandsTildeAndStandardizes() throws {
        let raw = #"journal = "~/journal\\with\"quote""#
        let expected = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(#"journal\with"quote"#, isDirectory: true)
            .standardizedFileURL
            .path

        #expect(parseJournalPathFromConfigToml(raw) == expected)
    }

    @Test func tomlParserAcceptsNoSpaceJournalAssignment() throws {
        let expected = URL(fileURLWithPath: "/some/path", isDirectory: true)
            .standardizedFileURL
            .path

        #expect(parseJournalPathFromConfigToml(#"journal="/some/path""#) == expected)
    }

    @Test func tomlParserIgnoresNonTopLevelJournalKeys() {
        #expect(parseJournalPathFromConfigToml(#"#journal = "/tmp/nope""#) == nil)
        #expect(parseJournalPathFromConfigToml(#"journal_backup = "/tmp/nope""#) == nil)
        #expect(parseJournalPathFromConfigToml("""
        [table]
        journal = "/tmp/nope"
        """) == nil)
    }

    @Test func missingOrInvalidConfigFallsThroughToDefaultJournal() async {
        for raw in [nil, "junk", #"server = "https://example.invalid""#] {
            let reader = FakeOnDiskJournalFileReader()
            let defaultPath = defaultJournalPath()
            reader.directories = [defaultPath, childPath(defaultPath, "config")]

            let result = await discoverOnDiskJournal(
                configReader: FakeConfigReader(raw: raw),
                fileReader: reader,
                timeout: 0.05
            )

            #expect(result == .found(path: defaultPath))
        }
    }

    @Test func predicateAcceptsOnlyTopLevelJournalEvidence() async {
        for evidence in JournalEvidence.accepted {
            let reader = FakeOnDiskJournalFileReader()
            evidence.apply(to: reader, root: "/journal")

            #expect(await journalDirectoryQualifies(at: "/journal", using: reader))
        }
    }

    @Test func predicateRejectsNonQualifyingDirectories() async {
        for evidence in JournalEvidence.rejected {
            let reader = FakeOnDiskJournalFileReader()
            evidence.apply(to: reader, root: "/journal")

            #expect(!(await journalDirectoryQualifies(at: "/journal", using: reader)))
        }
    }

    @Test func stalledConfigStatTimesOutBeforeEnumeration() async {
        let reader = FakeOnDiskJournalFileReader()
        reader.directories = ["/stall"]
        reader.directoryStalls = ["/stall/config"]
        let start = ContinuousClock.now

        let result = await discoverOnDiskJournal(
            configReader: FakeConfigReader(raw: #"journal = "/stall""#),
            fileReader: reader,
            timeout: 0.05
        )

        let elapsed = start.duration(to: ContinuousClock.now)
        #expect(result == .none)
        #expect(elapsed < .milliseconds(500))
        #expect(reader.calls.prefix(2) == ["directory:/stall", "directory:/stall/config"])
        #expect(!reader.calls.contains("contents:/stall"))
    }

    @MainActor
    @Test func runningJournalPrecedenceSkipsOnDiskDiscovery() async {
        var onDiskCalls = 0
        let model = await discoverLocalJournalPanelModel(
            fetchIdentity: { _ in .uiTestSample },
            onDiskDiscovery: {
                onDiskCalls += 1
                return .found(path: "/journal")
            }
        )

        #expect(model == .foundRunning(.uiTestSample))
        #expect(onDiskCalls == 0)
    }
}

private struct FakeConfigReader: SolstoneUserConfigReading {
    let raw: String?

    func readConfigToml() async -> String? {
        raw
    }
}

private final class FakeOnDiskJournalFileReader: OnDiskJournalFileReading, @unchecked Sendable {
    var directories: Set<String> = []
    var files: Set<String> = []
    var directoryEntries: [String: [String]] = [:]
    var directoryStalls: Set<String> = []
    var fileStalls: Set<String> = []
    var enumerationStalls: Set<String> = []
    var calls: [String] = []

    func directoryExists(_ path: String) async -> Bool {
        calls.append("directory:\(path)")
        if directoryStalls.contains(path) {
            return await stallUntilCancelled(false)
        }
        return directories.contains(path)
    }

    func fileExists(_ path: String) async -> Bool {
        calls.append("file:\(path)")
        if fileStalls.contains(path) {
            return await stallUntilCancelled(false)
        }
        return files.contains(path) || directories.contains(path)
    }

    func contentsOfDirectory(_ path: String) async -> [String] {
        calls.append("contents:\(path)")
        if enumerationStalls.contains(path) {
            return await stallUntilCancelled([])
        }
        return directoryEntries[path] ?? []
    }
}

private enum JournalEvidence {
    case configDirectory
    case jsonlFile
    case eightDigitDirectory
    case empty
    case missing
    case rootFile
    case unrelated
    case configFile
    case sevenDigitDirectory
    case nineDigitDirectory
    case eightDigitsWithSuffix

    static let accepted: [JournalEvidence] = [
        .configDirectory,
        .jsonlFile,
        .eightDigitDirectory,
    ]

    static let rejected: [JournalEvidence] = [
        .empty,
        .missing,
        .rootFile,
        .unrelated,
        .configFile,
        .sevenDigitDirectory,
        .nineDigitDirectory,
        .eightDigitsWithSuffix,
    ]

    func apply(to reader: FakeOnDiskJournalFileReader, root: String) {
        switch self {
        case .configDirectory:
            reader.directories = [root, childPath(root, "config")]
        case .jsonlFile:
            reader.directories = [root]
            reader.files = [childPath(root, "events.jsonl")]
            reader.directoryEntries[root] = ["events.jsonl"]
        case .eightDigitDirectory:
            reader.directories = [root, childPath(root, "20260715")]
            reader.directoryEntries[root] = ["20260715"]
        case .empty:
            reader.directories = [root]
            reader.directoryEntries[root] = []
        case .missing:
            break
        case .rootFile:
            reader.files = [root]
        case .unrelated:
            reader.directories = [root]
            reader.files = [childPath(root, "notes.txt")]
            reader.directoryEntries[root] = ["notes.txt"]
        case .configFile:
            reader.directories = [root]
            reader.files = [childPath(root, "config")]
            reader.directoryEntries[root] = ["config"]
        case .sevenDigitDirectory:
            reader.directories = [root, childPath(root, "1234567")]
            reader.directoryEntries[root] = ["1234567"]
        case .nineDigitDirectory:
            reader.directories = [root, childPath(root, "123456789")]
            reader.directoryEntries[root] = ["123456789"]
        case .eightDigitsWithSuffix:
            reader.directories = [root, childPath(root, "12345678abc")]
            reader.directoryEntries[root] = ["12345678abc"]
        }
    }
}

private func defaultJournalPath() -> String {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("journal", isDirectory: true)
        .standardizedFileURL
        .path
}

private func childPath(_ parent: String, _ child: String) -> String {
    URL(fileURLWithPath: parent, isDirectory: true)
        .appendingPathComponent(child)
        .path
}

private func stallUntilCancelled<T>(_ value: T) async -> T {
    while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return value
}
