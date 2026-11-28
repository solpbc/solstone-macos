// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import SPLTunnel
import Testing
@testable import solstone

/// End-to-end folder-source validation over a real paired SPL mTLS tunnel against a live journal.
/// Runs only when `SOLSTONE_LIVE_FOLDER_E2E_PAIR_LINK` and `SOLSTONE_LIVE_FOLDER_E2E_DIR` are set;
/// skipped in routine `make ci`.
@Suite(
    "NativeIntegration folder source live E2E",
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["SOLSTONE_LIVE_FOLDER_E2E_PAIR_LINK"] != nil
            && ProcessInfo.processInfo.environment["SOLSTONE_LIVE_FOLDER_E2E_DIR"] != nil,
        "set SOLSTONE_LIVE_FOLDER_E2E_PAIR_LINK and SOLSTONE_LIVE_FOLDER_E2E_DIR to run live folder E2E"
    )
)
@MainActor
struct FolderSourceLiveE2ETests {
    private struct Report: Codable {
        var journalCapabilities: [String]
        var facetsCount: Int
        var chosenFacet: String?
        var supportedRulesetVersion: Int
        var folderID: String
        var day: String
        var previewTotalItems: Int
        var previewContentItems: Int
        var previewMetadataOnlyItems: Int
        var estimateSegments: Int?
        var estimateDays: Int?
        var estimateThoughts: Int?
        var estimateAlreadyInJournal: Int?
        var initialUploadCount: Int
        var initialAnswers: [String]
        var fallbackToDetailsAfterInitial: Int
        var segmentsOnDayCount: Int
        var scenario2DownloadDelivered: Bool
        var scenario3NoteEditDelivered: Bool
        var scenario3RevertSuppressed: Bool
        var scenario4DocRevisionHeldBeforeCooldown: Bool
        var scenario4DocRevisionDeliveredAfterCooldown: Bool
        var scenario5RenameDelivered: Bool
        var scenario6DeleteBeforeSendDropped: Bool
        var scenario7CorruptPDFNotResent: Bool
        var scenario8OfflineChangeDeliveredAfterReopen: Bool
        var pauseHeldWithoutSkipping: Bool
        var resumeDeliveredQueuedChange: Bool
        var iCloudEvictedChecked: Bool
        var iCloudDatalessBefore: Bool?
        var iCloudDatalessAfter: Bool?
        var declaredStatesSent: [String]
        var journalSourcesStatesObserved: [String]
    }

    @Test func fullMacFolderSourceLifecycleAgainstLiveJournal() async throws {
        let env = ProcessInfo.processInfo.environment
        let pairLink = try #require(env["SOLSTONE_LIVE_FOLDER_E2E_PAIR_LINK"])
        let folderPath = try #require(env["SOLSTONE_LIVE_FOLDER_E2E_DIR"])
        let iCloudDir = env["SOLSTONE_LIVE_FOLDER_E2E_ICLOUD_DIR"]
        let iCloudFile = env["SOLSTONE_LIVE_FOLDER_E2E_ICLOUD_FILE"]
        let reportPath = env["SOLSTONE_LIVE_FOLDER_E2E_REPORT"]
        let ownerBase = env["SOLSTONE_LIVE_FOLDER_E2E_OWNER_BASE"]

        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-folder-live-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }

        // 1. Pair over real SPL mTLS transport (in-memory pairing, zero keychain writes).
        let pairURL = try PairURL(string: pairLink)
        let unreachableRelay = try #require(URL(string: "https://127.0.0.1:1"))
        let pairing = try await PairClient(clientInfo: SPLRuntime.clientInfo).pair(
            pairURL: pairURL,
            deviceLabel: "mac-folder-e2e",
            relayEndpoint: unreachableRelay
        )
        let tunnelTransport = SPLTunnelTransport()
        let connection = try await tunnelTransport.connect(
            pairing: pairing,
            candidates: TransportEndpoint.candidates(for: pairing)
        )
        defer {
            Task { await tunnelTransport.disconnect() }
        }
        let serverURL = "http://127.0.0.1:\(connection.localPort)"

        let client = UploadClient()
        let liveTransport = FolderLiveTransport(journal: client)
        let reader = FolderSourceMacReader()

        // 2. Verify "folder" capability, /facets, and /supported.
        let caps = try await client.capabilities(serverURL: serverURL)
        #expect(caps.contains(FolderSourceWireConstants.capability))

