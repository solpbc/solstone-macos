// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import Testing
@testable import solstone

private let day = "20260101"
private let name = "101500_300"

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeSegment(root: URL, body: Data = Data("terminal".utf8), zone: Bool = true) throws -> URL {
    let directory = root.appendingPathComponent(day).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try body.write(to: directory.appendingPathComponent("tmux_main_screen.jsonl"))
    if zone {
        try Data(#"{"tz":"Asia/Kolkata","utc_offset_seconds":19800}"#.utf8)
            .write(to: TerminalSpool.zoneURL(segmentDirectory: directory))
    }
    return directory
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func listing(_ files: [(String, UInt64, String, String)]) throws -> IngestProtocolV3.SegmentsDay {
    let rows = files.map { #"{"name":"\#($0.0)","submitted_name":"\#($0.0)","size":\#($0.1),"sha256":"\#($0.2)","status":"\#($0.3)"}"# }
    let body = #"{"protocol_version":3,"total":1,"items":[{"key":"\#(name)","segment":"\#(name)","stream":"s","files":[\#(rows.joined(separator: ","))]}]}"#
    return try JSONDecoder().decode(IngestProtocolV3.SegmentsDay.self, from: Data(body.utf8))
}

private final class FakeTransport: TerminalUploadTransport, @unchecked Sendable {
    let lock = NSLock()
    var listings: [Result<IngestProtocolV3.SegmentsDay, Error>] = []
    var results: [UploadResult] = []
    var sources: [String?] = []
    var uploads = 0

    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay {
        try lock.withLock {
            sources.append(source)
            if listings.isEmpty { return IngestProtocolV3.SegmentsDay(total: 0, items: []) }
            return try listings.removeFirst().get()
        }
    }

    func prepareTerminalUpload(serverURL: String, segment: TerminalSpoolSegment, bodyURL: URL) throws -> PreparedIngestV3Upload {
        PreparedIngestV3Upload(
            request: URLRequest(url: URL(string: "http://127.0.0.1")!),
            bodyURL: bodyURL,
            stagedParts: [],
            submittedSegment: segment.segment,
            metadata: segment.zone
        )
    }

    func uploadStaged(prepared: PreparedIngestV3Upload) async -> UploadResult {
        lock.withLock {
            uploads += 1
            return results.isEmpty ? .failure(URLError(.notConnectedToInternet)) : results.removeFirst()
        }
    }
}

private func planner(root: URL, transport: FakeTransport, held: Bool = false, url: String? = "http://127.0.0.1") -> TerminalUploadPlanner {
    TerminalUploadPlanner(root: root, transport: transport, serverURL: { url }, isHeld: { held })
}

@Suite("Terminal source")
struct TerminalSourceTests {
    @Test func terminalIsOffUntilTheOwnerTurnsItOn() {
        var config = AppConfig()
        #expect(config.isTerminalEnabled == false)
        config.isTerminalEnabled = true
        #expect(config.isTerminalEnabled)
    }

    @Test func aFinishedSegmentCarriesItsFilesAndCaptureTime() throws {
        let root = try tempRoot()
        try writeSegment(root: root)
        let found = TerminalSpool.finished(root: root)
        #expect(found.count == 1)
        #expect(found[0].day == day)
        #expect(found[0].files.map(\.lastPathComponent) == ["tmux_main_screen.jsonl"])
        #expect(found[0].zone?["utc_offset_seconds"] == .integer(19800))
        #expect(found[0].zone?["tz"] == .string("Asia/Kolkata"))
    }

    @Test func aSegmentWhoseFinishHasNotCompletedIsNotDeliverable() throws {
        let root = try tempRoot()
        let directory = try writeSegment(root: root, zone: false)
        let meta = directory.deletingLastPathComponent().appendingPathComponent("101500.incomplete.meta")
        try Data("{}".utf8).write(to: meta)
        #expect(TerminalSpool.finished(root: root).isEmpty)
        try FileManager.default.removeItem(at: meta)
        #expect(TerminalSpool.finished(root: root).count == 1)
    }

    @Test func unfinishedAndForeignEntriesAreIgnored() throws {
        let root = try tempRoot()
        let dayURL = root.appendingPathComponent(day)
        for other in ["101500.incomplete", "101500_300.failed", "notes"] {
            try FileManager.default.createDirectory(at: dayURL.appendingPathComponent(other), withIntermediateDirectories: true)
        }
        #expect(TerminalSpool.finished(root: root).isEmpty)
    }

    @Test func tmuxLookupPrefersKnownPathsThenTheLoginShell() {
        #expect(TerminalTmuxLocator.locate(isExecutable: { $0 == "/usr/local/bin/tmux" }, loginShellLookup: { nil }) == "/usr/local/bin/tmux")
        #expect(TerminalTmuxLocator.locate(isExecutable: { $0 == "/nix/bin/tmux" }, loginShellLookup: { "/nix/bin/tmux\n" }) == "/nix/bin/tmux")
        #expect(TerminalTmuxLocator.locate(isExecutable: { _ in false }, loginShellLookup: { "/nix/bin/tmux" }) == nil)
        #expect(TerminalTmuxLocator.locate(isExecutable: { _ in true }, loginShellLookup: { nil }) != nil)
    }

    @Test func helperEventsAreParsedWhateverTheKeyOrder() {
        #expect(TerminalHelperEvent.parse(Data(#"{"version":"1","event":"ready"}"#.utf8)) == .ready)
        #expect(TerminalHelperEvent.parse(Data(#"{"tmux":"missing","event":"health"}"#.utf8)) == .tmuxHealth(found: false))
        #expect(TerminalHelperEvent.parse(Data(#"{"day":"1","dir":"/x","event":"segment","segment":"s"}"#.utf8)) == .segment)
        #expect(TerminalHelperEvent.parse(Data("garbage".utf8)) == nil)
    }

    @Test func linesSplitAcrossReadsAreJoined() {
        var buffer = TerminalLineBuffer()
        #expect(buffer.append(Data("ab".utf8)).isEmpty)
        #expect(buffer.append(Data("c\nd\ne".utf8)) == [Data("abc".utf8), Data("d".utf8)])
    }

    @Test func aHeldPassSendsNothing() async throws {
        let root = try tempRoot()
        let directory = try writeSegment(root: root)
        let transport = FakeTransport()
        await planner(root: root, transport: transport, held: true).planAndUpload()
        #expect(transport.uploads == 0)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func withNoRouteToTheJournalNothingMoves() async throws {
        let root = try tempRoot()
        try writeSegment(root: root)
        let transport = FakeTransport()
        await planner(root: root, transport: transport, url: nil).planAndUpload()
        #expect(transport.uploads == 0)
        #expect(transport.sources.isEmpty)
    }

    @Test func aFailedUploadKeepsTheSegment() async throws {
        let root = try tempRoot()
        let directory = try writeSegment(root: root)
        let transport = FakeTransport()
        await planner(root: root, transport: transport).planAndUpload()
        #expect(transport.uploads == 1)
        #expect(transport.sources == [TerminalUploadPlanner.source])
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aRowProvingEveryFileRemovesTheSegmentUnsent() async throws {
        let root = try tempRoot()
        let body = Data("terminal".utf8)
        let directory = try writeSegment(root: root, body: body)
        let transport = FakeTransport()
        transport.listings = [.success(try listing([("tmux_main_screen.jsonl", UInt64(body.count), digest(body), "present")]))]
        await planner(root: root, transport: transport).planAndUpload()
        #expect(transport.uploads == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: TerminalSpool.zoneURL(segmentDirectory: directory).path))
    }

    @Test func aRowThatDoesNotProveEveryFileIsSentAnyway() async throws {
        let root = try tempRoot()
        let body = Data("terminal".utf8)
        let directory = try writeSegment(root: root, body: body)
        for row in [
            ("tmux_main_screen.jsonl", UInt64(body.count), digest(body), "missing"),
            ("tmux_main_screen.jsonl", UInt64(body.count), digest(Data("other".utf8)), "present"),
            ("other.jsonl", UInt64(body.count), digest(body), "present"),
        ] {
            let transport = FakeTransport()
            transport.listings = [.success(try listing([row]))]
            await planner(root: root, transport: transport).planAndUpload()
            #expect(transport.uploads == 1, "\(row)")
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
