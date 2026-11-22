// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import os
import SwiftUI
import Testing
@testable import UpdateKit
@testable import solstone

/// Renders the import page and the home deck import states, light and dark, for review by eye.
/// These tests check that each image rendered, not how it looks.
@Suite("Import page snapshots")
@MainActor
struct ImportPageSnapshotTests {
    private let isolatedDefaults = IsolatedUserDefaults()

    init() {
        _ = NSApplication.shared
        JournalMarkFont.register()
    }

    enum Scene: String, CaseIterable {
        case empty, waiting, review, refused, unpaired, oldJournal, unreadable
    }

    enum HomeScene: String, CaseIterable {
        case homeReview = "home-review"
        case homeStatusReview = "home-status-review"
        case homeAttention = "home-attention"
        case homeIdle = "home-idle"
    }

    private static func sampleTotals() -> SourceTotals.View {
        let now = Date()
        let iso = { (seconds: TimeInterval) in SourceTotals.iso(now.addingTimeInterval(-seconds)) }
        return SourceTotals.View(
            audioSeconds: 265 * 3600, audioRemainderMs: 0, audioLast: iso(4 * 60), audioSegments: [], audioStarted: "2026-03-03",
            screenSeconds: 212 * 3600, screenRemainderMs: 0, screenLast: iso(10), screenSegments: [], screenStarted: "2026-03-03",
            terminalSeconds: 38 * 3600, terminalLast: iso(12 * 60), terminalCarried: false, terminalStarted: "2026-03-03",
            browsersTotal: 1351, browsersLast: iso(26 * 3600), browsersTabs: [:], browsersStarted: "2026-06-12",
            obsidianTotal: 412, obsidianLast: iso(2 * 3600), obsidianNotes: [], obsidianBaseline: true, obsidianStarted: "2026-03-03",
            importsTotal: 14, importsLast: iso(18 * 60), importsIDs: [], importsStarted: "2026-03-03"
        )
    }

    private static func sampleReceipts(now: Date = Date()) -> [ImportRecentReceipt] {
        [
            ImportRecentReceipt(
                id: "r1",
                filename: "chatgpt-export.zip",
                importID: "20261122_141200",
                instanceID: "inst-1",
                deliveredAt: now.addingTimeInterval(-18 * 60)
            ),
            ImportRecentReceipt(
                id: "r2",
                filename: "meeting-notes.md",
                importID: nil,
                instanceID: "inst-1",
                deliveredAt: now.addingTimeInterval(-3 * 3600)
            ),
        ]
    }

    private static func snapshot(_ scene: Scene) -> ImportSnapshot {
        var s = ImportSnapshot()
        s.canOpenJournalImport = true
        switch scene {
        case .empty:
            s.waiting = .waiting
            s.deliveredToCurrentJournal = true
        case .waiting:
            s.waiting = .sending
            s.rows = [
                ImportRow(id: "a", name: "lease agreement.pdf", kind: .sending, retryable: false, savedAtJournal: true),
                ImportRow(id: "b", name: "voice memo.m4a", kind: .waiting, retryable: false, savedAtJournal: false),
            ]
            s.countsAsWaiting = 2
            s.intake = .finished(accepted: 2, refused: [ImportRefusedItem(name: "holiday.mov", reason: .unsupportedType)])
        case .review:
            s.waiting = .waiting
            s.deliveredToCurrentJournal = true
            s.rows = [
                ImportRow(
                    id: "rev-1",
                    name: "claude-conversations-2026.zip",
                    kind: .readyToReview,
                    retryable: false,
                    savedAtJournal: true,
                    importID: "20261122_140500",
                    reasonCode: "import_preview_required",
                    reviewKind: "body_confirmation_required",
                    reviewExpired: false
                ),
                ImportRow(
                    id: "rev-2",
                    name: "apple-notes-export.zip",
                    kind: .reviewExpired,
                    retryable: true,
                    savedAtJournal: false,
                    importID: "20261121_210000",
                    reasonCode: "import_preview_required",
                    reviewKind: "confirmation_required",
                    reviewExpired: true
                ),
                ImportRow(id: "w-1", name: "tax-receipt-2026.pdf", kind: .sending, retryable: false, savedAtJournal: false),
            ]
            s.countsAsWaiting = 1
            s.recentReceipts = sampleReceipts()
        case .refused:
            s.waiting = .waiting
            s.rows = [
                ImportRow(id: "c", name: "scan.pdf", kind: .refused("your journal can't take this kind of file"), retryable: false, savedAtJournal: true),
                ImportRow(id: "d", name: "notes.txt", kind: .refused("your journal couldn't save this right now."), retryable: true, savedAtJournal: false),
                ImportRow(id: "e", name: "photo.jpg", kind: .missingCopy, retryable: false, savedAtJournal: false),
            ]
            s.needsOwner = true
            s.interruptedAdd = true
            s.recentReceipts = sampleReceipts()
        case .unpaired:
            s.waiting = .unpaired
            s.canOpenJournalImport = false
            s.rows = [
                ImportRow(id: "u1", name: "journal-backup.zip", kind: .waiting, retryable: false, savedAtJournal: false),
            ]
            s.countsAsWaiting = 1
        case .oldJournal:
            s.waiting = .journalTooOld
            s.rows = [ImportRow(id: "f", name: "chapter one.pdf", kind: .waiting, retryable: false, savedAtJournal: false)]
            s.needsOwner = true
        case .unreadable:
            s.storeUnreadable = true
        }
        return s
    }

