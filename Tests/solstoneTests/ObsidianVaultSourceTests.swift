// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation
import MacTestSupport
import Testing
@testable import solstone

private let denver = TimeZone(secondsFromGMT: -7 * 3600)!

private func date(_ rfc3339: String) -> Date {
    // The fixtures below are all literal, valid RFC 3339.
    try! Date(rfc3339, strategy: .iso8601)
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// A vault in a temp directory, with the engine's private store beside it.
private final class Fixture: @unchecked Sendable {
    let base: URL
    let root: URL
    let store: URL
    let walkHook: Locked<(@Sendable (inout ObsidianVaultWalk) -> Void)?>

    init(vaultName: String = "Notes") throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("obsidian-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent(vaultName, isDirectory: true)
        store = base.appendingPathComponent("store", isDirectory: true)
        walkHook = Locked(nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func makeEngine() async -> ObsidianEngine {
        let hook = walkHook
        let engine = ObsidianEngine(directory: store, timeZone: { denver }, walker: { url in
            let result = ObsidianVaultWalker.walk(root: url)
            guard case .scanned(var walk) = result else { return result }
            hook.value?(&walk)
            return .scanned(walk)
        })
        await engine.load()
        return engine
    }

    func setPermissions(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: root.appendingPathComponent(path).path)
    }

    func pendingEntryFiles() throws -> [URL] {
        let pending = store.appendingPathComponent("pending", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil).flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
    }

    func write(_ path: String, _ text: String, at mtime: Date = date("2026-11-08T09:42:10-07:00")) throws {
        try writeData(path, Data(text.utf8), at: mtime)
    }

    func writeData(_ path: String, _ data: Data, at mtime: Date = date("2026-11-08T09:42:10-07:00")) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try setMtime(path, mtime)
    }

    func setMtime(_ path: String, _ mtime: Date) throws {
        var times = [timeval](repeating: timeval(tv_sec: Int(mtime.timeIntervalSince1970), tv_usec: 0), count: 2)
        guard utimes(root.appendingPathComponent(path).path, &times) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    }

    func rename(_ old: String, to new: String) throws {
        let destination = root.appendingPathComponent(new)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(old), to: destination)
    }

    /// Every file under the vault, with its content hash and modification time.
    func vaultState() throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            let relative = String(url.path.dropFirst(root.path.count))
            let hash = values.isRegularFile == true ? ObsidianWire.sha256Hex(try Data(contentsOf: url)) : "directory"
            result[relative] = "\(hash)@\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }

    /// All lines currently in outbox files, in delivery order.
    func outboxLines(_ engine: ObsidianEngine) async throws -> [[String: Any]] {
        var lines: [[String: Any]] = []
        for file in await engine.outboxFiles() {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                lines.append(try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any])
            }
        }
        return lines
    }

    func heldBytes() throws -> [Data] {
        var result: [Data] = []
        let enumerator = FileManager.default.enumerator(at: store, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result.append(try Data(contentsOf: url))
            }
        }
        return result
    }
}

private func line(_ lines: [[String: Any]], _ path: String) -> [String: Any]? {
    lines.first { ($0["path"] as? String) == path }
}

@Suite("Obsidian wire contract")
struct ObsidianWireTests {
    private func stamp(_ value: String) -> ObsidianStamp {
        ObsidianStamp(epochSeconds: Int64(date(value).timeIntervalSince1970), timeZone: denver)
    }

    private var goldenLines: [ObsidianNoteLine] {
        [
            ObsidianNoteLine(
                change: .changed, vault: "Notes", path: "daily/2026-11-08.md", previousPath: nil,
                changedAt: stamp("2026-11-08T09:42:10-07:00"), observedAt: stamp("2026-11-08T09:42:33-07:00"),
                text: "---\ntags: [walk]\n---\nMet Alex by the river.\n",
                contentHash: "f0b347123a86bae3e1d4d8c48a7f0430bed090b37d8ed1873a63a97c0b13dfa9"
            ),
            ObsidianNoteLine(
                change: .removed, vault: "Notes", path: "inbox/old idea.md", previousPath: nil,
                changedAt: stamp("2026-11-08T09:44:33-07:00"), observedAt: stamp("2026-11-08T09:44:33-07:00"),
                text: nil, contentHash: nil
            ),
            ObsidianNoteLine(
                change: .renamed, vault: "Notes", path: "people/Alex Rivera.md", previousPath: "inbox/Alex.md",
                changedAt: stamp("2026-11-08T09:43:02-07:00"), observedAt: stamp("2026-11-08T09:43:33-07:00"),
                text: "Alex likes rivers.\n",
                contentHash: "14fece546a747b07dec10e2658310b2d224447158a8c6e1b3a65d467b9de22a3"
            ),
        ]
    }

    @Test func goldenFileIsExactBytesAndName() throws {
        let expected = """
        {"change":"changed","changed_at":"2026-11-08T09:42:10-07:00","content_hash":"f0b347123a86bae3e1d4d8c48a7f0430bed090b37d8ed1873a63a97c0b13dfa9","observed_at":"2026-11-08T09:42:33-07:00","path":"daily/2026-11-08.md","previous_path":null,"text":"---\\ntags: [walk]\\n---\\nMet Alex by the river.\\n","v":1,"vault":"Notes"}
        {"change":"removed","changed_at":"2026-11-08T09:44:33-07:00","content_hash":null,"observed_at":"2026-11-08T09:44:33-07:00","path":"inbox/old idea.md","previous_path":null,"text":null,"v":1,"vault":"Notes"}
        {"change":"renamed","changed_at":"2026-11-08T09:43:02-07:00","content_hash":"14fece546a747b07dec10e2658310b2d224447158a8c6e1b3a65d467b9de22a3","observed_at":"2026-11-08T09:43:33-07:00","path":"people/Alex Rivera.md","previous_path":"inbox/Alex.md","text":"Alex likes rivers.\\n","v":1,"vault":"Notes"}

        """
        let files = ObsidianNoteLine.files(for: goldenLines.reversed())
        #expect(files.count == 1)
        #expect(files[0].name == "obsidian_3e100d06fb18b4f45302cb3cf2cad1881e7183360649f0543ce4acf565b9f81e.jsonl")
        #expect(String(decoding: files[0].bytes, as: UTF8.self) == expected)
        #expect(goldenLines[0].changedAt.window == ObsidianWindow(day: "20261108", segment: "094000_300"))
    }

    @Test func hashesMatchTheGoldenText() {
        #expect(ObsidianWire.sha256Hex(Data("---\ntags: [walk]\n---\nMet Alex by the river.\n".utf8)) == "f0b347123a86bae3e1d4d8c48a7f0430bed090b37d8ed1873a63a97c0b13dfa9")
        #expect(ObsidianWire.sha256Hex(Data("Alex likes rivers.\n".utf8)) == "14fece546a747b07dec10e2658310b2d224447158a8c6e1b3a65d467b9de22a3")
    }

    @Test func offsetsAreWrittenAndSecondsOffsetsBecomeUTC() {
        let moment = Int64(date("2026-11-08T16:42:33Z").timeIntervalSince1970)
        #expect(ObsidianStamp(epochSeconds: moment, timeZone: TimeZone(secondsFromGMT: 19_800)!).rfc3339 == "2026-11-08T22:12:33+05:30")
        #expect(ObsidianStamp(epochSeconds: moment, timeZone: TimeZone(secondsFromGMT: 0)!).rfc3339 == "2026-11-08T16:42:33Z")
        let secondsOffset = ObsidianStamp(epochSeconds: moment, timeZone: TimeZone(secondsFromGMT: 3601)!)
        #expect(secondsOffset.rfc3339 == "2026-11-08T16:42:33Z")
        #expect(secondsOffset.window == ObsidianWindow(day: "20261108", segment: "164000_300"))
    }

    @Test func windowIsTheWallClockFlooredInItsOwnOffset() {
        let stamp = ObsidianStamp(epochSeconds: Int64(date("2026-11-08T09:44:59-07:00").timeIntervalSince1970), timeZone: denver)
        #expect(stamp.window.key == "20261108-094000_300")
        let close = stamp.window.closeDate(timeZone: denver)
        #expect(close == date("2026-11-08T09:46:30-07:00"))
    }

