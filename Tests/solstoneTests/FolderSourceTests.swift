// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import solstone

@Suite("Folder source")
struct FolderSourceTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-folder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ url: URL, text: String, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func writeFile(_ url: URL, data: Data, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func makeSummary(
        id: String,
        name: String? = nil,
        mode: FolderMode = .on,
        state: DeckStateWord = .on,
        attention: FolderAttention? = nil
    ) -> FolderSummary {
        FolderSummary(
            id: id,
            name: name ?? id,
            path: "/tmp/\(id)",
            displayPath: id,
            mode: mode,
            state: state,
            attention: attention,
            kinds: .allOn,
            facet: nil,
            span: .last30Days,
            returning: false,
            widening: false,
            overlap: nil,
            preview: FolderPreviewSummary(),
            backfillDone: 0,
            backfillTotal: nil,
            waiting: 0,
            deliveredTotal: 0,
            lastAddedAt: nil,
            lastCheckedAt: nil,
            cantRead: 0,
            fallbackToDetails: 0,
            pausedByMac: false
        )
    }

    // MARK: - Classification, partials, junk, symlinks, net diff

    @Test func classifyMatchesRulesetV8AndSizeFallbacks() {
        let supported = FolderSupportedList.defaults
        let allOn = FolderKinds.allOn

        // Short markdown note
        let shortNote = Data("# Todo\n\n- check build\n- ship release\n".utf8)
        #expect(FolderSourceClassify.classifyFile(extension: "md", sizeBytes: Int64(shortNote.count), isScreenshot: false, noteBytes: shortNote, kinds: allOn, supported: supported) == (.notes, .content))

        // Structured prose (>= 1,500 words, >= 2 heading levels, >= 70% prose) promotes to document
        var structured = "# Chapter One\n\n## Section A\n\n"
        structured += Array(repeating: "prose", count: 1_550).joined(separator: " ")
        let structuredData = Data(structured.utf8)
        #expect(FolderSourceClassify.classifyFile(extension: "md", sizeBytes: Int64(structuredData.count), isScreenshot: false, noteBytes: structuredData, kinds: allOn, supported: supported) == (.documents, .content))

        // PDF -> document, VTT -> transcript, screenshot vs photo
        #expect(FolderSourceClassify.classifyFile(extension: "pdf", sizeBytes: 120_000, isScreenshot: false, noteBytes: nil, kinds: allOn, supported: supported) == (.documents, .content))
        #expect(FolderSourceClassify.classifyFile(extension: "vtt", sizeBytes: 4_000, isScreenshot: false, noteBytes: nil, kinds: allOn, supported: supported) == (.transcripts, .content))
        #expect(FolderSourceClassify.classifyFile(extension: "png", sizeBytes: 50_000, isScreenshot: true, noteBytes: nil, kinds: allOn, supported: supported) == (.screenshots, .content))
        #expect(FolderSourceClassify.classifyFile(extension: "png", sizeBytes: 50_000, isScreenshot: false, noteBytes: nil, kinds: allOn, supported: supported) == (.photos, .content))
        #expect(FolderSourceClassify.classifyFile(extension: "heic", sizeBytes: 50_000, isScreenshot: false, noteBytes: nil, kinds: allOn, supported: supported) == (.photos, .content))

        // Unsupported types (.docx, .dmg, .mp4) -> metadata-only when `other` is on, ignored when off
        #expect(FolderSourceClassify.classifyFile(extension: "docx", sizeBytes: 40_000, isScreenshot: false, noteBytes: nil, kinds: allOn, supported: supported) == (.other, .metadataOnly))
        #expect(FolderSourceClassify.classifyFile(extension: "dmg", sizeBytes: 12_000_000, isScreenshot: false, noteBytes: nil, kinds: allOn, supported: supported) == (.other, .metadataOnly))
        var noOther = allOn
        noOther.other = false
        #expect(FolderSourceClassify.classifyFile(extension: "docx", sizeBytes: 40_000, isScreenshot: false, noteBytes: nil, kinds: noOther, supported: supported) == (.other, .ignore))

        // Over 64 MiB falls back to metadata-only when `other` is on
        #expect(FolderSourceClassify.classifyFile(extension: "pdf", sizeBytes: supported.maxContentBytes + 1, isScreenshot: false, noteBytes: nil, kinds: noOther, supported: supported) == (.documents, .metadataOnly))

        // Disabling documents with `other` on sends PDFs as metadata-only; disabling both ignores them
        var noDocs = allOn
        noDocs.documents = false
        #expect(FolderSourceClassify.classifyFile(extension: "pdf", sizeBytes: 20_000, isScreenshot: false, noteBytes: nil, kinds: noDocs, supported: supported) == (.documents, .metadataOnly))
        noDocs.other = false
        #expect(FolderSourceClassify.classifyFile(extension: "pdf", sizeBytes: 20_000, isScreenshot: false, noteBytes: nil, kinds: noDocs, supported: supported) == (.documents, .ignore))

        // Binary NUL bytes in a .txt file fall back to `.other`
        #expect(FolderSourceClassify.classifyTextFile(Data([0x61, 0x00, 0x62]), supported: supported) == .other)
    }

    @Test func partialDownloadsJunkAndSymlinkConfinementWork() throws {
        #expect(FolderSourceClassify.isPartialDownload("archive.zip.crdownload"))
        #expect(FolderSourceClassify.isPartialDownload("Installer.dmg.download"))
        #expect(FolderSourceClassify.isPartialDownload("file.part"))
        #expect(FolderSourceClassify.isPartialDownload("draft.tmp"))
        #expect(!FolderSourceClassify.isPartialDownload("report.pdf"))

        #expect(FolderSourceClassify.isJunkEntry(".DS_Store"))
        #expect(FolderSourceClassify.isJunkEntry("~$budget.xlsx"))
        #expect(FolderSourceClassify.isJunkEntry("notes.md~"))
        #expect(FolderSourceClassify.isJunkEntry(".hidden"))
        #expect(!FolderSourceClassify.isJunkEntry("notes.md"))

        #expect(FolderSourceClassify.isValidRelativePath("sub/plan.md"))
        #expect(!FolderSourceClassify.isValidRelativePath("/abs/plan.md"))
        #expect(!FolderSourceClassify.isValidRelativePath("../escape.md"))
        #expect(!FolderSourceClassify.isValidRelativePath("bad\\path.md"))
        #expect(!FolderSourceClassify.isValidRelativePath("ctrl\u{0007}.md"))

        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("chosen", isDirectory: true)
        let inside = root.appendingPathComponent("ok.txt")
        let outside = base.appendingPathComponent("secret.txt")
        try writeFile(inside, text: "ok")
        try writeFile(outside, text: "secret")
        let inLink = root.appendingPathComponent("local-link.txt")
        let escLink = root.appendingPathComponent("escape-link.txt")
        try FileManager.default.createSymbolicLink(at: inLink, withDestinationURL: inside)
        try FileManager.default.createSymbolicLink(at: escLink, withDestinationURL: outside)

        let canonRoot = FolderSourceClassify.canonicalPath(root.path)
        #expect(FolderSourceClassify.symlinkStaysInside(canonicalRoot: canonRoot, entryPath: inLink.path))
        #expect(!FolderSourceClassify.symlinkStaysInside(canonicalRoot: canonRoot, entryPath: escLink.path))
    }

    @Test func netLineDiffSuppressesRevertsAndCapturesChanges() {
        #expect(FolderSourceClassify.netLineDiff(before: "a\nb\n", after: "a\nb\n") == nil)
        let diff = FolderSourceClassify.netLineDiff(before: "one\ntwo\nthree\n", after: "one\ntwo updated\nthree\nfour\n")
        #expect(diff != nil)
        #expect(diff?.contains("- two\n") == true)
        #expect(diff?.contains("+ two updated\n") == true)
        #expect(diff?.contains("+ four\n") == true)
        #expect(diff?.contains("one") == false)
    }

    @Test func overlapDetectsExactDuplicateObsidianScreenshotsAndParentChild() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = base.appendingPathComponent("Vault", isDirectory: true)
        let subVault = vault.appendingPathComponent("notes", isDirectory: true)
        let shots = base.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        let dl = base.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: subVault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)

        let obsOverlap = FolderSourceClassify.detectOverlap(
            candidatePath: subVault.path,
            obsidian: (path: vault.path, name: "field notes"),
            screenshots: nil,
            existingFolders: []
        )
        #expect(obsOverlap == .overlap(FolderOverlapInfo(targetKind: .obsidian, targetName: "field notes", targetFolderID: nil)))

        let shotOverlap = FolderSourceClassify.detectOverlap(
            candidatePath: base.appendingPathComponent("Pictures").path,
            obsidian: nil,
            screenshots: (path: shots.path, name: "Screenshots"),
            existingFolders: []
        )
        #expect(shotOverlap == .overlap(FolderOverlapInfo(targetKind: .screenshots, targetName: "Screenshots", targetFolderID: nil)))

        let exact = FolderSourceClassify.detectOverlap(
            candidatePath: dl.path,
            obsidian: nil,
            screenshots: nil,
            existingFolders: [(id: "downloads-1234abcd", path: dl.path, name: "Downloads")]
        )
        #expect(exact == .alreadyAdded(id: "downloads-1234abcd", name: "Downloads"))

        // Folder ID matches wire regex ^[a-z0-9][a-z0-9_-]{0,63}$
        let id = FolderSourceClassify.makeFolderID(name: "My Work Notes!", canonicalPath: dl.path)
        #expect(id.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil)
    }

    // MARK: - macOS metadata & wire contract

    @Test func macOSWhereFromsAndQuarantineMetadataParseCleanly() throws {
        let whereFroms = ["https://releases.example.com/app.dmg", "https://releases.example.com/downloads"]
        let plist = try PropertyListSerialization.data(fromPropertyList: whereFroms, format: .binary, options: 0)
        let parsedWF = FolderSourceMacReader.parseWhereFromsPlist(plist)
        #expect(parsedWF == whereFroms)

        let q = FolderSourceMacReader.parseQuarantine("0083;6928abcd;Google\\x20Chrome;11112222-3333-4444-5555-666677778888")
        #expect(q?.agent == "Google Chrome")
        #expect(q?.raw.hasPrefix("0083;") == true)

        // End-to-end real file xattr read on disk
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("installer.dmg")
        try writeFile(file, data: Data("dmg-bytes".utf8))
        let wfSet = plist.withUnsafeBytes { buf in
            setxattr(file.path, FolderSourceMacReader.whereFromsAttribute, buf.baseAddress, plist.count, 0, 0)
        }
        let qBytes = Data("0083;6928abcd;Safari;AAAA-BBBB".utf8)
        let qSet = qBytes.withUnsafeBytes { buf in
            setxattr(file.path, FolderSourceMacReader.quarantineAttribute, buf.baseAddress, qBytes.count, 0, 0)
        }
        #expect(wfSet == 0 && qSet == 0)

        let reader = FolderSourceMacReader()
        let (isShot, meta) = reader.readMetadata(path: file.path, canonicalRoot: FolderSourceClassify.canonicalPath(dir.path), isImage: false)
        #expect(!isShot)
        #expect(meta?.originURL == "https://releases.example.com/app.dmg")
        #expect(meta?.referrerURL == "https://releases.example.com/downloads")
        #expect(meta?.downloadedBy == "Safari")
        #expect(meta?.whereFroms == whereFroms)

        // Screenshot xattr sets isScreenshot + sourceApp
        let shotFile = dir.appendingPathComponent("shot.png")
        try writeFile(shotFile, data: Data([0x89, 0x50, 0x4E, 0x47]))
        let boolPlist = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        _ = boolPlist.withUnsafeBytes { buf in
            setxattr(shotFile.path, ScreenshotMac.screenCaptureAttribute, buf.baseAddress, boolPlist.count, 0, 0)
        }
        let (shotFlag, shotMeta) = reader.readMetadata(path: shotFile.path, canonicalRoot: FolderSourceClassify.canonicalPath(dir.path), isImage: true)
        #expect(shotFlag)
        #expect(shotMeta?.sourceApp != nil)
    }

    @Test func wireEncodingAndAnswersTableConformToContract() throws {
        let added = FolderActivityWireLine(
            event: "added",
            path: "notes/plan.md",
            previousPath: "should-be-omitted.md",
            at: "2026-11-27T14:06:10-07:00",
            observedAt: "2026-11-27T14:06:12-07:00",
            fileType: "md",
            size: 120,
            createdAt: "2026-11-27T14:06:09-07:00",
            modifiedAt: "2026-11-27T14:06:10-07:00",
            contentHash: String(repeating: "a", count: 64),
            part: "c_01.md",
            kindHint: "notes",
            platform: nil
        )
        let renamed = FolderActivityWireLine(
            event: "renamed",
            path: "notes/final.md",
            previousPath: "notes/plan.md",
            at: "2026-11-27T14:07:00-07:00",
            observedAt: "2026-11-27T14:07:02-07:00",
            fileType: "md",
            size: 120,
            createdAt: nil,
            modifiedAt: nil,
            contentHash: nil,
            part: nil,
            kindHint: nil,
            platform: nil
        )
        let removed = FolderActivityWireLine(
            event: "removed",
            path: "notes/old.md",
            previousPath: "bad.md",
            at: "2026-11-27T14:08:00-07:00",
            observedAt: "2026-11-27T14:08:02-07:00",
            fileType: "md",
            size: 10,
            createdAt: nil,
            modifiedAt: nil,
            contentHash: String(repeating: "b", count: 64),
            part: "c_02.md",
            kindHint: nil,
            platform: nil
        )

        let (filename, bytes) = try FolderSourceWire.encodeActivityJSONL([added, renamed, removed])
        let expectedHex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(filename == "folder_\(expectedHex).jsonl")
        #expect(bytes.last == 0x0A)

        let text = try #require(String(data: bytes, encoding: .utf8))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3)
        // `previous_path` omitted on added/removed, present on renamed
        #expect(!lines[0].contains("previous_path"))
        #expect(lines[1].contains("\"previous_path\":\"notes/plan.md\""))
        // `part` and `content_hash` forbidden on removed
        #expect(!lines[2].contains("\"part\""))
        #expect(!lines[2].contains("\"content_hash\""))
        #expect(!lines[2].contains("previous_path"))

        // Answers table
        #expect(FolderSourceWire.classifyAnswer(statusCode: 200, body: Data(#"{"status":"ok"}"#.utf8)) == .delivered())
        #expect(FolderSourceWire.classifyAnswer(statusCode: 200, body: Data(#"{"status":"duplicate"}"#.utf8)) == .delivered())
        #expect(FolderSourceWire.classifyAnswer(
            statusCode: 200,
            body: Data(#"{"status":"ok","refused_files":[{"path":"bad.pdf","part":"c_01.pdf","reason_code":"folder_file_invalid"}]}"#.utf8)
        ) == .deliveredWithRefused(serverRefused: ["bad.pdf"]))
        #expect(FolderSourceWire.classifyAnswer(
            statusCode: 400,
            body: Data(#"{"reason_code":"folder_file_invalid","refused_files":[{"path":"bad.pdf"}]}"#.utf8)
        ) == .allFilesRefused(["bad.pdf"]))
        #expect(FolderSourceWire.classifyAnswer(statusCode: 400, body: Data(#"{"reason_code":"folder_ahead"}"#.utf8)) == .ahead)
        #expect(FolderSourceWire.classifyAnswer(statusCode: 400, body: Data(#"{"reason_code":"folder_invalid"}"#.utf8)) == .invalid)
        #expect(FolderSourceWire.classifyAnswer(statusCode: 503, body: Data(#"{"reason_code":"journal_read_failed"}"#.utf8)) == .retry)

        // `/supported` parser honors dynamic document extensions without hardcoding
        let supportedJSON = Data(#"""
        {
          "version": 1,
          "ruleset_version": 9,
          "window_seconds": 300,
          "max_file_bytes": 67108864,
          "max_note_bytes": 4194304,
          "max_image_pixels": 67108864,
          "document_revision_cooldown_seconds": 1800,
          "kinds": {
            "notes": {"extensions": ["md", "txt"]},
            "documents": {"extensions": ["pdf", "docx", "md"], "thresholds": {"structured_prose_min_words": 1200, "structured_prose_min_heading_levels": 2, "long_prose_min_words": 4000}},
            "transcripts": {"extensions": ["vtt", "srt", "json"]},
            "screenshots": {"extensions": ["png", "webp"], "convert_to_png_on_device": ["heic"]},
            "photos": {"extensions": ["png", "jpg"], "convert_to_png_on_device": ["tiff"]}
          }
        }
        """#.utf8)
        let parsed = try #require(FolderSourceWire.parseSupportedList(supportedJSON))
        #expect(parsed.rulesetVersion == 9)
        #expect(parsed.documentRevisionCooldownMs == 1_800_000)
        #expect(parsed.documentExtensions.contains("docx"))
        #expect(!parsed.documentExtensions.contains("md"))
        #expect(parsed.transcriptExtensions == ["vtt", "srt", "json"])
        let border = String(repeating: "=", count: 62)
        let examples: [(String, String)] = [
            ("log", "--- Log opened Tue Sep 3 00:00:00 2024\n00:00 -!- lio has joined\n00:01 <@lio> Ready.\n00:01 < val> Over here.\n00:02 <@lio> Coming."),
            ("txt", "\(border)\nGuild: Potters\nChannel: firing\n\(border)\n[4/7/2025 10:02 AM] lio\nReady.\n[4/7/2025 10:03 AM] val\nComing.\n\(border)\nExported 2 message(s)\n\(border)"),
            ("txt", "Unknown Speaker  0:04\nThe wind is picking up.\nUnknown Speaker  2:13\nThe smaller boats have tied up.\nTranscribed by https://otter.ai"),
            ("txt", "\u{200e}[17/08/2025, 09:01:01] Pia: Where is the shelf?\n[17/08/2025, 09:01:03] Ivo: Around the corner."),
            ("txt", "8/17/25, 9:01 AM - Pia: Where is it?\n8/17/25, 9:02\u{202f}AM - Ivo: At the shop."),
            ("json", #"{"language":"en","text":"hi","segments":[{"start":0,"end":1,"text":"hi"}]}"#),
            ("json", #"{"text":"hi","segments":[{"speaker":"A","start":0,"end":2,"text":"hi"}]}"#),
            ("json", #"{"version":"1.0","segments":[{"startTime":0,"endTime":1,"body":"hi"}]}"#),
            ("json", #"[{"type":"message","ts":"1730000000.000123","user":"A","text":"hi"}]"#),
            ("json", #"{"type":"personal_chat","messages":[{"type":"message","date_unixtime":"1730000000","text":"hi"}]}"#),
            ("tsv", "start\tend\ttext\n0\t120\tReady."),
            ("csv", "Speaker,Start Time,End Time,Sentence\nA,00:01,00:03,\"Hello, there\""),
            ("html", #"<div class="page_body chat_page"><div class="history"><div class="message default"><div class="text">Hi</div></div></div></div>"#),
            ("md", "**User:** Hello\n**Assistant:** Here I am."),
            ("txt", "10:07:10 From Ivo : Hold it.\n10:07:12 From Pia to Everyone : Holding.")
        ]
        for (ext, item) in examples {
            #expect(FolderTranscriptLayout.recognizes(ext, data: Data(item.utf8)))
        }
        for (ext, item) in [("json", #"{"rows":[{"text":"hi"}]}"#), ("csv", "name,items\nA,2"),
                            ("tsv", "start\tend\ttext\nabc\t123\tbroken"), ("html", "<p>message history text</p>"),
                            ("txt", "Unknown Speaker  0:04\nWind.\nUnknown Speaker  2:13\nBoats."),
                            ("txt", "I meant to find this later.\nTranscribed by https://otter.ai"),
                            ("txt", "Guild: Potters\nChannel: firing\n[4/7/2025 10:02 AM] lio\nReady."),
                            ("log", "Kiln maintenance notes\n00:01 <@lio> Ready.\n00:02 < val> Over here.\n00:03 <@lio> Coming."),
                            ("txt", "Groceries:\nBread\nMilk")] {
            #expect(!FolderTranscriptLayout.recognizes(ext, data: Data(item.utf8)))
        }
        #expect(parsed.convertibleImageExtensions == ["heic", "tiff"])
    }

    @Test func bomMarkedUTF16NotesKeepTheirText() throws {
        for (bom, encoding) in [(Data([0xff, 0xfe]), String.Encoding.utf16LittleEndian),
                                (Data([0xfe, 0xff]), .utf16BigEndian)] {
            let bytes = bom + (try #require("Résumé".data(using: encoding)))
            #expect(FolderSourceClassify.classifyTextFile(bytes, supported: .defaults) == .notes)
            #expect(FolderSourceClassify.decodeText(bytes) == "Résumé")
        }
    }

    @Test func todayStartsAtLocalMidnightAndDeletedDetailsAreHeldUntilRescan() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Today", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tz = TimeZone(secondsFromGMT: -7 * 3600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let now = Date(timeIntervalSince1970: 1_795_700_000)
        let midnight = calendar.startOfDay(for: now)
        try writeFile(folder.appendingPathComponent("old.md"), text: "old", modified: midnight.addingTimeInterval(-1))
        try writeFile(folder.appendingPathComponent("today.md"), text: "today", modified: midnight)
        let transient = folder.appendingPathComponent("transient.bin")
        try writeFile(transient, text: "temporary", modified: midnight)
        let engine = FolderSourceEngine(directory: base.appendingPathComponent("state"), timeZone: { tz })
        guard case .added(let id) = await engine.checkAndAddFolder(rawPath: folder.path, overlapContext: .init()) else {
            Issue.record("folder selection failed")
            return
        }
        _ = await engine.selectSpan(id: id, span: .fromToday)
        let preview = try #require(await engine.computePreview(id: id, now: now))
        #expect(preview.summary.totalItems == 2)
        #expect(preview.summary.earliestMs == Int64(midnight.timeIntervalSince1970 * 1000))
        #expect(await engine.confirmFolder(id: id, now: now))
        try FileManager.default.removeItem(at: transient)
        let delivery = try #require(await engine.nextDelivery(now: now, ownerPaused: false))
        #expect(delivery.items.map(\.path) == ["today.md"])
    }

    // MARK: - Engine scenarios (note revert, 1h revision, rename, delete-before-send, pause, refused, restartFirstSetup)

    @Test func engineHandlesEndToEndLifecycleInvariants() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let stateDir = base.appendingPathComponent("state", isDirectory: true)
        let folder = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let totals = SourceTotals(directory: stateDir, clock: .init(now: Date(timeIntervalSince1970: 1_795_700_000), timeZone: TimeZone(secondsFromGMT: 0)!))
        let engine = FolderSourceEngine(
            directory: stateDir.appendingPathComponent("folders", isDirectory: true),
            reader: FolderSourceMacReader(),
            totals: totals,
            timeZone: { TimeZone(secondsFromGMT: 0)! }
        )

        // Seed 3 files: a note, a PDF, a .icloud stub, and a partial download
        let t0 = Date(timeIntervalSince1970: 1_795_700_000) // aligned cleanly
        try writeFile(folder.appendingPathComponent("note.md"), text: "line 1\nline 2\n", modified: t0.addingTimeInterval(-600))
        try writeFile(folder.appendingPathComponent("doc.pdf"), data: Data("%PDF-1.4\nhello".utf8), modified: t0.addingTimeInterval(-600))
        try writeFile(folder.appendingPathComponent(".evicted.pdf.icloud"), data: Data("stub".utf8), modified: t0.addingTimeInterval(-600))
        try writeFile(folder.appendingPathComponent("pending.zip.crdownload"), data: Data("partial".utf8), modified: t0.addingTimeInterval(-600))

        let pick = await engine.checkAndAddFolder(rawPath: folder.path, overlapContext: .init())
        guard case .added(let id) = pick else {
            Issue.record("expected .added, got \(pick)")
            return
        }

        // Preview counts only note.md + doc.pdf (skips .icloud stub and .crdownload partial)
        let previewPair = await engine.computePreview(id: id, now: t0)
        let summary = try #require(previewPair?.summary)
        #expect(summary.totalItems == 2)
        #expect(summary.contentItems == 2)
        #expect(summary.metadataOnlyItems == 0)

        // Confirm while unpaired: files queue locally, and first pairing (`restartFirstSetup`)
        // restarts setup but preserves the confirmed waiting queue so files deliver on connect.
        #expect(await engine.confirmFolder(id: id, now: t0))
        await engine.restartFirstSetup()
        let snapAfterFirstPair = await engine.snapshot(paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready)
        #expect(snapAfterFirstPair.folders.first?.mode == .settingUp)
        #expect(snapAfterFirstPair.folders.first?.waiting == 2)

        let firstUpload = try #require(await engine.nextDelivery(now: t0, ownerPaused: false))
        #expect(firstUpload.items.count == 2)
        await engine.recordAnswer(.delivered(), for: firstUpload, now: t0)
        #expect(totals.view()?.foldersTotal == 2)

        #expect(await engine.confirmFolder(id: id, now: t0))
        #expect(await engine.nextDelivery(now: t0, ownerPaused: false) == nil)

        // Zero journal identity stored in ledger.json
        let ledgerBytes = try Data(contentsOf: stateDir.appendingPathComponent("folders/ledger.json"))
        let ledgerStr = try #require(String(data: ledgerBytes, encoding: .utf8))
        #expect(!ledgerStr.contains("fingerprint"))
        #expect(!ledgerStr.contains("127.0.0.1"))
        #expect(!ledgerStr.contains("journal_id"))

        // Note edit + revert within same 5-minute window suppresses sending
        let t1 = t0.addingTimeInterval(60)
        try writeFile(folder.appendingPathComponent("note.md"), text: "line 1\nline 2\nline 3\n", modified: t1)
        await engine.scanAll(now: t1.addingTimeInterval(5))
        #expect(await engine.hasPendingUploads())
        // Revert back before window closes
        let t2 = t1.addingTimeInterval(30)
        try writeFile(folder.appendingPathComponent("note.md"), text: "line 1\nline 2\n", modified: t2)
        await engine.scanAll(now: t2.addingTimeInterval(5))
        #expect(await !engine.hasPendingUploads())

        // Document revision waits 1 full hour without saves
        let tDocSave = t0.addingTimeInterval(120)
        try writeFile(folder.appendingPathComponent("doc.pdf"), data: Data("%PDF-1.4\nrev 2".utf8), modified: tDocSave)
        await engine.scanAll(now: tDocSave.addingTimeInterval(10))
        #expect(await !engine.hasPendingUploads())
        // 30 minutes later: still cooling down
        await engine.scanAll(now: tDocSave.addingTimeInterval(1800))
        #expect(await !engine.hasPendingUploads())
        // 61 minutes later: revision becomes due!
        let tDocDue = tDocSave.addingTimeInterval(3660)
        await engine.scanAll(now: tDocDue)
        let revUpload = try #require(await engine.nextDelivery(now: tDocDue.addingTimeInterval(360), ownerPaused: false))
        #expect(revUpload.items.count == 1)
        #expect(revUpload.items[0].verb == .revised)
        #expect(revUpload.items[0].verb.wireEvent == "changed")
        await engine.recordAnswer(.delivered(), for: revUpload, now: tDocDue.addingTimeInterval(360))

        // Delete-before-send: drop a newly added file before its window closes -> nothing leaves!
        let tTemp = tDocDue.addingTimeInterval(600)
        let ephemeral = folder.appendingPathComponent("ephemeral.txt")
        try writeFile(ephemeral, text: "oops", modified: tTemp)
        await engine.scanAll(now: tTemp.addingTimeInterval(5))
        #expect(await engine.hasPendingUploads())
        try FileManager.default.removeItem(at: ephemeral)
        await engine.scanAll(now: tTemp.addingTimeInterval(10))
        #expect(await !engine.hasPendingUploads())
        #expect(await engine.nextDelivery(now: tTemp.addingTimeInterval(600), ownerPaused: false) == nil)

        // Rename of delivered file emits `renamed` with `previous_path`
        let tRen = tTemp.addingTimeInterval(700)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("note.md"), to: folder.appendingPathComponent("renamed-note.md"))
        await engine.scanAll(now: tRen)
        let renUpload = try #require(await engine.nextDelivery(now: tRen.addingTimeInterval(400), ownerPaused: false))
        #expect(renUpload.items.count == 1)
        #expect(renUpload.items[0].verb == .renamed)
        #expect(renUpload.items[0].path == "renamed-note.md")
        #expect(renUpload.items[0].previousPath == "note.md")
        await engine.recordAnswer(.delivered(), for: renUpload, now: tRen.addingTimeInterval(400))

        // Pause holds sync WITHOUT skipping changes; resume delivers them!
        #expect(await engine.pauseFolder(id: id))
        let tPaused = tRen.addingTimeInterval(1000)
        try writeFile(folder.appendingPathComponent("while-paused.md"), text: "captured while paused\n", modified: tPaused)
        await engine.scanAll(now: tPaused.addingTimeInterval(5))
        // Still held while paused (even after window closes)
        #expect(await engine.nextDelivery(now: tPaused.addingTimeInterval(400), ownerPaused: false) == nil)
        // Resume -> queued change delivers immediately!
        #expect(await engine.resumeFolder(id: id))
        let pausedUpload = try #require(await engine.nextDelivery(now: tPaused.addingTimeInterval(400), ownerPaused: false))
        #expect(await engine.canSend(pausedUpload))
        #expect(await engine.pauseFolder(id: id))
        #expect(await !engine.canSend(pausedUpload))
        #expect(await engine.resumeFolder(id: id))
        #expect(pausedUpload.items.contains { $0.path == "while-paused.md" })
        #expect(await engine.updateKinds(id: id, kinds: FolderKinds(notes: false)))
        #expect(await !engine.canSend(pausedUpload))
        let details = try #require(await engine.nextDelivery(now: tPaused.addingTimeInterval(400), ownerPaused: false))
        #expect(details.items.allSatisfy { $0.sourcePath == nil && $0.inlineNoteData == nil })
        await engine.recordAnswer(.delivered(), for: details, now: tPaused.addingTimeInterval(400))

        // Refused file falls back to details-only (`fallbackToDetails` increments ONLY once details land)
        #expect(await engine.updateKinds(id: id, kinds: FolderKinds(other: false)))
        let tBad = tPaused.addingTimeInterval(1000)
        try writeFile(folder.appendingPathComponent("corrupt.pdf"), data: Data("not-really-a-pdf".utf8), modified: tBad)
        await engine.scanAll(now: tBad.addingTimeInterval(5))
        let badUpload = try #require(await engine.nextDelivery(now: tBad.addingTimeInterval(400), ownerPaused: false))
        await engine.recordAnswer(.allFilesRefused(["corrupt.pdf"]), for: badUpload, now: tBad.addingTimeInterval(400))
        let snapBeforeFallbackLands = await engine.snapshot(paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready)
        #expect(snapBeforeFallbackLands.folders.first?.fallbackToDetails == 0)
        let fallbackUpload = try #require(await engine.nextDelivery(now: tBad.addingTimeInterval(405), ownerPaused: false))
        #expect(fallbackUpload.items.count == 1)
        #expect(fallbackUpload.items[0].path == "corrupt.pdf")
        #expect(fallbackUpload.items[0].sourcePath == nil)
        await engine.recordAnswer(.delivered(), for: fallbackUpload, now: tBad.addingTimeInterval(405))
        let snapAfterFallbackLands = await engine.snapshot(paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready)
        #expect(snapAfterFallbackLands.folders.first?.fallbackToDetails == 1)

        let offlineDate = tBad.addingTimeInterval(1200)
        let heldFile = folder.appendingPathComponent("offline.md")
        try writeFile(heldFile, text: "held for pairing", modified: offlineDate)
        await engine.scanAll(now: offlineDate.addingTimeInterval(10))
        await engine.restartFirstSetup()
        let snapAfterReset = await engine.snapshot(paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready)
        #expect(snapAfterReset.folders.first?.mode == .settingUp)
        let held = try #require(await engine.nextDelivery(now: offlineDate.addingTimeInterval(400), ownerPaused: false))
        #expect(held.items.map(\.path) == ["offline.md"])
        await engine.recordAnswer(.delivered(), for: held, now: offlineDate.addingTimeInterval(400))
        #expect(await engine.nextDelivery(now: offlineDate.addingTimeInterval(410), ownerPaused: false) == nil)
    }

    // MARK: - Declarations & SharedSources capability gate (contract § 9)

    @Test @MainActor func folderDeclarationsPrioritizeSeverityRespectCapAndGateOnCapability() async throws {
        var deck = DeckInputs()
        deck.screenOn = true
        deck.microphoneOn = true
        deck.terminalOn = true
        deck.terminalState = .running
        deck.browsersOn = false
        deck.obsidianState = .off

        // Create 70 folders across all modes: attention, paused, on, off, settingUp
        var list: [FolderSummary] = []
        list.append(makeSummary(id: "z-off", mode: .off, state: .off))
        list.append(makeSummary(id: "z-setup", mode: .settingUp, state: .settingUp))
        list.append(makeSummary(id: "b-attn", mode: .on, state: .needsAttention, attention: .missing))
        list.append(makeSummary(id: "a-attn", mode: .paused, state: .needsAttention, attention: .accessOff))
        list.append(makeSummary(id: "b-paused", mode: .paused, state: .paused))
        list.append(makeSummary(id: "a-paused", mode: .paused, state: .paused))
        for i in 0..<65 {
            let fid = String(format: "on-%02d", i)
            list.append(makeSummary(id: fid, mode: .on, state: .on))
        }
        deck.folders = FoldersSnapshot.compose(
            folders: list,
            paired: true,
            ownerPaused: false,
            journalNeedsUpdate: false,
            facets: [],
            facetsState: .ready,
            busy: false
        )

        let declared = deck.declarations(vaultConfirmed: false, browserConfigured: false, permissionsChecked: true)
        #expect(declared.count == 64)

        // All 3 non-folder sources appear first, never displaced
        #expect(declared[0].source == "audio")
        #expect(declared[1].source == "screen")
        #expect(declared[2].source == "terminal")

        // Next come attention (sorted by id), then paused (sorted by id), then on (sorted by id)
        #expect(declared[3] == SourceDeclaration(source: "folder", state: "needs_attention", detail: "a-attn"))
        #expect(declared[4] == SourceDeclaration(source: "folder", state: "needs_attention", detail: "b-attn"))
        #expect(declared[5] == SourceDeclaration(source: "folder", state: "paused", detail: "a-paused"))
        #expect(declared[6] == SourceDeclaration(source: "folder", state: "paused", detail: "b-paused"))
        #expect(declared[7] == SourceDeclaration(source: "folder", state: "on", detail: "on-00"))
        // off and settingUp are never emitted
        #expect(!declared.contains { $0.detail == "z-off" || $0.detail == "z-setup" })

        // Whole-Mac pause maps active `on` folders to `"paused"` while keeping `needs_attention`
        deck.ownerPaused = true
        let pausedDeclared = deck.declarations(vaultConfirmed: false, browserConfigured: false, permissionsChecked: true)
        #expect(pausedDeclared.first { $0.detail == "a-attn" }?.state == "needs_attention")
        #expect(pausedDeclared.first { $0.detail == "on-00" }?.state == "paused")

        // SharedSources omits `"folder"` when journal status omits `"folder"`, sends it when present
        final class FakeSharedTransport: SharedSourceTransport, @unchecked Sendable {
            var caps: [String]
            var sent: [[SourceDeclaration]] = []
            init(caps: [String]) { self.caps = caps }
            func systemStatus(serverURL: String) async throws -> JournalSystemStatus {
                JournalSystemStatus(capabilities: caps, sources_rev: "rev1")
            }
            func declareSources(_ sources: [SourceDeclaration], serverURL: String) async throws {
                sent.append(sources)
            }
            func knownSources(serverURL: String) async throws -> SharedSourceSnapshot {
                SharedSourceSnapshot(self_cid: nil, sources_rev: "rev1", devices: [])
            }
        }

        let suite = "folder-shared-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldTransport = FakeSharedTransport(caps: ["shared_sources"])
        let sharedOld = SharedSources(defaults: defaults, transport: oldTransport)
        let route = SharedSourceRoute(identity: "id1", port: 12345, incarnation: 1)
        sharedOld.currentRoute = { route }
        sharedOld.update(identity: "id1", route: route, sources: [
            SourceDeclaration(source: "audio", state: "on"),
            SourceDeclaration(source: "folder", state: "on", detail: "downloads-1234abcd"),
        ])
        await sharedOld.waitForPendingWork()
        #expect(oldTransport.sent == [[SourceDeclaration(source: "audio", state: "on")]])

        let newTransport = FakeSharedTransport(caps: ["shared_sources", "folder"])
        let sharedNew = SharedSources(defaults: defaults, transport: newTransport)
        sharedNew.currentRoute = { route }
        sharedNew.update(identity: "id1", route: route, sources: [
            SourceDeclaration(source: "audio", state: "on"),
            SourceDeclaration(source: "folder", state: "on", detail: "downloads-1234abcd"),
        ])
        await sharedNew.waitForPendingWork()
        #expect(newTransport.sent == [[
            SourceDeclaration(source: "audio", state: "on"),
            SourceDeclaration(source: "folder", state: "on", detail: "downloads-1234abcd"),
        ]])
    }

    @Test func worstSignalRollupAndTotalsWork() {
        let onF = makeSummary(id: "dl-1", name: "Downloads", mode: .on, state: .on)
        let pausedF = makeSummary(id: "docs-2", name: "Documents", mode: .paused, state: .paused)
        let setupF = makeSummary(id: "desk-3", name: "Desktop", mode: .settingUp, state: .settingUp)
        let attnF = makeSummary(id: "work-4", name: "Work", mode: .on, state: .needsAttention, attention: .accessOff)

        let s1 = FoldersSnapshot.compose(folders: [onF, pausedF, setupF, attnF], paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready, busy: false)
        #expect(s1.state == .needsAttention)

        let s2 = FoldersSnapshot.compose(folders: [onF, pausedF, setupF], paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready, busy: false)
        #expect(s2.state == .settingUp)

        let s3 = FoldersSnapshot.compose(folders: [onF, pausedF], paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready, busy: false)
        #expect(s3.state == .on)

        let s4 = FoldersSnapshot.compose(folders: [pausedF], paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready, busy: false)
        #expect(s4.state == .paused)

        let s5 = FoldersSnapshot.compose(folders: [], paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: [], facetsState: .ready, busy: false)
        #expect(s5.state == .readyToSetUp)

        var deck = DeckInputs()
        deck.folders = s1
        let tile = deriveDeckTile(.folders, deck)
        #expect(tile.source == .folders)
        #expect(tile.state == .needsAttention)
        #expect(tile.switchOn == nil)
    }

    @Test func evictedFileInNewerWindowDoesNotHeadOfLineBlockOlderWindow() async throws {
        final class DatalessOverrideReader: FolderSystemReading, @unchecked Sendable {
            private let base = FolderSourceMacReader()
            var datalessFileName: String?

            func homePath() -> String { base.homePath() }
            func checkFolderAccess(path: String) -> FolderWalkResult.RootStatus { base.checkFolderAccess(path: path) }
            func isThirdPartyStoragePath(_ path: String) -> Bool { base.isThirdPartyStoragePath(path) }
            func walk(rootPath: String, bookmark: Data?) -> FolderWalkResult { base.walk(rootPath: rootPath, bookmark: bookmark) }
            func probeFile(path: String, rootPath: String, bookmark: Data?) -> FolderFileProbe? {
                if let name = datalessFileName, path.hasSuffix("/" + name) {
                    return FolderFileProbe(isRegular: true, isSymlink: false, isDataless: true)
                }
                return base.probeFile(path: path, rootPath: rootPath, bookmark: bookmark)
            }
            func readMetadata(path: String, canonicalRoot: String, isImage: Bool) -> (isScreenshot: Bool, platform: FolderPlatformMetadata?) {
                base.readMetadata(path: path, canonicalRoot: canonicalRoot, isImage: isImage)
            }
            func readAndHash(path: String, canonicalRoot: String, expectedDevice: UInt64?, expectedInode: UInt64?, maxInlineBytes: Int?) -> FolderFileReadResult? {
                base.readAndHash(path: path, canonicalRoot: canonicalRoot, expectedDevice: expectedDevice, expectedInode: expectedInode, maxInlineBytes: maxInlineBytes)
            }
            func stageFile(sourcePath: String, canonicalRoot: String, destinationURL: URL, expectedSHA256: String?, convertToPNG: Bool, maxImagePixels: Int64, maxBytes: Int64) -> FolderStagedFileResult {
                base.stageFile(sourcePath: sourcePath, canonicalRoot: canonicalRoot, destinationURL: destinationURL, expectedSHA256: expectedSHA256, convertToPNG: convertToPNG, maxImagePixels: maxImagePixels, maxBytes: maxBytes)
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-hol-\(UUID().uuidString)", isDirectory: true)
        let folder = dir.appendingPathComponent("Mix", isDirectory: true)
        let state = dir.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tz = TimeZone(secondsFromGMT: -7 * 3600)!
        let tOld = Date(timeIntervalSince1970: 1_795_800_000) // earlier closed window
        let tNew = tOld.addingTimeInterval(600)               // newer closed window
        let tNow = tOld.addingTimeInterval(1200)

        let oldNote = folder.appendingPathComponent("older.md")
        let newNote = folder.appendingPathComponent("newer.md")
        try Data("older content\n".utf8).write(to: oldNote)
        try Data("newer content\n".utf8).write(to: newNote)
        try FileManager.default.setAttributes([.modificationDate: tOld], ofItemAtPath: oldNote.path)
        try FileManager.default.setAttributes([.modificationDate: tNew], ofItemAtPath: newNote.path)

        let reader = DatalessOverrideReader()
        let engine = FolderSourceEngine(directory: state, reader: reader, timeZone: { tz })
        guard case .added(let id) = await engine.checkAndAddFolder(rawPath: folder.path, overlapContext: .init()) else {
            Issue.record("failed to add folder")
            return
        }
        _ = await engine.selectSpan(id: id, span: .allOfIt)
        #expect(await engine.confirmFolder(id: id, now: tNow))

        // Simulate newer.md getting evicted to iCloud while waiting in the newest window.
        reader.datalessFileName = "newer.md"
        let upload = try #require(await engine.nextDelivery(now: tNow, ownerPaused: false))
        #expect(upload.items.map(\.path) == ["older.md"])
    }

    @Test func deletedDeliveredDocumentClearsQueuedRevisionAndEmitsRemoved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-delrev-\(UUID().uuidString)", isDirectory: true)
        let folder = dir.appendingPathComponent("Docs", isDirectory: true)
        let state = dir.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tz = TimeZone(secondsFromGMT: -7 * 3600)!
        let t0 = Date(timeIntervalSince1970: 1_795_800_000)
        let pdf = folder.appendingPathComponent("spec.pdf")
        try Data("%PDF-1.4\nv1\n".utf8).write(to: pdf)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-600)], ofItemAtPath: pdf.path)

        let engine = FolderSourceEngine(directory: state, timeZone: { tz })
        guard case .added(let id) = await engine.checkAndAddFolder(rawPath: folder.path, overlapContext: .init()) else {
            Issue.record("failed to add folder")
            return
        }
        _ = await engine.selectSpan(id: id, span: .allOfIt)
        #expect(await engine.confirmFolder(id: id, now: t0))
        let first = try #require(await engine.nextDelivery(now: t0, ownerPaused: false))
        await engine.recordAnswer(.delivered(), for: first, now: t0)

        // Revise the PDF, wait past 1h cool-down so the revision enters pending, then delete it before delivery.
        let t1 = t0.addingTimeInterval(600)
        try Data("%PDF-1.4\nv2-revised\n".utf8).write(to: pdf)
        try FileManager.default.setAttributes([.modificationDate: t1], ofItemAtPath: pdf.path)
        await engine.scanAll(now: t1.addingTimeInterval(10))
        let tDue = t1.addingTimeInterval(3900)
        await engine.scanAll(now: tDue)
        try FileManager.default.removeItem(at: pdf)
        await engine.scanAll(now: tDue.addingTimeInterval(10))

        let next = try #require(await engine.nextDelivery(now: tDue.addingTimeInterval(400), ownerPaused: false))
        #expect(next.items.count == 1)
        #expect(next.items[0].verb == .removed)
        #expect(next.items[0].path == "spec.pdf")
        #expect(next.items[0].sourcePath == nil)
    }

    @Test func intermediateSymlinkEscapeBlockedOnReadAndStage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-sym-\(UUID().uuidString)", isDirectory: true)
        let root = dir.appendingPathComponent("Root", isDirectory: true)
        let outside = dir.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let secret = outside.appendingPathComponent("secret.txt")
        try Data("do not escape\n".utf8).write(to: secret)
        let linkDir = root.appendingPathComponent("sub")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: outside)

        let escapedPath = linkDir.appendingPathComponent("secret.txt").path
        let canonicalRoot = FolderSourceClassify.canonicalPath(root.path)
        let reader = FolderSourceMacReader()
        #expect(reader.readAndHash(path: escapedPath, canonicalRoot: canonicalRoot, expectedDevice: nil, expectedInode: nil, maxInlineBytes: 1024) == nil)
        let dest = dir.appendingPathComponent("staged.txt")
        let staged = reader.stageFile(sourcePath: escapedPath, canonicalRoot: canonicalRoot, destinationURL: dest, expectedSHA256: nil, convertToPNG: false, maxImagePixels: 67_108_864, maxBytes: 1024)
        #expect(staged == .unreadable)
    }
}