    private func outputDir() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("snapshots/import")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func updateController() -> UpdateController {
        UpdateController(
            feedURL: nil, publicKey: nil, log: Logger.setup,
            errorDomain: "app.solstone.observer.updates", defaults: isolatedDefaults.defaults
        ) { _, _ in nil }
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String, dark: Bool) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: try outputDir().appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        #expect(png.count > 10_000, "\(name) rendered almost nothing")
    }

    @Test(arguments: Scene.allCases)
    func page(_ scene: Scene) throws {
        let state = AppState.forSnapshot()
        let source = ImportSource(
            engine: ImportEngine(directory: FileManager.default.temporaryDirectory.appendingPathComponent("import-snap-\(UUID().uuidString)"),
                                 transport: ImportLiveTransport()),
            facts: { ImportFacts() }, serverURL: { nil }, runsLoop: false
        )
        source.showForSnapshot(Self.snapshot(scene))
        state.importSource = source
        state.snapshotSourceTotals = scene == .unreadable ? nil : Self.sampleTotals()
        for dark in [false, true] {
            let page = DesktopImportPage(
                appState: state,
                header: AnyView(Text(ImportCopy.title).font(DeckStyle.name(20))),
                openScreenshots: {}
            )
            .padding(20)
            .frame(width: 400, height: 780, alignment: .topLeading)
            .background(DeckPaneGround())
            try render(page, size: CGSize(width: 400, height: 780), to: scene.rawValue, dark: dark)
        }
    }

    @Test(arguments: HomeScene.allCases)
    func home(_ scene: HomeScene) throws {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.granted)
        state.microphoneAuthorizationCause = .authorized
        state.isRecording = true

        var deck = DeckInputs()
        deck.terminalOn = true
        deck.terminalState = .running
        deck.browserState = .running(connected: ["Chrome", "Safari"])
        deck.obsidianState = .on
        deck.obsidianVaultName = "field notes"
        state.snapshotDeckInputs = deck
        state.snapshotSourceTotals = Self.sampleTotals()

        let importSnapshot: ImportSnapshot
        var pill = JournalPillInputs()
        let pane: HomePane?
        switch scene {
        case .homeReview:
            importSnapshot = Self.snapshot(.review)
            pill.readyToReview = importSnapshot.readyToReviewCount
            pane = .importPage
        case .homeStatusReview:
            importSnapshot = Self.snapshot(.review)
            pill.readyToReview = importSnapshot.readyToReviewCount
            pane = .status
        case .homeAttention:
            importSnapshot = Self.snapshot(.refused)
            pill.held = .importsNeedYou
            pane = .importPage
        case .homeIdle:
            importSnapshot = Self.snapshot(.empty)
            pane = nil
        }

        let source = ImportSource(
            engine: ImportEngine(directory: FileManager.default.temporaryDirectory.appendingPathComponent("import-home-snap-\(UUID().uuidString)"),
                                 transport: ImportLiveTransport()),
            facts: { ImportFacts() }, serverURL: { nil }, runsLoop: false
        )
        source.showForSnapshot(importSnapshot)
        state.importSource = source
        state.snapshotJournalPillInputs = pill
        state.snapshotJournalFacts = [
            ["connection", statusConnectionValue(deriveJournalPill(pill), connectionLine: "connected to your journal on this mac")],
            [UICopy.SETTINGS_LAST_DELIVERY_LABEL, "just now"],
        ]

        let size = CGSize(width: 1160, height: 860)
        for dark in [false, true] {
            let view = SettingsView(
                appState: state,
                updateController: updateController(),
                selectedTab: .home,
                initialHomePane: pane,
                initialStorageUsedMB: 42
            )
            try render(view, size: size, to: scene.rawValue, dark: dark)
        }
    }
}