    @Test func windowsCloseOnTimeAroundAChangeOfClocks() throws {
        let denverRules = try #require(TimeZone(identifier: "America/Denver"))
        // After the clocks go back: 03:10 MST.
        #expect(ObsidianWindow(day: "20261101", segment: "031000_300").closeDate(timeZone: denverRules) == date("2026-11-01T10:16:30Z"))
        // After the clocks go forward: 03:10 MDT.
        #expect(ObsidianWindow(day: "20260308", segment: "031000_300").closeDate(timeZone: denverRules) == date("2026-03-08T09:16:30Z"))
        // In the repeated hour, the later of the two, so it never closes early.
        #expect(ObsidianWindow(day: "20261101", segment: "013000_300").closeDate(timeZone: denverRules) == date("2026-11-01T08:36:30Z"))
    }

    @Test func splitsAtTheLineAndByteLimitsInOrder() {
        var lines: [ObsidianNoteLine] = []
        for index in 0..<5_001 {
            lines.append(ObsidianNoteLine(
                change: .changed, vault: "V", path: "n\(String(format: "%05d", index)).md", previousPath: nil,
                changedAt: stamp("2026-11-08T09:42:10-07:00"), observedAt: stamp("2026-11-08T09:42:10-07:00"),
                text: "x", contentHash: "0"))
        }
        let byLines = ObsidianNoteLine.files(for: lines)
        #expect(byLines.count == 2)
        #expect(byLines[0].bytes.split(separator: UInt8(ascii: "\n")).count == ObsidianWire.maxFileLines)
        #expect(byLines[1].bytes.split(separator: UInt8(ascii: "\n")).count == 1)

        let big = String(repeating: "a", count: 3 * 1024 * 1024)
        let bigLines = (0..<3).map { index in
            ObsidianNoteLine(change: .changed, vault: "V", path: "\(index).md", previousPath: nil,
                             changedAt: stamp("2026-11-08T09:42:10-07:00"), observedAt: stamp("2026-11-08T09:42:10-07:00"),
                             text: big, contentHash: "0")
        }
        let byBytes = ObsidianNoteLine.files(for: bigLines)
        #expect(byBytes.count == 2)
        for file in byBytes {
            #expect(file.bytes.count <= ObsidianWire.maxFileBytes)
            #expect(file.bytes.last == UInt8(ascii: "\n"))
        }
    }

    @Test func controlCharactersEscapeLikeTheJournalReadsThem() {
        let text = "tab\tnl\ncr\rbs\\qt\"nul\u{0}del\u{7f}snow☃"
        let encoded = ObsidianNoteLine(
            change: .changed, vault: "V", path: "a.md", previousPath: nil,
            changedAt: stamp("2026-11-08T09:42:10-07:00"), observedAt: stamp("2026-11-08T09:42:10-07:00"),
            text: text, contentHash: "h").encoded()
        let string = String(decoding: encoded, as: UTF8.self)
        #expect(string.contains(#""text":"tab\tnl\ncr\rbs\\qt\"nul\u0000del"#))
        #expect(string.contains("del\u{7f}snow☃"))
        let parsed = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(parsed?["text"] as? String == text)
    }

    @Test func vaultAndPathNamesTheJournalRefusesAreRefusedHere() {
        #expect(ObsidianWire.isUsableVaultName("Notes"))
        #expect(!ObsidianWire.isUsableVaultName(""))
        #expect(!ObsidianWire.isUsableVaultName(String(repeating: "x", count: 129)))
        #expect(!ObsidianWire.isUsableVaultName("a\u{1}b"))
        #expect(ObsidianWire.isSendablePath("folder/note.md"))
        #expect(!ObsidianWire.isSendablePath("back\\slash.md"))
        #expect(!ObsidianWire.isSendablePath("tab\tname.md"))
    }
}

@Suite("Obsidian engine rules")
struct ObsidianEngineTests {
    private let afterClose = date("2026-11-09T00:00:00-07:00")

    @Test func firstScanReportsEveryNoteAtItsMtimeAndWindowClosesAtNinety() async throws {
        let fixture = try Fixture()
        try fixture.write("daily/2026-11-08.md", "hello\n")
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()

        let snap = await engine.scan(now: date("2026-11-08T09:44:00-07:00"))
        #expect(snap.waiting == 1)
        #expect(snap.state.firstSyncTotal == 1)
        await engine.closeDueWindows(now: date("2026-11-08T09:46:29-07:00"))
        #expect(await engine.outboxFiles().isEmpty)

        await engine.closeDueWindows(now: date("2026-11-08T09:46:30-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "changed")
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:42:10-07:00")
        #expect(lines[0]["observed_at"] as? String == "2026-11-08T09:44:00-07:00")
        #expect(lines[0]["vault"] as? String == "Notes")
        #expect(await engine.snapshot().waiting == 1)
    }

    @Test func dotFoldersTemplatesNonNotesAndSymlinksAreSkipped() async throws {
        let fixture = try Fixture()
        try fixture.write("keep.md", "k")
        try fixture.write("UPPER.MD", "u")
        try fixture.write(".obsidian/app.md", "cfg")
        try fixture.write(".trash/gone.md", "t")
        try fixture.write("templates/daily.md", "t")
        try fixture.write("Deep/_Templates/x.md", "t")
        try fixture.write("sub/ok.md", "s")
        try fixture.write("image.png", "p")
        try fixture.write(".hidden.md", "h")
        try fixture.write("templates2/fine.md", "f")
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("link.md").path, withDestinationPath: fixture.root.appendingPathComponent("keep.md").path)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("linkdir").path, withDestinationPath: fixture.root.appendingPathComponent("sub").path)
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()

        await engine.scan(now: afterClose)
        await engine.closeDueWindows(now: afterClose.addingTimeInterval(3600))
        let paths = try await Set(fixture.outboxLines(engine).compactMap { $0["path"] as? String })
        #expect(paths == ["keep.md", "UPPER.MD", "sub/ok.md", "templates2/fine.md"])
    }

    @Test func iCloudPlaceholderIsNotReportedAndNeverDeleted() async throws {
        let fixture = try Fixture()
        try fixture.write("away.md", "text")
        try fixture.write("present.md", "here")
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: afterClose)

