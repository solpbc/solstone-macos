// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI
import UniformTypeIdentifiers

/// Import's words. Every one but the three computer lines is the phones' word for word.
enum ImportCopy {
    static let title = MacStrings.macos_desktopimportpage_import()
    static let tileSubline = MacStrings.macos_desktopimportpage_files()
    static let adds = MacStrings.macos_desktopimportpage_addspdfsaudioimagesandtextyouchoosehereordrop()
    static let choose = MacStrings.macos_desktopimportpage_choosefiles()
    static let screenshotsPointer = MacStrings.macos_desktopimportpage_screenshotscomeinontheirown()
    static let setUpScreenshots = MacStrings.macos_desktopimportpage_setupscreenshots()
    static let openScreenshots = MacStrings.macos_desktopimportpage_openscreenshots()
    static let interrupted = MacStrings.macos_desktopimportpage_somethingyouwereaddingdidntfinishsavingaddita()
    static let ok = MacStrings.macos_desktop_shared_settings_severity()
    static let recent = MacStrings.macos_desktopimportpage_recent()
    static let onThisDevice = MacStrings.macos_desktopstatuspane_onthisdevice()
    static let waiting = MacStrings.macos_desktopimportpage_waiting()
    static let sending = MacStrings.macos_desktopimportpage_sending()
    static let missingCopy = MacStrings.macos_desktopimportpage_thecopyonthisdeviceismissing()
    static let tryNow = MacStrings.macos_desktopimportpage_trynow()
    static let remove = MacStrings.macos_desktopimportpage_remove()
    static let cancel = MacStrings.macos_desktop_shared_setup_cancel()
    static let missingCopyRemove = MacStrings.macos_desktopimportpage_thecopyisalreadygonesothisonlyclearsitfromher()
    static let savedRemove = MacStrings.macos_desktopimportpage_thisremovesthecopyonthisdeviceyourjournalmays()
    static let plainRemove = MacStrings.macos_desktopimportpage_thisremovesthecopyonthisdevicesoitwontreachyo()
    static let nothingSaved = MacStrings.macos_desktopimportpage_nothingwassavedonthisdevice()
    static let importsNeedYou = MacStrings.macos_desktopimportpage_importsneedyou()
    static let openImportToSeeWhy = MacStrings.macos_desktopimportpage_openimporttoseewhy()
    static let storeUnreadable = MacStrings.macos_desktopimportpage_couldntreadimportsonthisdevicenothinghasbeenr()

    static func removeTitle(_ name: String) -> String { MacStrings.macos_desktopimportpage_remove2("\(name)") }
    static func saving(_ done: Int, _ total: Int) -> String { MacStrings.macos_desktopimportpage_savingonthisdeviceof(MacStrings.number(done + 1), MacStrings.number(total)) }
    static func saved(_ count: Int) -> String { MacStrings.macos_desktopimportpage_savedonthisdevice(MacStrings.number(count)) }

    static func recent(_ snapshot: ImportSnapshot) -> String {
        if snapshot.countsAsWaiting > 0 || (snapshot.needsOwner && snapshot.waiting == .journalTooOld) {
            switch snapshot.waiting {
            case .unpaired: return MacStrings.macos_desktopimportpage_importswaitonthisdeviceuntilyouconnectajourna()
            case .awaitingConfirmation: return MacStrings.macos_desktopimportpage_importswaituntilyouconfirmyourjournalsmark()
            case .pairingRefused: return MacStrings.macos_desktopimportpage_yourjournalstoppedacceptingthisdeviceimportsw()
            case .checkingJournal: return MacStrings.macos_desktopimportpage_checkingyourjournal()
            case .journalTooOld: return MacStrings.macos_desktopimportpage_importswaituntilyourjournalisupdated()
            case .sending: return MacStrings.macos_desktopimportpage_sendingtoyourjournal()
            case .waiting: return MacStrings.macos_desktopimportpage_waitingtogotoyourjournal()
            }
        }
        if !snapshot.rows.isEmpty { return MacStrings.macos_desktopimportpage_notgoingtoyourjournalrightnoweachonesayswhy() }
        if snapshot.deliveredToCurrentJournal { return MacStrings.macos_desktopimportpage_inyourjournal() }
        return MacStrings.macos_desktopimportpage_nothingyet()
    }

    static func refusal(_ reason: ImportIntakeRefusal) -> String {
        switch reason {
        case .unsupportedType: return MacStrings.macos_desktopimportpage_yourjournalcanttakethiskindoffile()
        case .cannotConvert: return MacStrings.macos_desktopimportpage_thisdevicecantconvertthisphoto()
        case .unreadable: return MacStrings.macos_desktopimportpage_thiscouldntbereadadditagain()
        case .tooLarge: return MacStrings.macos_desktopimportpage_itslargerthanyourjournaltakes()
        case .noSpace: return MacStrings.macos_desktopimportpage_thereisntenoughroomonthisdevice()
        }
    }

    /// What the owner is told when a remove or a retry didn't go as asked; nil when it did.
    static func change(_ result: ImportActionResult) -> String? {
        switch result {
        case .done, .removed: return nil
        case .alreadyDelivered: return MacStrings.macos_desktopimportpage_itsalreadyinyourjournal()
        case .gone: return MacStrings.macos_desktopimportpage_itsalreadygonefromthisdevice()
        case .busy: return MacStrings.macos_desktopimportpage_itssendingnowsonothingchanged()
        case .notApplicable, .storeUnreadable: return MacStrings.macos_desktopimportpage_nothingchangeditmayhavemovedoncheckthelist()
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
                    .accessibilityLabel(MacStrings.macos_accessibility_removeitem(row.name))
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