        let facets = try await liveTransport.fetchFacets(serverURL: serverURL)
        let chosenFacet = facets.first(where: { $0.name == "work" })?.name ?? facets.first?.name
        let supported = try await liveTransport.fetchSupported(serverURL: serverURL)
        #expect(supported.fromJournal)
        #expect(supported.rulesetVersion >= 8)

        // Anchor timeline safely in today's past so every window is closed and never ahead of the journal.
        let rawNow = Int64(Date().timeIntervalSince1970)
        let t0Epoch = ((rawNow - 10_800) / 300) * 300
        let t0 = Date(timeIntervalSince1970: TimeInterval(t0Epoch))
        let tz = TimeZone.current
        let day = ObsidianStamp(epochSeconds: t0Epoch, timeZone: tz).window.day

        let totals = SourceTotals(directory: stateDir, clock: .init(now: t0, timeZone: tz))
        var engine = FolderSourceEngine(
            directory: stateDir.appendingPathComponent("folders", isDirectory: true),
            reader: reader,
            totals: totals,
            timeZone: { tz }
        )
        await engine.setSupportedList(supported)

        // Helper to drain all ready deliveries at `at` through real `FolderLiveTransport`.
        func drainAll(at moment: Date) async -> [String] {
            var answers: [String] = []
            for _ in 0..<20 {
                guard let upload = await engine.nextDelivery(now: moment, ownerPaused: false) else { break }
                let ans = await liveTransport.sendSegment(
                    upload,
                    reader: reader,
                    supported: supported,
                    serverURL: serverURL,
                    isCurrent: { true }
                )
                answers.append(String(describing: ans))
                await engine.recordAnswer(ans, for: upload, now: moment)
                if case .retry = ans { break }
                if case .ahead = ans { break }
            }
            return answers
        }

        // Scenario 1: First setup with history + facet + live /estimate + mixed files + corrupt PDF fallback.
        let pick = await engine.checkAndAddFolder(rawPath: folderPath, overlapContext: .init())
        guard case .added(let folderID) = pick else {
            Issue.record("expected .added, got \(pick)")
            return
        }
        if let chosenFacet {
            _ = await engine.updateFacet(id: folderID, facet: chosenFacet)
        }
        _ = await engine.selectSpan(id: folderID, span: .allOfIt)

        let previewPair = try #require(await engine.computePreview(id: folderID, now: t0))
        let preview = previewPair.summary
        #expect(preview.totalItems >= 8)
        #expect(preview.contentItems >= 5)
        #expect(preview.metadataOnlyItems >= 2)

        let estimate = try await liveTransport.fetchEstimate(
            serverURL: serverURL,
            request: FolderEstimateRequest(folderID: folderID, items: previewPair.estimateItems)
        )
        #expect(estimate.segments > 0)
        #expect(estimate.days > 0)
        #expect(estimate.alreadyInJournal == 0)

        #expect(await engine.confirmFolder(id: folderID, now: t0))
        let initialAnswers = await drainAll(at: t0)
        #expect(!initialAnswers.isEmpty)

        // Verify corrupt PDF triggered fallbackToDetails == 1 and landed as details-only.
        let snap1 = await engine.snapshot(paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: facets, facetsState: .ready)
        let fallback1 = snap1.folders.first(where: { $0.id == folderID })?.fallbackToDetails ?? 0
        #expect(fallback1 >= 1)

        // Verify GET /app/devices/ingest/segments/{day}?source=folder lists landed folder segments.
        let segDay = try await client.getSegmentsDay(serverURL: serverURL, day: day, source: FolderSourceWireConstants.source)
        #expect(segDay.total >= 1)