        // The file goes dataless: the stub appears and the file vanishes.
        try fixture.delete("away.md")
        try fixture.write(".away.md.icloud", "stub")
        // And a placeholder that was never local at all.
        try fixture.write(".fresh.md.icloud", "stub")
        let t1 = afterClose.addingTimeInterval(600)
        var snap = await engine.scan(now: t1)
        snap = await engine.scan(now: t1.addingTimeInterval(120))
        #expect(snap.notOnDevice == 2)
        #expect(snap.vaultUnreadable == false)
        await engine.closeDueWindows(now: t1.addingTimeInterval(3600))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.allSatisfy { ($0["change"] as? String) != "removed" })
        #expect(!lines.contains { ($0["path"] as? String) == "fresh.md" })
    }

    @Test func datalessFilesAreNeverReadAndKeepTheirRows() async throws {
        #expect(ObsidianVaultWalker.isDataless(flags: 0x4000_0000))
        #expect(!ObsidianVaultWalker.isDataless(flags: 0))
        let fixture = try Fixture()
        try fixture.write("away.md", "text")
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: afterClose)
        await engine.closeDueWindows(now: afterClose.addingTimeInterval(3600))
        let before = try await fixture.outboxLines(engine).count

        // Mark it dataless and change its stored bytes, which a read would see.
        fixture.walkHook.value = { walk in walk.notes["away.md"]?.isPlaceholder = true }
        try fixture.write("away.md", "text changed", at: date("2026-11-08T23:00:00-07:00"))
        let t1 = afterClose.addingTimeInterval(4000)
        let snap = await engine.scan(now: t1)
        #expect(snap.notOnDevice == 1)
        await engine.closeDueWindows(now: t1.addingTimeInterval(3600))
        #expect(try await fixture.outboxLines(engine).count == before)
    }

    @Test func datalessFolderKeepsItsNotesAsNotOnThisDevice() async throws {
        let fixture = try Fixture()
        try fixture.write("folder/inside.md", "text")
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: afterClose)
        fixture.walkHook.value = { walk in
            walk.notes["folder/inside.md"] = nil
            walk.unreachableDirectories.insert("folder")
        }
        let t1 = afterClose.addingTimeInterval(600)
        var snap = await engine.scan(now: t1)
        snap = await engine.scan(now: t1.addingTimeInterval(120))
        #expect(snap.notOnDevice == 1)
        await engine.closeDueWindows(now: t1.addingTimeInterval(3600))
        #expect(try await fixture.outboxLines(engine).allSatisfy { ($0["change"] as? String) != "removed" })
    }

    @Test func mtimeInTheFutureUsesTheObservedTime() async throws {
        let fixture = try Fixture()
        let now = date("2026-11-08T10:00:00-07:00")
        try fixture.write("future.md", "x", at: date("2026-12-01T00:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: now)
        await engine.closeDueWindows(now: now.addingTimeInterval(3600))
        let first = try #require(try await fixture.outboxLines(engine).first)
        #expect(first["changed_at"] as? String == "2026-11-08T10:00:00-07:00")
    }

    @Test func mtimeNotLaterThanLastReportedWithChangedContentUsesTheObservedTime() async throws {
        let fixture = try Fixture()
        try fixture.write("n.md", "first", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        // Same size, different words, an mtime that isn't later: a sync tool restored it.
        try fixture.write("n.md", "other", at: date("2026-11-08T08:00:00-07:00"))
        try fixture.setMtime("n.md", date("2026-11-08T07:59:00-07:00"))
        await engine.scan(now: date("2026-11-08T10:00:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T10:00:00-07:00")
        #expect(lines[0]["text"] as? String == "other")
    }

    @Test func unchangedMtimeAndSizeReadNothingAndAnUnchangedHashReportsNothing() async throws {
        let fixture = try Fixture()
        try fixture.write("n.md", "same", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        await engine.scan(now: date("2026-11-08T10:00:00-07:00"))
        // Touched: mtime moved, same bytes.
        try fixture.setMtime("n.md", date("2026-11-08T09:30:00-07:00"))
        await engine.scan(now: date("2026-11-08T11:00:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T12:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)
    }

    @Test func renameIsPairedByFileIDWithItsObservedTime() async throws {
        let fixture = try Fixture()
        try fixture.write("inbox/Alex.md", "Alex likes rivers.\n", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.rename("inbox/Alex.md", to: "people/Alex Rivera.md")
        await engine.scan(now: date("2026-11-08T09:43:33-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:30:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "renamed")
        #expect(lines[0]["previous_path"] as? String == "inbox/Alex.md")
        #expect(lines[0]["path"] as? String == "people/Alex Rivera.md")
        #expect(lines[0]["text"] as? String == "Alex likes rivers.\n")
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:43:33-07:00")
    }

    /// Two notes known to the journal and delivered, with the scan that saw them at 09:30.
    private func deliveredPair(_ fixture: Fixture) async throws -> ObsidianEngine {
        try fixture.write("a.md", "the note", at: date("2026-11-08T08:00:00-07:00"))
        try fixture.write("linker.md", "see [[a]]", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:31:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }
        return engine
    }

    @Test func aRenameLandsInTheEarlierWindowOfAnEditInItsScan() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredPair(fixture)

        try fixture.rename("a.md", to: "b.md")
        try fixture.write("linker.md", "see [[b]]", at: date("2026-11-08T09:44:50-07:00"))
        try fixture.write("later.md", "also this scan", at: date("2026-11-08T09:45:05-07:00"))
        await engine.scan(now: date("2026-11-08T09:45:20-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:30:00-07:00"))

        let lines = try await fixture.outboxLines(engine)
        let rename = try #require(line(lines, "b.md"))
        let edit = try #require(line(lines, "linker.md"))
        #expect(rename["change"] as? String == "renamed")
        #expect(rename["changed_at"] as? String == "2026-11-08T09:44:50-07:00")
        #expect(rename["observed_at"] as? String == "2026-11-08T09:45:20-07:00")
        #expect(edit["changed_at"] as? String == "2026-11-08T09:44:50-07:00")
        let windows = await engine.outboxFiles().map(\.window.segment)
        #expect(windows.first == "094000_300")
    }

    @Test func aRenameTakesTheEarliestEditHoweverManyThereAre() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredPair(fixture)

        try fixture.rename("a.md", to: "b.md")
        try fixture.write("linker.md", "see [[b]]", at: date("2026-11-08T09:44:59-07:00"))
        try fixture.write("other.md", "first sight", at: date("2026-11-08T09:41:10-07:00"))
        await engine.scan(now: date("2026-11-08T09:45:20-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:30:00-07:00"))
        let rename = try #require(line(try await fixture.outboxLines(engine), "b.md"))
        #expect(rename["changed_at"] as? String == "2026-11-08T09:41:10-07:00")
    }

    @Test func aRenameWithAnEditOfItsOwnAnchorsAPlainRename() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredPair(fixture)

        try fixture.rename("a.md", to: "b.md")
        try fixture.rename("linker.md", to: "moved.md")
        try fixture.write("moved.md", "see [[b]]", at: date("2026-11-08T09:44:50-07:00"))
        await engine.scan(now: date("2026-11-08T09:45:20-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:30:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(line(lines, "moved.md")?["changed_at"] as? String == "2026-11-08T09:44:50-07:00")
        #expect(line(lines, "b.md")?["changed_at"] as? String == "2026-11-08T09:44:50-07:00")
    }

    @Test func anEditNotNewerThanThePreviousScanDoesNotMoveARename() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredPair(fixture)

        try fixture.rename("a.md", to: "b.md")
        // Restored by a sync tool with an mtime from before the 09:30 scan.
        try fixture.write("linker.md", "see [[b]] restored", at: date("2026-11-08T09:20:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:45:20-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:30:00-07:00"))
        let rename = try #require(line(try await fixture.outboxLines(engine), "b.md"))
        #expect(rename["changed_at"] as? String == "2026-11-08T09:45:20-07:00")
    }

    @Test func aTouchOrAFutureMtimeDoesNotMoveARename() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredPair(fixture)

        try fixture.rename("a.md", to: "b.md")
        try fixture.setMtime("linker.md", date("2026-11-08T09:44:50-07:00")) // same bytes
        try fixture.write("future.md", "from a fast clock", at: date("2026-11-08T09:59:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:45:20-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:30:00-07:00"))
        let rename = try #require(line(try await fixture.outboxLines(engine), "b.md"))
        #expect(rename["changed_at"] as? String == "2026-11-08T09:45:20-07:00")
    }

    @Test func thePreviousScanTimeSurvivesTheAppBeingOff() async throws {
        let fixture = try Fixture()
        _ = try await deliveredPair(fixture)

        try fixture.rename("a.md", to: "b.md")
        try fixture.write("linker.md", "see [[b]]", at: date("2026-11-08T09:44:50-07:00"))
        let reopened = await fixture.makeEngine()
        await reopened.scan(now: date("2026-11-08T12:00:00-07:00"))
        await reopened.closeDueWindows(now: date("2026-11-08T13:00:00-07:00"))
        let rename = try #require(line(try await fixture.outboxLines(reopened), "b.md"))
        #expect(rename["changed_at"] as? String == "2026-11-08T09:44:50-07:00")
    }

    @Test func aRenameWithNothingElseInItsScanKeepsTheObservedTime() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredPair(fixture)

        try fixture.rename("a.md", to: "b.md")
        await engine.scan(now: date("2026-11-08T09:45:20-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:30:00-07:00"))
        let rename = try #require(line(try await fixture.outboxLines(engine), "b.md"))
        #expect(rename["changed_at"] as? String == "2026-11-08T09:45:20-07:00")
    }

    @Test func renameWithAnEditTakesTheChangedRule() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "one", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.rename("a.md", to: "b.md")
        try fixture.write("b.md", "two", at: date("2026-11-08T09:40:15-07:00"))
        await engine.scan(now: date("2026-11-08T09:43:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:30:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "renamed")
        #expect(lines[0]["text"] as? String == "two")
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:40:15-07:00")
    }

    @Test func aDeleteThenCreateIsPairedByContent() async throws {
        let fixture = try Fixture()
        try fixture.write("old.md", "same words", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        // The new file exists before the old goes, so it can't share the old inode.
        try fixture.write("new.md", "same words", at: date("2026-11-08T08:00:00-07:00"))
        try fixture.delete("old.md")
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "renamed")
        #expect(lines[0]["previous_path"] as? String == "old.md")
        #expect(lines[0]["path"] as? String == "new.md")
    }

    @Test func deleteIsHeldOneScanAndStampedWhenFirstMissed() async throws {
        let fixture = try Fixture()
        try fixture.write("gone.md", "bye", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.delete("gone.md")
        await engine.scan(now: date("2026-11-08T09:44:33-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        await engine.scan(now: date("2026-11-08T09:47:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "removed")
        #expect(lines[0]["path"] as? String == "gone.md")
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:44:33-07:00")
        #expect(lines[0]["observed_at"] as? String == "2026-11-08T09:44:33-07:00")
        #expect(lines[0]["text"] is NSNull)
        #expect(lines[0]["content_hash"] is NSNull)
    }

    @Test func aDeleteThenCreateAcrossTwoScansIsARename() async throws {
        let fixture = try Fixture()
        try fixture.write("old.md", "same words", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.delete("old.md")
        await engine.scan(now: date("2026-11-08T09:00:00-07:00"))
        try fixture.write("elsewhere/new.md", "same words", at: date("2026-11-08T08:00:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:01:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "renamed")
        #expect(lines[0]["previous_path"] as? String == "old.md")
    }

    @Test func onlyOneLinePerNotePerWindow() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "v1", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:40:30-07:00"))
        try fixture.write("a.md", "v2", at: date("2026-11-08T09:42:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:43:00-07:00"))
        try fixture.write("a.md", "v3", at: date("2026-11-08T09:44:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:44:30-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["text"] as? String == "v3")
        #expect(await engine.snapshot().waiting == 1)
    }

    @Test func aRenamedNoteEditedInItsWindowStaysARenameWithLatestText() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "one", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.rename("a.md", to: "b.md")
        await engine.scan(now: date("2026-11-08T09:40:30-07:00"))
        try fixture.write("b.md", "two", at: date("2026-11-08T09:41:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:42:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "renamed")
        #expect(lines[0]["text"] as? String == "two")
    }

    @Test func aNoteSeenAndRemovedBeforeSendingLeavesNothing() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "fleeting", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:40:30-07:00"))
        try fixture.delete("a.md")
        await engine.scan(now: date("2026-11-08T09:41:30-07:00"))
        await engine.scan(now: date("2026-11-08T09:42:30-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)
        #expect(await engine.snapshot().waiting == 0)
    }

    @Test func aChangeToAnAlreadySentWindowMovesLater() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "v1", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:40:30-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:46:31-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.write("a.md", "v2", at: date("2026-11-08T09:44:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:47:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:47:00-07:00")
        #expect(lines[0]["observed_at"] as? String == "2026-11-08T09:47:00-07:00")
    }

    @Test func aDeleteFirstMissedInASentWindowUsesTheConfirmingScan() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "v1", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:40:30-07:00"))

        try fixture.delete("a.md")
        // First missed inside the note's window, confirmed after that window has been sent.
        await engine.scan(now: date("2026-11-08T09:44:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:46:31-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }
        await engine.scan(now: date("2026-11-08T09:50:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "removed")
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:50:00-07:00")
    }

    @Test func aGoneVaultReportsNothing() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "v1", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        let aside = fixture.base.appendingPathComponent("moved-away")
        try FileManager.default.moveItem(at: fixture.root, to: aside)
        var snap = await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        #expect(snap.vaultUnreadable)
        snap = await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        #expect(snap.vaultUnreadable)
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        // A folder with no .obsidian is no better than a missing one.
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        snap = await engine.scan(now: date("2026-11-08T11:30:00-07:00"))
        #expect(snap.vaultUnreadable)
        await engine.closeDueWindows(now: date("2026-11-08T12:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.moveItem(at: aside, to: fixture.root)
        snap = await engine.scan(now: date("2026-11-08T13:00:00-07:00"))
        #expect(snap.vaultUnreadable == false)
        await engine.closeDueWindows(now: date("2026-11-08T14:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)
    }

    @Test func creatingAnEngineTouchesNothingUntilItLoads() async throws {
        let fixture = try Fixture()
        let engine = ObsidianEngine(directory: fixture.store)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.path))
        await engine.load()
        #expect(FileManager.default.fileExists(atPath: fixture.store.appendingPathComponent("pending").path))
    }

    @Test(arguments: [0o444, 0o000])
    func aFolderThatCantBeListedInFullIsNotADelete(mode: Int) async throws {
        let fixture = try Fixture()
        try fixture.write("folder/inside.md", "text", at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        try fixture.setPermissions("folder", mode)
        defer { try? fixture.setPermissions("folder", 0o755) }
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        let during = await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        #expect(during.partUnreadable)
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        try fixture.setPermissions("folder", 0o755)
        await engine.scan(now: date("2026-11-08T11:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T13:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)
    }

    private func deliveredNote(_ fixture: Fixture, _ path: String = "old.md", _ text: String = "same words") async throws -> ObsidianEngine {
        try fixture.write(path, text, at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }
        return engine
    }

    @Test func aHeldDeleteWaitsWhileAPlaceholderCouldBeItsNewName() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture)

        try fixture.rename("old.md", to: "new.md")
        fixture.walkHook.value = { walk in walk.notes["new.md"]?.isPlaceholder = true }
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        let held = await engine.scan(now: date("2026-11-08T09:50:00-07:00"))
        #expect(held.partUnreadable)
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        fixture.walkHook.value = nil
        await engine.scan(now: date("2026-11-08T11:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T13:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "renamed")
        #expect(lines[0]["previous_path"] as? String == "old.md")
    }

    @Test func aHeldDeleteWaitsWhileAFolderWithNoRowsCantBeSeen() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture)

        try fixture.delete("old.md")
        fixture.walkHook.value = { walk in walk.unreachableDirectories.insert("elsewhere") }
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        let held = await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        #expect(held.partUnreadable)
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        fixture.walkHook.value = nil
        await engine.scan(now: date("2026-11-08T11:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T13:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "removed")
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:30:00-07:00")
    }

    @Test func aDeletedRenameDoesNotOverwriteANewNoteAtTheOldPath() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture, "a.md", "original")

        try fixture.rename("a.md", to: "b.md")
        await engine.scan(now: date("2026-11-08T09:40:30-07:00"))
        try fixture.write("a.md", "a new note here", at: date("2026-11-08T09:40:45-07:00"))
        await engine.scan(now: date("2026-11-08T09:41:00-07:00"))
        try fixture.delete("b.md")
        await engine.scan(now: date("2026-11-08T09:42:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:43:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["path"] as? String == "a.md")
        #expect(lines[0]["change"] as? String == "changed")
        #expect(lines[0]["text"] as? String == "a new note here")
    }

    @Test func anUnreadableNewNameDoesNotBecomeADeletePairedByFileID() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture)

        try fixture.rename("old.md", to: "new.md")
        try fixture.setPermissions("new.md", 0o000)
        defer { try? fixture.setPermissions("new.md", 0o644) }
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        try fixture.setPermissions("new.md", 0o644)
        await engine.scan(now: date("2026-11-08T11:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T13:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "renamed")
    }

    @Test func anUnreadableNewNameDoesNotBecomeADeletePairedByContent() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture)

        try fixture.write("new.md", "same words", at: date("2026-11-08T08:00:00-07:00"))
        try fixture.delete("old.md")
        try fixture.setPermissions("new.md", 0o000)
        defer { try? fixture.setPermissions("new.md", 0o644) }
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        try fixture.setPermissions("new.md", 0o644)
        await engine.scan(now: date("2026-11-08T11:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T13:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "renamed")
    }

    @Test func aPlaceholderOfAnotherSizeDoesNotHoldADelete() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture)

        try fixture.delete("old.md")
        try fixture.write("never-local.md", "a different length entirely", at: date("2026-11-08T08:00:00-07:00"))
        fixture.walkHook.value = { walk in walk.notes["never-local.md"]?.isPlaceholder = true }
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        let snap = await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        #expect(!snap.partUnreadable)
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).first?["change"] as? String == "removed")
    }

    @Test func anUnreadableNoteOfAnotherSizeShowsAttentionAndDoesNotHoldADelete() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture)

        try fixture.delete("old.md")
        try fixture.write("locked.md", "a different length entirely", at: date("2026-11-08T08:00:00-07:00"))
        try fixture.setPermissions("locked.md", 0o000)
        defer { try? fixture.setPermissions("locked.md", 0o644) }
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        let snap = await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        #expect(snap.partUnreadable)
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "removed")
        #expect(lines[0]["path"] as? String == "old.md")
    }

    @Test func aNoteMovedAfterGrowingPastTheLimitIsNotADelete() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture)

        try fixture.rename("old.md", to: "moved.md")
        try fixture.write("moved.md", String(repeating: "x", count: ObsidianWire.maxNoteBytes + 1))
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        let snap = await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        #expect(snap.tooLarge == 1)
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)
    }

    @Test func aClockMovedBackDoesNotHoldAChange() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "v1", at: date("2026-11-08T10:01:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T10:02:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:06:31-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        // The window sent is 10:00; the clock now reads an hour before it.
        try fixture.write("a.md", "v2", at: date("2026-11-08T08:59:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:00:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:30:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["text"] as? String == "v2")
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:00:00-07:00")
    }

    @Test func aChangeSeenInsideTheSentWindowWaitsForTheNextScan() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "v1", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:41:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:46:31-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }

        // Clock back into the sent window: one line per note per window still holds.
        try fixture.write("a.md", "v2", at: date("2026-11-08T09:42:30-07:00"))
        await engine.scan(now: date("2026-11-08T09:43:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:46:31-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)

        await engine.scan(now: date("2026-11-08T09:47:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["text"] as? String == "v2")
        #expect(lines[0]["changed_at"] as? String == "2026-11-08T09:47:00-07:00")
    }

    @Test func aPureRenameIsNeverStampedBeforeTheNotesLatestChange() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "v1", at: date("2026-11-08T09:59:30-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T10:00:00-07:00"))

        try fixture.rename("a.md", to: "b.md")
        await engine.scan(now: date("2026-11-08T09:50:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        let rename = try #require(line(try await fixture.outboxLines(engine), "b.md"))
        #expect(rename["changed_at"] as? String == "2026-11-08T09:59:30-07:00")
        #expect(rename["observed_at"] as? String == "2026-11-08T09:50:00-07:00")
    }

    @Test func aVaultsTableSurvivesSwitchingAndCancelAndFindsADeleteLater() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture, "kept.md")
        let tables = fixture.store.appendingPathComponent("tables", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tables.path).count == 1)

        let other = fixture.base.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try Data("second vault".utf8).write(to: other.appendingPathComponent("second.md"))
        await engine.adoptVault(root: other, name: "Other")
        await engine.scan(now: date("2026-11-08T09:10:00-07:00"))
        await engine.discardUnsentVault()
        #expect(try FileManager.default.contentsOfDirectory(atPath: tables.path).count == 1)

        // While another vault was chosen and cancelled, a note in the first was deleted.
        try fixture.delete("kept.md")
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(lines.count == 1)
        #expect(lines[0]["change"] as? String == "removed")
        #expect(lines[0]["path"] as? String == "kept.md")
        #expect(await engine.currentState().firstSendCleared)
    }

    @Test func aNoteMissingFromAVaultSwitchedAwayIsStillItsOwn() async throws {
        let fixture = try Fixture()
        let engine = try await deliveredNote(fixture, "kept.md")
        let other = fixture.base.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        await engine.adoptVault(root: other, name: "Other")
        await engine.setFirstSendCleared()
        // The second vault has nothing in it; the first's rows must not read as missing here.
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:40:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)
    }

    @Test func theSamePathInTwoVaultsIsTwoWaitingChanges() async throws {
        let fixture = try Fixture()
        try fixture.write("same.md", "from notes", at: date("2026-11-08T09:40:05-07:00"))
        let other = fixture.base.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let note = other.appendingPathComponent("same.md")
        try Data("from other".utf8).write(to: note)
        try FileManager.default.setAttributes([.modificationDate: date("2026-11-08T09:40:05-07:00")], ofItemAtPath: note.path)
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:41:00-07:00"))
        await engine.adoptVault(root: other, name: "Other")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:42:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let lines = try await fixture.outboxLines(engine)
        #expect(Set(lines.compactMap { $0["vault"] as? String }) == ["Notes", "Other"])
    }

    @Test func aPendingEntryThatCantBeReadKeepsItsWindow() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "keep me", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:41:00-07:00"))
        let entry = try #require(try fixture.pendingEntryFiles().first)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: entry.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.path) }

        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        #expect(await engine.outboxFiles().isEmpty)
        #expect(await engine.snapshot().waiting == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.path)
        await engine.closeDueWindows(now: date("2026-11-08T10:01:00-07:00"))
        #expect(try await fixture.outboxLines(engine).compactMap { $0["text"] as? String } == ["keep me"])
    }

    @Test func aPendingEntryThatCantBeDecodedIsDroppedAndTheRestGo() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "one", at: date("2026-11-08T09:40:05-07:00"))
        try fixture.write("b.md", "two", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:41:00-07:00"))
        let entry = try #require(try fixture.pendingEntryFiles().first)
        try Data("not an entry".utf8).write(to: entry)

        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).count == 1)
        #expect(await engine.snapshot().waiting == 1)
    }

    @Test func nothingLeavesPendingUntilTheFirstSendIsCleared() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "one", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.scan(now: date("2026-11-08T09:41:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(await engine.outboxFiles().isEmpty)
        await engine.setFirstSendCleared()
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(await engine.outboxFiles().count == 1)
    }

    @Test func tooLargeNotesAreCountedAndNotSent() async throws {
        let fixture = try Fixture()
        try fixture.write("big.md", String(repeating: "x", count: ObsidianWire.maxNoteBytes + 1))
        try fixture.write("ok.md", "fine")
        // Passes the size check but escapes past the file limit.
        try fixture.writeData("control.md", Data(repeating: 0x01, count: 2 * 1024 * 1024))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        let snap = await engine.scan(now: date("2026-11-08T10:00:00-07:00"))
        #expect(snap.tooLarge == 2)
        await engine.closeDueWindows(now: date("2026-11-09T00:00:00-07:00"))
        let paths = try await fixture.outboxLines(engine).compactMap { $0["path"] as? String }
        #expect(paths == ["ok.md"])
    }

    @Test func invalidUTF8IsReadWithReplacementCharacters() async throws {
        let fixture = try Fixture()
        try fixture.writeData("latin.md", Data([0x61, 0xE9, 0x62]))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T10:00:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-09T00:00:00-07:00"))
        let first = try #require(try await fixture.outboxLines(engine).first)
        let text = "a\u{FFFD}b"
        #expect(first["text"] as? String == text)
        #expect(first["content_hash"] as? String == ObsidianWire.sha256Hex(Data(text.utf8)))
    }

    @Test func aNameTheJournalRefusesIsSkipped() async throws {
        let fixture = try Fixture()
        try fixture.write("good.md", "g")
        try fixture.write("bad\\name.md", "b")
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T10:00:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-09T00:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).compactMap { $0["path"] as? String } == ["good.md"])
    }

    @Test func theTableSurvivesTurningOffAndOnAndRestarting() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "v1", at: date("2026-11-08T08:00:00-07:00"))
        var engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T09:00:00-07:00"))
        for file in await engine.outboxFiles() { await engine.markDelivered(file) }
        await engine.setEnabled(false)

        engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T10:00:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)
    }

    @Test func outboxDeliversOldestWindowFirstAcrossDays() async throws {
        let fixture = try Fixture()
        try fixture.write("old.md", "o", at: date("2026-11-01T08:02:00-07:00"))
        try fixture.write("new.md", "n", at: date("2026-11-08T08:02:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T09:00:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T10:00:00-07:00"))
        let order = await engine.outboxFiles().map(\.window.day)
        #expect(order == ["20261101", "20261108"])
    }

    @Test func aRowNeverReportedLeavesNoRemovedLine() async throws {
        let fixture = try Fixture()
        try fixture.write("big.md", String(repeating: "x", count: ObsidianWire.maxNoteBytes + 1), at: date("2026-11-08T08:00:00-07:00"))
        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Notes")
        await engine.setFirstSendCleared()
        await engine.scan(now: date("2026-11-08T08:30:00-07:00"))
        try fixture.delete("big.md")
        await engine.scan(now: date("2026-11-08T09:00:00-07:00"))
        await engine.scan(now: date("2026-11-08T09:30:00-07:00"))
        await engine.closeDueWindows(now: date("2026-11-08T11:00:00-07:00"))
        #expect(try await fixture.outboxLines(engine).isEmpty)
    }
}

/// A journal that answers as each test scripts it.
private final class FakeJournal: ObsidianJournalTransport, @unchecked Sendable {
    let capabilitiesAnswer = Locked<[String]>([])
    let vaultsAnswer = Locked<[ObsidianJournalVault]>([])
    let outcomes = Locked<[ObsidianSendOutcome]>([])
    let sent = Locked<[String]>([])
    let serverURLs = Locked<[String]>([])
    let capabilityFails = Locked(false)
    let vaultsHook = Locked<(@Sendable () async -> Void)?>(nil)

    func capabilities(serverURL: String) async throws -> [String] {
        serverURLs.mutate { $0.append(serverURL) }
        if capabilityFails.value { throw URLError(.cannotConnectToHost) }
        return capabilitiesAnswer.value
    }

    func vaults(serverURL: String) async throws -> [ObsidianJournalVault] {
        await vaultsHook.value?()
        return vaultsAnswer.value
    }

    func send(file: ObsidianOutboxFile, serverURL: String, stagingDirectory: URL) async -> ObsidianSendOutcome {
        sent.mutate { $0.append(file.url.lastPathComponent) }
        var outcome: ObsidianSendOutcome = .delivered
        outcomes.mutate {
            if !$0.isEmpty { outcome = $0.removeFirst() }
        }
        return outcome
    }
}

@MainActor
@Suite("Obsidian source delivery")
struct ObsidianDeliveryTests {
    private let t0 = date("2026-11-08T10:00:00-07:00")

    private func outcome(_ status: Int, _ body: String) -> ObsidianSendOutcome {
        ObsidianDelivery.classify(statusCode: status, body: Data(body.utf8))
    }

    @Test func theAnswersTableIsHonoured() {
        #expect(outcome(200, #"{"status":"ok"}"#) == .delivered)
        #expect(outcome(200, #"{"status":"duplicate"}"#) == .delivered)
        #expect(outcome(200, #"{"status":"collision"}"#) == .delivered)
        #expect(outcome(500, #"{"status":"failed","reason_code":"segment_removed"}"#) == .delivered)
        #expect(outcome(409, #"{"reason_code":"obsidian_note_ahead"}"#) == .ahead)
        #expect(outcome(422, #"{"reason_code":"obsidian_note_invalid"}"#) == .invalid)
        #expect(outcome(500, #"{"reason_code":"anything_else"}"#) == .retry)
        #expect(outcome(200, "not json") == .retry)
        #expect(outcome(200, #"{"status":"something_new"}"#) == .retry)
    }

    /// The journal keeps its own memory in place of a note file, so these are its real answers.
    @Test func theJournalsRealAnswersAreDeliveredOverTheRealClient() async throws {
        let bodies = [
            #"{"status":"ok","segment":"094000_300","files":["note_transcript.md"],"bytes":60,"file_descriptors":[{"submitted":"note_transcript.md","written":"note_transcript.md","size":60,"sha256":"aaaa","disposition":"written"}],"meta":{}}"#,
            #"{"status":"duplicate","existing_segment":"094000_300","message":"Nothing new in this file","file_descriptors":[],"meta":{}}"#,
        ]
        for body in bodies {
            let fixture = try Fixture()
            let staging = fixture.base.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let note = fixture.base.appendingPathComponent("obsidian_abc.jsonl")
            try Data("{}\n".utf8).write(to: note)
            let store = ObserverURLProtocolStore()
            let client = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))
            store.registerRoute(path: "/app/devices/ingest", body: body)
            let answer = await client.send(
                file: ObsidianOutboxFile(url: note, window: ObsidianWindow(day: "20261108", segment: "094000_300")),
                serverURL: "http://journal.example", stagingDirectory: staging
            )
            #expect(answer == .delivered)
        }
    }

    @Test func scanIntervalScalesPastSixHundredMillisecondsAndCaps() {
        #expect(ObsidianVaultSource.scanInterval(afterScanTaking: 0.2) == 60)
        #expect(ObsidianVaultSource.scanInterval(afterScanTaking: 0.6) == 60)
        #expect(ObsidianVaultSource.scanInterval(afterScanTaking: 2) == 200)
        #expect(ObsidianVaultSource.scanInterval(afterScanTaking: 100) == 900)
    }

    private struct Harness {
        let fixture: Fixture
        let engine: ObsidianEngine
        let journal: FakeJournal
        let source: ObsidianVaultSource
        let clock: Locked<Date>
        let held: Locked<Bool>

        @MainActor func advance(_ seconds: TimeInterval) { clock.mutate { $0 = $0.addingTimeInterval(seconds) } }
        var serverURL: String { "http://127.0.0.1:9999/my-journal-identity-marker" }
    }

    private func makeHarness(url: String = "http://127.0.0.1:9999/my-journal-identity-marker") async throws -> Harness {
        let fixture = try Fixture()
        try fixture.write("a.md", "first note", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        let journal = FakeJournal()
        let clock = Locked(t0)
        let held = Locked(false)
        let source = ObsidianVaultSource(
            engine: engine,
            transport: journal,
            resolver: HomeBaseURLResolver { .url(url) },
            isHeld: { held.value },
            clock: { clock.value },
            configURL: fixture.base.appendingPathComponent("no-config.json"),
            runsLoop: false
        )
        return Harness(fixture: fixture, engine: engine, journal: journal, source: source, clock: clock, held: held)
    }

    @Test func nothingGoesToAJournalWithoutTheCapabilityThenItDelivers() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["calendar_notes"]
        await harness.source.turnOn(harness.fixture.root)
        await harness.source.tick()
        #expect(harness.source.phase == .waitingForJournalUpdate)
        #expect(harness.journal.sent.value.isEmpty)

        harness.journal.capabilitiesAnswer.value = ["calendar_notes", "obsidian_notes"]
        harness.advance(600)
        await harness.source.tick()
        #expect(harness.source.phase == .on)
        #expect(harness.journal.sent.value.count == 1)
        #expect(await harness.engine.outboxFiles().isEmpty)
        #expect(harness.source.snapshot.waiting == 0)
    }

    @Test func aJournalWithTheVaultAlreadyAsksFirstAndContinueDelivers() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.vaultsAnswer.value = [ObsidianJournalVault(vault: "Notes", device: "studio", lastSyncedAt: "2026-11-08T09:44:33-07:00")]
        await harness.source.turnOn(harness.fixture.root)
        await harness.source.tick()
        harness.advance(600)
        await harness.source.tick()
        #expect(harness.source.alreadySynced?.device == "studio")
        #expect(harness.source.axState == .confirming)
        #expect(harness.journal.sent.value.isEmpty)

        await harness.source.continueAfterAlreadySynced()
        harness.advance(60)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count == 1)
        // The warning is the first send's alone.
        harness.journal.sent.value = []
        try harness.fixture.write("b.md", "another", at: date("2026-11-08T11:00:00-07:00"))
        harness.advance(7200)
        await harness.source.tick()
        #expect(harness.source.alreadySynced == nil)
    }

    @Test func cancellingTheWarningLeavesTheSourceOffAndKeepsNothing() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.vaultsAnswer.value = [ObsidianJournalVault(vault: "Notes", device: nil, lastSyncedAt: nil)]
        await harness.source.turnOn(harness.fixture.root)
        await harness.source.tick()
        await harness.source.cancelAfterAlreadySynced()
        #expect(harness.source.phase == .off)
        #expect(harness.journal.sent.value.isEmpty)
        #expect(await harness.engine.outboxFiles().isEmpty)
        #expect(await harness.engine.snapshot().waiting == 0)
    }

    @Test func aVaultOnlyOtherDevicesHaveGoesAheadWithoutAsking() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.vaultsAnswer.value = [ObsidianJournalVault(vault: "Different", device: "studio", lastSyncedAt: nil)]
        await harness.source.turnOn(harness.fixture.root)
        harness.advance(600)
        await harness.source.tick()
        #expect(harness.source.alreadySynced == nil)
        #expect(harness.journal.sent.value.count == 1)
    }

    @Test func pauseHoldsWindowsAndKeepsScanningThenResumeDelivers() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        await harness.source.turnOn(harness.fixture.root)
        harness.held.value = true
        harness.advance(600)
        await harness.source.tick()
        #expect(harness.source.phase == .paused)
        #expect(harness.journal.sent.value.isEmpty)
        #expect(await harness.engine.outboxFiles().isEmpty)
        #expect(harness.source.snapshot.waiting == 1)

        // Scanning continues while paused.
        try harness.fixture.write("b.md", "written while paused", at: date("2026-11-08T10:09:00-07:00"))
        harness.advance(600)
        await harness.source.tick()
        #expect(harness.source.snapshot.waiting == 2)

        harness.held.value = false
        harness.advance(600)
        await harness.source.tick()
        #expect(harness.source.phase == .on)
        #expect(harness.journal.sent.value.count == 2)
    }

    @Test func turningOffStopsEverythingAndWhatsWaitingStays() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = []
        await harness.source.turnOn(harness.fixture.root)
        await harness.source.tick()
        await harness.source.turnOff()
        #expect(harness.source.phase == .off)
        harness.advance(3600)
        await harness.source.tick()
        #expect(harness.journal.sent.value.isEmpty)
        #expect(await harness.engine.snapshot().waiting == 1)

        // Turned on again, what was waiting goes.
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        await harness.source.turnOn(harness.fixture.root)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count == 1)
    }

    @Test func invalidFilesGoAsideAndTheRestCarryOn() async throws {
        let harness = try await makeHarness()
        try harness.fixture.write("c.md", "later", at: date("2026-11-08T09:50:00-07:00"))
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.outcomes.value = [.invalid, .delivered]
        await harness.source.turnOn(harness.fixture.root)
        harness.advance(1200)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count == 2)
        #expect(harness.source.phase == .needsAttention)
        #expect(await harness.engine.outboxFiles().isEmpty)
        #expect(harness.source.snapshot.setAside == 1)
    }

    @Test func aheadAndUnknownAnswersHoldAndRetryLater() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.outcomes.value = [.ahead]
        await harness.source.turnOn(harness.fixture.root)
        harness.advance(600)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count == 1)
        #expect(await harness.engine.outboxFiles().count == 1)

        // Inside the backoff nothing is resent.
        harness.advance(1)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count == 1)

        harness.journal.outcomes.value = [.retry]
        harness.advance(120)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count == 2)
        harness.advance(400)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count == 3)
        #expect(await harness.engine.outboxFiles().isEmpty)
    }

    @Test func noJournalIdentityIsHeld() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.outcomes.value = [.retry]
        await harness.source.turnOn(harness.fixture.root)
        harness.advance(600)
        await harness.source.tick()
        try harness.fixture.write("b.md", "still waiting", at: date("2026-11-08T10:12:00-07:00"))
        harness.advance(60)
        await harness.source.tick()
        #expect(harness.journal.serverURLs.value.contains { $0.contains("my-journal-identity-marker") })

        let held = try harness.fixture.heldBytes()
        #expect(!held.isEmpty)
        for bytes in held {
            #expect(bytes.range(of: Data("my-journal-identity-marker".utf8)) == nil)
            #expect(bytes.range(of: Data("journal_id".utf8)) == nil)
            #expect(bytes.range(of: Data("pairing".utf8)) == nil)
        }
        let stateData = try Data(contentsOf: harness.fixture.store.appendingPathComponent("state.json"))
        let stateKeys = try #require(try JSONSerialization.jsonObject(with: stateData) as? [String: Any]).keys
        #expect(Set(stateKeys) == ["enabled", "vaultPath", "vaultName", "firstSendCleared", "firstScanDone", "firstSyncTotal", "firstSyncDelivered", "lastScanMs"])
    }

    @Test func aFullRunLeavesTheVaultByteIdentical() async throws {
        let harness = try await makeHarness()
        try harness.fixture.write("sub/b.md", "note b", at: date("2026-11-08T09:40:05-07:00"))
        try harness.fixture.write("c.md", "note c", at: date("2026-11-08T09:40:05-07:00"))
        try harness.fixture.write("sub/keep.png", "not a note")
        try harness.fixture.write(".obsidian/workspace.json", "{}")
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        let before = try harness.fixture.vaultState()

        await harness.source.turnOn(harness.fixture.root)
        harness.advance(3600)
        await harness.source.tick()
        harness.advance(3600)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count >= 1)
        #expect(try harness.fixture.vaultState() == before)
    }

    @Test func foundVaultsComeFromObsidianListOnlyWhenStillVaults() async throws {
        let fixture = try Fixture()
        let notAVault = fixture.base.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: notAVault, withIntermediateDirectories: true)
        let config = fixture.base.appendingPathComponent("obsidian.json")
        let keyed = #"{"vaults":{"a":{"path":"\#(fixture.root.path)","ts":1},"b":{"path":"\#(notAVault.path)","ts":2}}}"#
        try Data(keyed.utf8).write(to: config)
        var found = ObsidianVaultLocator.foundVaults(configURL: config)
        #expect(found.map(\.name) == ["Notes"])

        let listed = #"{"vaults":[{"path":"\#(fixture.root.path)"}]}"#
        try Data(listed.utf8).write(to: config)
        found = ObsidianVaultLocator.foundVaults(configURL: config)
        #expect(found.count == 1)
        #expect(ObsidianVaultLocator.foundVaults(configURL: fixture.base.appendingPathComponent("missing.json")).isEmpty)
    }

    @Test func aFolderWithoutAnObsidianDirectoryIsRefusedAndSendsNothing() async throws {
        let harness = try await makeHarness()
        let plain = harness.fixture.base.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        await harness.source.turnOn(plain)
        #expect(harness.source.refusal == .notAVault)
        #expect(!harness.source.isOn)
        #expect(ObsidianVaultChoice.evaluate(plain) == .refusedNotAVault)
        let file = harness.fixture.base.appendingPathComponent("not-a-folder")
        try Data().write(to: file)
        #expect(ObsidianVaultChoice.evaluate(file) == .refusedNotAVault)
        let longName = harness.fixture.base.appendingPathComponent(String(repeating: "n", count: 129), isDirectory: true)
        try FileManager.default.createDirectory(at: longName.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        #expect(ObsidianVaultChoice.evaluate(longName) == .refusedUnusableName)
        await harness.source.tick()
        #expect(harness.journal.sent.value.isEmpty)
    }

    @Test func aReadableFolderWithObsidianTurnsOnAndAxTokensAreWired() async throws {
        let harness = try await makeHarness()
        #expect(harness.source.axState == .off)
        await harness.source.turnOn(harness.fixture.root)
        #expect(harness.source.isOn)
        #expect(harness.source.axState == .on)
    }

    @Test func aRemovedSegmentAnswerOverTheRealClientIsDeliveredAndNeverResent() async throws {
        let fixture = try Fixture()
        try fixture.write("a.md", "first note", at: date("2026-11-08T09:40:05-07:00"))
        let engine = await fixture.makeEngine()
        let store = ObserverURLProtocolStore()
        let client = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))
        store.registerRoute(path: "/api/system/status", body: #"{"capabilities":["obsidian_notes"]}"#)
        store.registerRoute(path: "/app/devices/ingest/obsidian/vaults", statusCode: 404, body: #"{"status":"not_found"}"#)
        store.registerRoute(path: "/app/devices/ingest", statusCode: 500, body: #"{"status":"failed","reason_code":"segment_removed"}"#)
        let clock = Locked(t0)
        let source = ObsidianVaultSource(
            engine: engine, transport: client,
            resolver: HomeBaseURLResolver { .url("http://journal.example") },
            isHeld: { false }, clock: { clock.value },
            configURL: fixture.base.appendingPathComponent("no-config.json"), runsLoop: false
        )
        await source.turnOn(fixture.root)
        clock.mutate { $0 = $0.addingTimeInterval(600) }
        await source.tick()
        let uploads = { store.snapshotRequests().filter { $0.url?.path == "/app/devices/ingest" }.count }
        #expect(uploads() == 1)
        #expect(await engine.outboxFiles().isEmpty)
        #expect(source.snapshot.waiting == 0)

        clock.mutate { $0 = $0.addingTimeInterval(3600) }
        await source.tick()
        #expect(uploads() == 1)
    }

    @Test func aWarningThatArrivesAfterTurningOffIsDropped() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.vaultsAnswer.value = [ObsidianJournalVault(vault: "Notes", device: "studio", lastSyncedAt: nil)]
        let source = harness.source
        harness.journal.vaultsHook.value = { await source.turnOff() }
        await source.turnOn(harness.fixture.root)
        await source.tick()
        #expect(source.alreadySynced == nil)
        #expect(source.phase == .off)
    }

    @Test func aNewVaultStaysOutOfTheOutboxAndCancelLeavesAnothersWaiting() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.outcomes.value = [.retry]
        await harness.source.turnOn(harness.fixture.root)
        harness.advance(600)
        await harness.source.tick()
        let waiting = await harness.engine.outboxFiles()
        #expect(waiting.count == 1)
        await harness.source.turnOff()

        let other = harness.fixture.base.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        let note = other.appendingPathComponent("second.md")
        try Data("second vault".utf8).write(to: note)
        try FileManager.default.setAttributes([.modificationDate: date("2026-11-08T09:41:00-07:00")], ofItemAtPath: note.path)
        harness.journal.vaultsAnswer.value = [ObsidianJournalVault(vault: "Other", device: "studio", lastSyncedAt: nil)]
        await harness.source.turnOn(other)
        harness.advance(3600)
        await harness.source.tick()
        #expect(harness.source.alreadySynced?.vault == "Other")
        #expect(await harness.engine.outboxFiles() == waiting)
        #expect(harness.source.snapshot.waiting == 2)

        await harness.source.cancelAfterAlreadySynced()
        #expect(harness.source.phase == .off)
        #expect(await harness.engine.outboxFiles() == waiting)
        #expect(await harness.engine.snapshot().waiting == 1)
        #expect(try harness.fixture.pendingEntryFiles().isEmpty)
    }

    @Test func aFileSetAsideIsTriedAgainOnTurnOnAndAtLaunch() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        harness.journal.outcomes.value = [.invalid, .invalid]
        await harness.source.turnOn(harness.fixture.root)
        harness.advance(600)
        await harness.source.tick()
        #expect(harness.source.phase == .needsAttention)

        // Turned off and on, it's tried again, and refused again it goes aside again.
        await harness.source.turnOff()
        await harness.source.turnOn(harness.fixture.root)
        #expect(harness.source.snapshot.setAside == 0)
        await harness.source.tick()
        #expect(harness.journal.sent.value.count == 2)
        #expect(harness.source.snapshot.setAside == 1)
        #expect(harness.source.phase == .needsAttention)

        // A fresh launch returns it to the outbox too, and an accepted file clears the state.
        let relaunched = await harness.fixture.makeEngine()
        #expect(await relaunched.snapshot().setAside == 0)
        #expect(await relaunched.outboxFiles().count == 1)
        for file in await relaunched.outboxFiles() { await relaunched.markDelivered(file) }
        #expect(await relaunched.snapshot().setAside == 0)
        #expect(await relaunched.snapshot().waiting == 0)
    }

    @Test func obsidianBeingOnIsNotEverySourceOff() async throws {
        let harness = try await makeHarness()
        harness.journal.capabilitiesAnswer.value = ["obsidian_notes"]
        var config = AppConfig(isBrowserIntakeEnabled: false)
        config.isMicrophoneCaptureEnabled = false
        config.isScreenCaptureEnabled = false
        let state = AppState.forSnapshot(config: config)
        state.obsidianSource = harness.source
        #expect(state.config.selectedSources.isEmpty)
        #expect(state.captureSourcesStatusText == UICopy.SOURCES_NONE)

        await harness.source.turnOn(harness.fixture.root)
        #expect(state.captureSourcesStatusText == "Obsidian is on · Notes")
        #expect(state.obsidianOnlyStatusText == "Obsidian is on · Notes")
        #expect(state.observationRowState == .observing)

        harness.held.value = true
        await harness.source.tick()
        #expect(state.captureSourcesStatusText == UICopy.Obsidian.stateLine(.paused, vaultName: "Notes"))
        #expect(state.observationRowState == .paused)

        await harness.source.turnOff()
        #expect(state.captureSourcesStatusText == UICopy.SOURCES_NONE)
        #expect(state.obsidianOnlyStatusText == nil)
    }

    @Test func theHealthCardDoesNotCallObsidianAloneSourcesOff() async throws {
        let state = AppState.forSnapshot(config: AppConfig(isBrowserIntakeEnabled: false))
        func summary(otherSourceOn: Bool) -> StatusHealthSummary {
            StatusHealthSummary.make(
                serviceMode: state.config.serviceMode, isRecording: false, isPaused: false,
                ownerPauseHeldIdle: false, held: false, hasPersistedPairing: true,
                uploadStatus: state.uploadCoordinator.status, pendingCount: 0,
                lastDeliveryOutcome: state.uploadCoordinator.lastJournalDeliveryOutcome,
                journalSlot: "your journal", now: Date(timeIntervalSince1970: 1_800_000_000),
                selectedSources: [], otherSourceOn: otherSourceOn, permittedSources: .all
            )
        }
        #expect(summary(otherSourceOn: false).axValue == "sources_off")
        #expect(summary(otherSourceOn: true).axValue != "sources_off")
        #expect(summary(otherSourceOn: true).axValue != "sources_unavailable")
    }

    @Test func aMissingCapabilitiesKeyMeansNoCapability() async throws {
        let store = ObserverURLProtocolStore()
        store.registerRoute(path: "/api/system/status", body: #"{"version":{"current":"2.0.70"}}"#)
        let client = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))
        let capabilities = try await client.capabilities(serverURL: "http://journal.example")
        #expect(capabilities.isEmpty)

        store.reset()
        store.registerRoute(path: "/api/system/status", body: #"{"capabilities":["obsidian_notes"]}"#)
        let listed = try await client.capabilities(serverURL: "http://journal.example")
        #expect(listed == ["obsidian_notes"])
    }

    @Test func anOlderJournalWithoutTheVaultRouteAnswers404AndTheListIsEmpty() async throws {
        let store = ObserverURLProtocolStore()
        store.registerRoute(path: "/app/devices/ingest/obsidian/vaults", statusCode: 404, body: #"{"status":"not_found"}"#)
        let client = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))
        #expect(try await client.vaults(serverURL: "http://journal.example").isEmpty)

        store.reset()
        store.registerRoute(
            path: "/app/devices/ingest/obsidian/vaults",
            body: #"{"vaults":[{"vault":"Notes","device":"studio","last_synced_at":"2026-11-08T09:44:33-07:00"}]}"#
        )
        let vaults = try await client.vaults(serverURL: "http://journal.example")
        #expect(vaults == [ObsidianJournalVault(vault: "Notes", device: "studio", lastSyncedAt: "2026-11-08T09:44:33-07:00")])
    }

    @Test func theRequestIsTheObsidianEnvelopeWithTheNoteFile() throws {
        let fixture = try Fixture()
        let file = fixture.base.appendingPathComponent("obsidian_abc.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let body = fixture.base.appendingPathComponent("body.tmp")
        _ = try IngestV3UploadRequestBuilder.build(
            baseURL: "http://journal.example", day: "20261108", segment: "094000_300",
            selectedFiles: [file], meta: nil, source: ObsidianWire.source, boundary: "b", bodyURL: body
        )
        let text = try String(contentsOf: body, encoding: .utf8)
        #expect(text.contains(#""source":"obsidian""#))
        #expect(text.contains(#"filename="obsidian_abc.jsonl""#))
        #expect(text.contains("Content-Type: application/jsonl"))
    }
}

