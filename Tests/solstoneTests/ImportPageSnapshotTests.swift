// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import SwiftUI
import Testing
@testable import solstone

/// Renders the import page in each of its states, light and dark, for review by eye. These
/// tests check that each image rendered, not how it looks.
@Suite("Import page snapshots")
@MainActor
struct ImportPageSnapshotTests {
    init() {
        _ = NSApplication.shared
        JournalMarkFont.register()
    }

    enum Scene: String, CaseIterable {
        case empty, waiting, refused, oldJournal, unreadable
    }

    private static func snapshot(_ scene: Scene) -> ImportSnapshot {
        var s = ImportSnapshot()
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
        case .refused:
            s.waiting = .waiting
            s.rows = [
                ImportRow(id: "c", name: "scan.pdf", kind: .refused("your journal can't take this kind of file"), retryable: false, savedAtJournal: true),
                ImportRow(id: "d", name: "notes.txt", kind: .refused("your journal couldn't save this right now."), retryable: true, savedAtJournal: false),
                ImportRow(id: "e", name: "photo.jpg", kind: .missingCopy, retryable: false, savedAtJournal: false),
            ]
            s.needsOwner = true
            s.interruptedAdd = true
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
        for dark in [false, true] {
            let page = DesktopImportPage(
                appState: state,
                header: AnyView(Text(ImportCopy.title).font(DeckStyle.name(20))),
                openScreenshots: {}
            )
            .padding(20)
            .frame(width: 400, height: 720, alignment: .topLeading)
            .background(DeckPaneGround())
            let host = NSHostingView(rootView: page.environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 720)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: try outputDir().appendingPathComponent("\(scene.rawValue)-\(dark ? "dark" : "light").png"))
            #expect(png.count > 10_000, "\(scene.rawValue) rendered almost nothing")
        }
    }
}