        // Scenario 2: Fresh download carrying real macOS kMDItemWhereFroms + com.apple.quarantine.
        let t2 = t0.addingTimeInterval(600)
        let downloadFile = URL(fileURLWithPath: folderPath).appendingPathComponent("downloaded-tool.dmg")
        try Data("synthetic-installer-binary".utf8).write(to: downloadFile)
        let wfPlist = try PropertyListSerialization.data(
            fromPropertyList: ["https://releases.example.com/tool-2.0.dmg", "https://releases.example.com/downloads"],
            format: .binary,
            options: 0
        )
        _ = wfPlist.withUnsafeBytes { buf in
            setxattr(downloadFile.path, FolderSourceMacReader.whereFromsAttribute, buf.baseAddress, wfPlist.count, 0, 0)
        }
        let qBytes = Data("0083;6928abcd;Safari;11112222-3333-4444-5555-666677778888".utf8)
        _ = qBytes.withUnsafeBytes { buf in
            setxattr(downloadFile.path, FolderSourceMacReader.quarantineAttribute, buf.baseAddress, qBytes.count, 0, 0)
        }
        try FileManager.default.setAttributes([.modificationDate: t2], ofItemAtPath: downloadFile.path)
        await engine.scanAll(now: t2.addingTimeInterval(10))
        let s2Answers = await drainAll(at: t2.addingTimeInterval(360))
        let s2Delivered = s2Answers.contains { $0.contains("delivered") }
        #expect(s2Delivered)

        // Scenario 3: Note edit (net change delivered) + revert inside window (suppressed).
        let noteURL = URL(fileURLWithPath: folderPath).appendingPathComponent("note.md")
        let t3 = t0.addingTimeInterval(1200)
        let originalNote = try String(contentsOf: noteURL, encoding: .utf8)
        let editedNote = originalNote + "\nAdded line during live macOS E2E.\n"
        try Data(editedNote.utf8).write(to: noteURL)
        try FileManager.default.setAttributes([.modificationDate: t3], ofItemAtPath: noteURL.path)
        await engine.scanAll(now: t3.addingTimeInterval(10))
        let s3Answers = await drainAll(at: t3.addingTimeInterval(360))
        let s3Delivered = s3Answers.contains { $0.contains("delivered") }
        #expect(s3Delivered)

        // Edit and revert within same 5-minute window -> suppressed.
        let t3Rev = t0.addingTimeInterval(1800)
        try Data((editedNote + "temporary line\n").utf8).write(to: noteURL)
        try FileManager.default.setAttributes([.modificationDate: t3Rev], ofItemAtPath: noteURL.path)
        await engine.scanAll(now: t3Rev.addingTimeInterval(10))
        try Data(editedNote.utf8).write(to: noteURL)
        try FileManager.default.setAttributes([.modificationDate: t3Rev.addingTimeInterval(30)], ofItemAtPath: noteURL.path)
        await engine.scanAll(now: t3Rev.addingTimeInterval(40))
        let s3RevSuppressed = await engine.nextDelivery(now: t3Rev.addingTimeInterval(360), ownerPaused: false) == nil
        #expect(s3RevSuppressed)

        // Scenario 4: Document revision after 1-hour cool-down.
        let pdfURL = URL(fileURLWithPath: folderPath).appendingPathComponent("text-report.pdf")
        let t4 = t0.addingTimeInterval(2400)
        let existingPDF = try Data(contentsOf: pdfURL)
        // Append a valid PDF comment line so bytes/hash change while remaining a valid PDF.
        var revisedPDF = existingPDF
        revisedPDF.append(Data("\n% macos-e2e-revision-2\n".utf8))
        try revisedPDF.write(to: pdfURL)
        try FileManager.default.setAttributes([.modificationDate: t4], ofItemAtPath: pdfURL.path)
        await engine.scanAll(now: t4.addingTimeInterval(10))
        await engine.scanAll(now: t4.addingTimeInterval(1800))
        let heldBeforeCooldown = await engine.nextDelivery(now: t4.addingTimeInterval(2100), ownerPaused: false) == nil
        #expect(heldBeforeCooldown)
        let t4Due = t4.addingTimeInterval(3900) // +65 min
        await engine.scanAll(now: t4Due)
        let s4Answers = await drainAll(at: t4Due.addingTimeInterval(360))
        let s4Delivered = s4Answers.contains { $0.contains("delivered") }
        #expect(s4Delivered)

        // Scenario 5: Rename of delivered file.
        let t5 = t0.addingTimeInterval(7200)
        let renamedNoteURL = URL(fileURLWithPath: folderPath).appendingPathComponent("note-renamed.md")
        try FileManager.default.moveItem(at: noteURL, to: renamedNoteURL)
        await engine.scanAll(now: t5)
        let s5Answers = await drainAll(at: t5.addingTimeInterval(360))
        let s5Delivered = s5Answers.contains { $0.contains("delivered") }
        #expect(s5Delivered)

