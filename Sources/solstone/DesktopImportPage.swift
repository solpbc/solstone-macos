// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI
import UniformTypeIdentifiers

/// Import's words. Every one but the three computer lines is the phones' word for word.
enum ImportCopy {
    static let title = "import"
    static let tileSubline = "files"
    static let adds = "adds PDFs, audio, images and text you choose here or drop on this window."
    static let choose = "choose files…"
    static let screenshotsPointer = "screenshots come in on their own."
    static let setUpScreenshots = "set up screenshots"
    static let openScreenshots = "open screenshots"
    static let interrupted = "something you were adding didn't finish saving. add it again."
    static let ok = "ok"
    static let recent = "recent"
    static let onThisDevice = "on this device"
    static let waiting = "waiting"
    static let sending = "sending"
    static let missingCopy = "the copy on this device is missing"
    static let tryNow = "try now"
    static let remove = "remove"
    static let cancel = "cancel"
    static let missingCopyRemove = "the copy is already gone, so this only clears it from here."
    static let savedRemove = "this removes the copy on this device. your journal may still bring in the copy it already has."
    static let plainRemove = "this removes the copy on this device, so it won't reach your journal."
    static let nothingSaved = "nothing was saved on this device."
    static let importsNeedYou = "imports need you"
    static let openImportToSeeWhy = "open import to see why"
    static let storeUnreadable = "couldn't read imports on this device. nothing has been removed. restart the solstone app to try again."

    static func removeTitle(_ name: String) -> String { "remove \(name)?" }
    static func saving(_ done: Int, _ total: Int) -> String { "saving on this device: \(done + 1) of \(total)" }
    static func saved(_ count: Int) -> String { "saved on this device: \(count)" }

    static func recent(_ snapshot: ImportSnapshot) -> String {
        if snapshot.countsAsWaiting > 0 || (snapshot.needsOwner && snapshot.waiting == .journalTooOld) {
            switch snapshot.waiting {
            case .unpaired: return "imports wait on this device until you connect a journal."
            case .awaitingConfirmation: return "imports wait until you confirm your journal's mark."
            case .pairingRefused: return "your journal stopped accepting this device. imports wait here until you pair again."
            case .checkingJournal: return "checking your journal."
            case .journalTooOld: return "imports wait until your journal is updated."
            case .sending: return "sending to your journal."
            case .waiting: return "waiting to go to your journal."
            }
        }
        if !snapshot.rows.isEmpty { return "imports here won't go on their own. each one says why." }
        if snapshot.deliveredToCurrentJournal { return "in your journal." }
        return "nothing yet."
    }

    static func refusal(_ reason: ImportIntakeRefusal) -> String {
        switch reason {
        case .unsupportedType: return "your journal can't take this kind of file"
        case .cannotConvert: return "this device can't convert this photo"
        case .unreadable: return "this couldn't be read. add it again"
        case .tooLarge: return "it's larger than your journal takes"
        case .noSpace: return "there isn't enough room on this device"
        }
    }

    /// What the owner is told when a remove or a retry didn't go as asked; nil when it did.
    static func change(_ result: ImportActionResult) -> String? {
        switch result {
        case .done, .removed: return nil
        case .alreadyDelivered: return "it's already in your journal."
        case .gone: return "it's already gone from this device."
        case .busy: return "it's sending now, so nothing changed."
        case .notApplicable, .storeUnreadable: return "nothing changed. it may have moved on; check the list."
        }
    }

    /// The types the picker offers: what the journal imports, with HEIC converted.
    static let pickerTypes: [UTType] = [.pdf, .audio, .plainText, .png, .jpeg, .webP, .gif, .heic, .heif]
}

/// `import` on the deck: a destination, with no state word and no switch.
struct ImportTile: View {
    var selected = false
    var compact = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15))
                        .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                        .accessibilityHidden(true)
                    if compact { name }
                }
                if !compact {
                    Spacer(minLength: 8)
                    name
                }
                Text(ImportCopy.tileSubline)
                    .font(.system(size: 11))
                    .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 66 : 104, alignment: .topLeading)
            .padding(compact ? 11 : 13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SetupChromeColor.card(for: scheme)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? SetupChromeColor.solOrange : SetupChromeColor.hairline(for: scheme), lineWidth: selected ? 2 : 1)
        )
        .accessibilityLabel("\(ImportCopy.title), \(ImportCopy.tileSubline)")
        .accessibilityIdentifier(AXID.Deck.importTile)
    }

    private var name: some View {
        Text(ImportCopy.title)
            .font(DeckStyle.name(compact ? 16 : 17))
            .foregroundStyle(SetupChromeColor.ink(for: scheme))
    }
}