@Suite("Obsidian vault at scale", .serialized)
struct ObsidianVaultScaleTests {
    private func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func peakRSSBytes() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return UInt64(usage.ru_maxrss)
    }

    /// Run with SOLSTONE_OBSIDIAN_MEASURE=1 and a filter for this test; prints the numbers.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOLSTONE_OBSIDIAN_MEASURE"] == "1"))
    func measureTwentyFiveThousandNotes() async throws {
        let fixture = try Fixture()
        let body = String(repeating: "A line of note text with #tags and [[links]] in it.\n", count: 80) // about 4 KB
        let spread = 400 * 24 * 3600
        let base = Int(date("2025-10-01T00:00:00-07:00").timeIntervalSince1970)
        for index in 0..<25_000 {
            let path = "folder\(index % 100)/note \(index).md"
            let mtime = Date(timeIntervalSince1970: TimeInterval(base + index * spread / 25_000))
            try fixture.write(path, body + "\(index)\n", at: mtime)
        }

        let engine = await fixture.makeEngine()
        await engine.adoptVault(root: fixture.root, name: "Scale")
        await engine.setFirstSendCleared()
        let beginFootprint = footprintBytes()
        func report(_ label: String, _ started: ContinuousClock.Instant) {
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("OBSIDIAN_MEASURE \(label): \(String(format: "%.3f", seconds))s footprint=\(footprintBytes() / 1_048_576)MB peakRSS=\(peakRSSBytes() / 1_048_576)MB")
        }

        var started = ContinuousClock.now
        var snapshot = await engine.scan(now: date("2026-11-08T10:00:00-07:00"))
        report("first scan (25k new, read+hash+write pending)", started)
        #expect(snapshot.waiting == 25_000)

        started = ContinuousClock.now
        await engine.closeDueWindows(now: date("2026-11-09T10:00:00-07:00"))
        report("close windows into outbox", started)
        snapshot = await engine.snapshot()
        #expect(snapshot.waiting == 25_000)

        started = ContinuousClock.now
        snapshot = await engine.scan(now: date("2026-11-10T10:00:00-07:00"))
        report("second scan, nothing changed (metadata only)", started)
        #expect(snapshot.waiting == 25_000)

        started = ContinuousClock.now
        try fixture.write("folder1/note 1.md", body + "edited\n", at: date("2026-11-10T09:59:00-07:00"))
        snapshot = await engine.scan(now: date("2026-11-11T10:00:00-07:00"))
        report("scan with one edit", started)
        let pendingEntries = (try? FileManager.default.contentsOfDirectory(atPath: fixture.store.appendingPathComponent("pending").path))?.count ?? 0
        let outboxBytes = (await engine.outboxFiles()).reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.url.path)[.size]) as? NSNumber)?.intValue ?? 0) }
        let tables = fixture.store.appendingPathComponent("tables", isDirectory: true)
        let tableName = (try? FileManager.default.contentsOfDirectory(atPath: tables.path).first) ?? "none"
        let tableBytes = ((try? FileManager.default.attributesOfItem(atPath: tables.appendingPathComponent(tableName).path)[.size]) as? NSNumber)?.intValue ?? 0
        print("OBSIDIAN_MEASURE store: outbox=\(outboxBytes / 1_048_576)MB table.json=\(tableBytes / 1024)KB pendingDirs=\(pendingEntries) footprintBegin=\(beginFootprint / 1_048_576)MB")
    }
}