        // Scenario 6: Delete before send drops queued file so nothing leaves this Mac.
        let t6 = t0.addingTimeInterval(7800)
        let ephemeralURL = URL(fileURLWithPath: folderPath).appendingPathComponent("ephemeral-secret.md")
        try Data("never send this\n".utf8).write(to: ephemeralURL)
        try FileManager.default.setAttributes([.modificationDate: t6], ofItemAtPath: ephemeralURL.path)
        await engine.scanAll(now: t6.addingTimeInterval(10))
        #expect(await engine.hasPendingUploads())
        try FileManager.default.removeItem(at: ephemeralURL)
        await engine.scanAll(now: t6.addingTimeInterval(20))
        let s6Dropped = await engine.nextDelivery(now: t6.addingTimeInterval(360), ownerPaused: false) == nil
        #expect(s6Dropped)

        // Scenario 7: Corrupt PDF bytes are NOT resent on subsequent scan.
        await engine.scanAll(now: t6.addingTimeInterval(370))
        let s7NotResent = await engine.nextDelivery(now: t6.addingTimeInterval(380), ownerPaused: false) == nil
        #expect(s7NotResent)

        // Scenario 8: Change while app was off (re-open fresh FolderSourceEngine on persisted ledger.json).
        let t8 = t0.addingTimeInterval(8400)
        let offlineURL = URL(fileURLWithPath: folderPath).appendingPathComponent("added-while-off.md")
        try Data("written while the app was closed\n".utf8).write(to: offlineURL)
        try FileManager.default.setAttributes([.modificationDate: t8], ofItemAtPath: offlineURL.path)
        engine = FolderSourceEngine(
            directory: stateDir.appendingPathComponent("folders", isDirectory: true),
            reader: reader,
            totals: totals,
            timeZone: { tz }
        )
        await engine.setSupportedList(supported)
        await engine.scanAll(now: t8.addingTimeInterval(10))
        let s8Answers = await drainAll(at: t8.addingTimeInterval(360))
        let s8Delivered = s8Answers.contains { $0.contains("delivered") }
        #expect(s8Delivered)

        // Pause (holds sync without skipping) + Resume.
        #expect(await engine.pauseFolder(id: folderID))
        let tPause = t0.addingTimeInterval(9000)
        let pausedURL = URL(fileURLWithPath: folderPath).appendingPathComponent("added-while-paused.md")
        try Data("created while folder was paused\n".utf8).write(to: pausedURL)
        try FileManager.default.setAttributes([.modificationDate: tPause], ofItemAtPath: pausedURL.path)
        await engine.scanAll(now: tPause.addingTimeInterval(10))
        let pauseHeld = await engine.nextDelivery(now: tPause.addingTimeInterval(360), ownerPaused: false) == nil
        #expect(pauseHeld)

        // Evicted iCloud Drive non-hydration verification (SF_DATALESS must remain set before AND after).
        var iCloudChecked = false
        var datalessBefore: Bool?
        var datalessAfter: Bool?
        if let iCloudDir, let iCloudFile {
            let beforeProbe = FolderSyncFile.probe(path: iCloudFile)
            datalessBefore = beforeProbe?.isDataless
            let icPick = await engine.checkAndAddFolder(rawPath: iCloudDir, overlapContext: .init())
            if case .added(let icID) = icPick {
                _ = await engine.selectSpan(id: icID, span: .allOfIt)
                _ = await engine.computePreview(id: icID, now: tPause.addingTimeInterval(360))
                _ = await engine.confirmFolder(id: icID, now: tPause.addingTimeInterval(360))
                await engine.scanAll(now: tPause.addingTimeInterval(370))
                _ = await drainAll(at: tPause.addingTimeInterval(380))
                let afterProbe = FolderSyncFile.probe(path: iCloudFile)
                datalessAfter = afterProbe?.isDataless
                iCloudChecked = true
                #expect(datalessBefore == true)
                #expect(datalessAfter == true)
                _ = await engine.removeFolder(id: icID)
            }
        }

        // Live PUT /app/network/api/clients/self/sources state transitions: paused -> on -> needs_attention -> off ([]).
        var declaredStates: [String] = []
        var observedJournalStates: [String] = []