/// The import page, top to bottom: what it adds, the one action, the screenshots pointer, the
/// last addition, recent, then what is still on this Mac.
struct DesktopImportPage: View {
    let appState: AppState
    let header: AnyView
    let openScreenshots: () -> Void
    @State private var confirming: ImportRow?
    @State private var changeLine: String?

    var body: some View {
        let source = appState.importSource
        let snapshot = source?.snapshot ?? ImportSnapshot()
        VStack(alignment: .leading, spacing: 16) {
            header
            Text(ImportCopy.adds)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.storeUnreadable {
                Text(ImportCopy.storeUnreadable).font(.callout)
            }
            Button(ImportCopy.choose) { chooseFiles() }
                .disabled(snapshot.storeUnreadable)
                .accessibilityIdentifier(AXID.Deck.importChoose)
            HStack {
                Text(ImportCopy.screenshotsPointer).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(screenshotsOn ? ImportCopy.openScreenshots : ImportCopy.setUpScreenshots, action: openScreenshots)
                    .buttonStyle(.link)
            }
            .font(.callout)
            if let intake = snapshot.intake, !snapshot.storeUnreadable {
                intakeLines(intake)
                    .onDisappear { Task { await source?.intakeSeen() } }
            }
            if snapshot.interruptedAdd {
                HStack {
                    Text(ImportCopy.interrupted).font(.callout)
                    Spacer(minLength: 8)
                    Button(ImportCopy.ok) { Task { await source?.dismissInterrupted() } }
                }
            }
            if let changeLine {
                Text(changeLine).font(.callout).foregroundStyle(.secondary)
            }
            if !snapshot.storeUnreadable {
                section(ImportCopy.recent) {
                    Text(ImportCopy.recent(snapshot))
                        .font(.callout)
                        .accessibilityIdentifier(AXID.Deck.importRecent)
                }
            }
            if !snapshot.rows.isEmpty {
                section(ImportCopy.onThisDevice) {
                    ForEach(snapshot.rows) { row in
                        itemRow(row)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.importPage)
        .confirmationDialog(
            confirming.map { ImportCopy.removeTitle($0.name) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { row in
            Button(ImportCopy.remove, role: .destructive) {
                Task {
                    let result = await source?.remove(row.id) ?? .gone
                    changeLine = ImportCopy.change(result)
                }
            }
            Button(ImportCopy.cancel, role: .cancel) {}
        } message: { row in
            Text(row.kind == .missingCopy ? ImportCopy.missingCopyRemove : row.savedAtJournal ? ImportCopy.savedRemove : ImportCopy.plainRemove)
        }
    }

    private var screenshotsOn: Bool { appState.screenshotSource?.snapshot.switchOn ?? false }

    @ViewBuilder
    private func intakeLines(_ intake: ImportIntakeLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch intake {
            case .copying(let done, let total):
                Text(ImportCopy.saving(done, total))
            case .finished(let accepted, let refused):
                Text(accepted == 0 ? ImportCopy.nothingSaved : ImportCopy.saved(accepted))
                ForEach(Array(refused.enumerated()), id: \.offset) { _, item in
                    Text("\(item.name): \(ImportCopy.refusal(item.reason))").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.Deck.importIntake)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func itemRow(_ row: ImportRow) -> some View {
        let subline: String
        switch row.kind {
        case .waiting, .goingAgain: subline = ImportCopy.waiting
        case .sending: subline = ImportCopy.sending
        case .refused(let sentence): subline = sentence
        case .missingCopy: subline = ImportCopy.missingCopy
        }
        let refusedHere: Bool = { if case .refused = row.kind { return true } else { return false } }()
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Text(subline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if row.kind != .sending {
                if refusedHere && row.retryable {
                    Button(ImportCopy.tryNow) {
                        Task { changeLine = ImportCopy.change(await appState.importSource?.retry(row.id) ?? .gone) }
                    }
                    .accessibilityLabel("\(ImportCopy.tryNow), \(row.name)")
                }
                Button(ImportCopy.remove) { confirming = row }
                    .accessibilityLabel("\(ImportCopy.remove) \(row.name)")
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.importItem(row.id))
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ImportCopy.pickerTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await appState.importSource?.add(urls) }
    }
}