        func readJournalFolderState() async -> String? {
            guard let ownerBase, let url = URL(string: "\(ownerBase)/app/sources/api/folders") else { return nil }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = obj["folders"] as? [[String: Any]] else { return nil }
            for row in rows {
                if (row["id"] as? String) == folderID {
                    return row["state"] as? String
                }
            }
            return nil
        }

        let pausedSnap = await engine.snapshot(paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: facets, facetsState: .ready)
        let pausedDecls = pausedSnap.folderDeclarations(ownerPaused: false)
        try await client.declareSources(pausedDecls, serverURL: serverURL)
        declaredStates.append(pausedDecls.first?.state ?? "none")
        #expect(pausedDecls.first == SourceDeclaration(source: "folder", state: "paused", detail: folderID))
        if let st = await readJournalFolderState() { observedJournalStates.append("paused:\(st)") }

        // Resume -> queued file while paused delivers immediately, declare "on".
        #expect(await engine.resumeFolder(id: folderID))
        let resumeAnswers = await drainAll(at: tPause.addingTimeInterval(360))
        let resumeDelivered = resumeAnswers.contains { $0.contains("delivered") }
        #expect(resumeDelivered)

        let onSnap = await engine.snapshot(paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: facets, facetsState: .ready)
        let onDecls = onSnap.folderDeclarations(ownerPaused: false)
        try await client.declareSources(onDecls, serverURL: serverURL)
        declaredStates.append(onDecls.first?.state ?? "none")
        #expect(onDecls.first == SourceDeclaration(source: "folder", state: "on", detail: folderID))
        if let st = await readJournalFolderState() { observedJournalStates.append("on:\(st)") }

        // Verify needs_attention declaration wire acceptance on live journal.
        let attnDecl = [SourceDeclaration(source: "folder", state: "needs_attention", detail: folderID)]
        try await client.declareSources(attnDecl, serverURL: serverURL)
        declaredStates.append("needs_attention")
        if let st = await readJournalFolderState() { observedJournalStates.append("needs_attention:\(st)") }

        // Turn off -> folder omitted from declaration ([] accepted by live journal).
        #expect(await engine.turnOffFolder(id: folderID))
        let offSnap = await engine.snapshot(paired: true, ownerPaused: false, journalNeedsUpdate: false, facets: facets, facetsState: .ready)
        let offDecls = offSnap.folderDeclarations(ownerPaused: false)
        #expect(offDecls.isEmpty)
        try await client.declareSources(offDecls, serverURL: serverURL)
        declaredStates.append("off_omitted")
        if let st = await readJournalFolderState() { observedJournalStates.append("off:\(st)") }

        let report = Report(
            journalCapabilities: caps,
            facetsCount: facets.count,
            chosenFacet: chosenFacet,
            supportedRulesetVersion: supported.rulesetVersion,
            folderID: folderID,
            day: day,
            previewTotalItems: preview.totalItems,
            previewContentItems: preview.contentItems,
            previewMetadataOnlyItems: preview.metadataOnlyItems,
            estimateSegments: estimate.segments,
            estimateDays: estimate.days,
            estimateThoughts: estimate.thoughts,
            estimateAlreadyInJournal: estimate.alreadyInJournal,
            initialUploadCount: initialAnswers.count,
            initialAnswers: initialAnswers,
            fallbackToDetailsAfterInitial: fallback1,
            segmentsOnDayCount: segDay.total,
            scenario2DownloadDelivered: s2Delivered,
            scenario3NoteEditDelivered: s3Delivered,
            scenario3RevertSuppressed: s3RevSuppressed,
            scenario4DocRevisionHeldBeforeCooldown: heldBeforeCooldown,
            scenario4DocRevisionDeliveredAfterCooldown: s4Delivered,
            scenario5RenameDelivered: s5Delivered,
            scenario6DeleteBeforeSendDropped: s6Dropped,
            scenario7CorruptPDFNotResent: s7NotResent,
            scenario8OfflineChangeDeliveredAfterReopen: s8Delivered,
            pauseHeldWithoutSkipping: pauseHeld,
            resumeDeliveredQueuedChange: resumeDelivered,
            iCloudEvictedChecked: iCloudChecked,
            iCloudDatalessBefore: datalessBefore,
            iCloudDatalessAfter: datalessAfter,
            declaredStatesSent: declaredStates,
            journalSourcesStatesObserved: observedJournalStates
        )
        if let reportPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: URL(fileURLWithPath: reportPath))
        }
    }
}
