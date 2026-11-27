// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI
import UniformTypeIdentifiers

/// Import's words. Every string comes from the Fluent catalog (`MacStrings`).
enum ImportCopy {
    static let title = MacStrings.macos_desktopimportpage_import()
    static let tileSubline = MacStrings.macos_desktopimportpage_files()
    static let tileWaitingForJournal = MacStrings.macos_desktopimportpage_waitingforjournal()
    static let adds = MacStrings.macos_desktopimportpage_addspdfsaudioimagesandtextyouchoosehereordrop()
    static let choose = MacStrings.macos_desktopimportpage_choosefiles()
    static let moreImports = MacStrings.macos_desktopimportpage_moreimports()
    static let moreImportsSubline = MacStrings.macos_desktopimportpage_moreimportssubline()
    static let screenshotsPointer = MacStrings.macos_desktopimportpage_screenshotscomeinontheirown()
    static let setUpScreenshots = MacStrings.macos_desktopimportpage_setupscreenshots()
    static let openScreenshots = MacStrings.macos_desktopimportpage_openscreenshots()
    static let interrupted = MacStrings.macos_desktopimportpage_somethingyouwereaddingdidntfinishsavingaddita()
    static let ok = MacStrings.macos_desktop_shared_settings_severity()
    static let waitingForYourReview = MacStrings.macos_desktopimportpage_waitingforyourreview()
    static let readyToReview = MacStrings.macos_desktopimportpage_readytoreview()
    static let expired = MacStrings.macos_desktopimportpage_expired()
    static let reviewDetail = MacStrings.macos_desktopimportpage_reviewdetail()
    static let reviewDetailHour = MacStrings.macos_desktopimportpage_reviewdetailhour()
    static let reviewExpired = MacStrings.macos_desktopimportpage_reviewexpired()
    static let reviewInYourJournal = MacStrings.macos_desktopimportpage_reviewinyourjournal()
    static let sendAgainToReview = MacStrings.macos_desktopimportpage_sendagaintoreview()
    static let recent = MacStrings.macos_desktopimportpage_recent()
    static let nothingYet = MacStrings.macos_desktopimportpage_nothingyet()
    static let allImportHistory = MacStrings.macos_desktopimportpage_allimporthistory()
    static let onThisDevice = MacStrings.macos_desktopstatuspane_onthisdevice()
    static let waiting = MacStrings.macos_desktopimportpage_waiting()
    static let paused = MacStrings.macos_desktopimportpage_paused()
    static let sending = MacStrings.macos_desktopimportpage_sending()
    static let checkingFile = MacStrings.macos_desktopimportpage_checkingfile()
    static let checkingCompleteFile = MacStrings.macos_desktopimportpage_checkingcompletefile()
    static let sendingDetail = MacStrings.macos_desktopimportpage_sendingtoyourjournal()
    static let waitingDetail = MacStrings.macos_desktopimportpage_waitingtogotoyourjournal()
    static let integrityMismatch = MacStrings.macos_desktopimportpage_integritymismatch()
    static let uploadExpired = MacStrings.macos_desktopimportpage_uploadexpired()
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
    static let openImportToReview = MacStrings.macos_desktopimportpage_openimporttoreview()
    static let storeUnreadable = MacStrings.macos_desktopimportpage_couldntreadimportsonthisdevicenothinghasbeenr()
    static let soFar = MacStrings.macos_desktopsource_sofar()
    static let lastTakenIn = MacStrings.macos_desktopsource_lasttakenin()

    static func removeTitle(_ name: String) -> String { MacStrings.macos_desktopimportpage_remove2("\(name)") }
    static func saving(_ done: Int, _ total: Int) -> String { MacStrings.macos_desktopimportpage_savingonthisdeviceof(MacStrings.number(done + 1), MacStrings.number(total)) }
    static func saved(_ count: Int) -> String { MacStrings.macos_desktopimportpage_savedonthisdevice(MacStrings.number(count)) }
    static func reviewItemA11y(_ name: String) -> String { MacStrings.macos_desktopimportpage_reviewiteminyourjournal(name) }
    static func sendItemAgainA11y(_ name: String) -> String { MacStrings.macos_desktopimportpage_senditemagaintoreview(name) }
    static func tryNowItemA11y(_ name: String) -> String { MacStrings.macos_desktopimportpage_trynowitem(name) }
    static func cancelItemA11y(_ name: String) -> String { MacStrings.macos_desktopimportpage_cancelitem(name) }
    static func removeItemA11y(_ name: String) -> String { MacStrings.macos_accessibility_removeitem(name) }
    static func tileProgress(sent: String, total: String) -> String {
        MacStrings.macos_desktopimportpage_tileprogress(sent, total)
    }
    static func tileProgressMore(count: Int, sent: String, total: String) -> String {
        MacStrings.macos_desktopimportpage_tileprogressmore_plural(count, sent, total)
    }
    static func progressBytes(sent: String, total: String, percent: Int) -> String {
        MacStrings.macos_desktopimportpage_progressbytes(sent, total, MacStrings.number(percent))
    }
    static func pausedDetail(progress: ImportResumableProgress) -> String {
        let sent = importFormatBytes(progress.bytesSent)
        let total = importFormatBytes(progress.bytesTotal)
        return MacStrings.macos_desktopimportpage_pauseddetail(sent, total)
    }
    static func pausedSubline(sent: String, total: String) -> String {
        MacStrings.macos_desktopimportpage_pausedsubline(sent, total)
    }
    static func resumingFrom(sent: String, total: String) -> String {
        MacStrings.macos_desktopimportpage_resumingfrom(sent, total)
    }
    static func faultDetail(for row: ImportRow, serverSentence: String) -> String {
        switch row.reasonCode {
        case "insufficient_journal_space":
            let totalBytes = row.progress?.bytesTotal ?? row.byteSize
            if totalBytes > 0 {
                return MacStrings.macos_desktopimportpage_insufficientspace(importFormatBytes(totalBytes))
            }
            return serverSentence
        case "whole_file_checksum_mismatch":
            return integrityMismatch
        case "upload_not_found":
            return uploadExpired
        default:
            return serverSentence
        }
    }
    static func inYourJournalRelative(_ relative: String) -> String { MacStrings.macos_desktopimportpage_inyourjournalrelative(relative) }
    static func pillReady(_ count: Int) -> String { MacStrings.macos_desktopimportpage_pillready_plural(count) }
    static func statusReadyHeadline(_ count: Int) -> String { MacStrings.macos_desktopimportpage_statusreadyheadline_plural(count) }
    static func stateAnnouncement(name: String, state: String) -> String { MacStrings.macos_desktopimportpage_stateannouncement(name, state) }

    static func recentRowA11y(name: String, relative: String, linkable: Bool) -> String {
        linkable
            ? MacStrings.macos_desktopimportpage_recentrowa11y(name, relative)
            : MacStrings.macos_desktopimportpage_recentrowplaina11y(name, relative)
    }

    static func reviewDetailLine(for row: ImportRow) -> String {
        if row.kind == .reviewExpired || row.reviewExpired {
            return reviewExpired
        }
        if row.reviewKind == "body_confirmation_required" {
            return reviewDetailHour
        }
        return reviewDetail
    }

    /// Shown at the top of `on this device` only when the queue itself is held.
    static func queueHoldLine(_ snapshot: ImportSnapshot) -> String? {
        let hasQueueRows = snapshot.onDeviceRows.contains { row in
            switch row.kind {
            case .waiting, .paused, .goingAgain: return true
            case .sending, .refused, .missingCopy, .readyToReview, .reviewExpired: return false
            }
        }
        guard hasQueueRows || snapshot.waiting == .journalTooOld else { return nil }
        switch snapshot.waiting {
        case .unpaired: return MacStrings.macos_desktopimportpage_importswaitonthisdeviceuntilyouconnectajourna()
        case .awaitingConfirmation: return MacStrings.macos_desktopimportpage_importswaituntilyouconfirmyourjournalsmark()
        case .pairingRefused: return MacStrings.macos_desktopimportpage_yourjournalstoppedacceptingthisdeviceimportsw()
        case .journalTooOld: return MacStrings.macos_desktopimportpage_importswaituntilyourjournalisupdated()
        case .checkingJournal: return MacStrings.macos_desktopimportpage_checkingyourjournal()
        case .waiting:
            return snapshot.offline ? MacStrings.macos_desktopimportpage_waitingforreconnect() : nil
        case .sending:
            return nil
        }
    }

    static func statusRowSubline(_ snapshot: ImportSnapshot) -> String {
        if snapshot.hasFault { return importsNeedYou }
        if snapshot.readyToReviewCount > 0 { return pillReady(snapshot.readyToReviewCount) }
        if let active = snapshot.rows.first(where: { $0.kind == .sending }) {
            if let progress = active.progress {
                if progress.phase == .checking { return checkingCompleteFile }
                return progressBytes(
                    sent: importFormatBytes(progress.bytesSent),
                    total: importFormatBytes(progress.bytesTotal),
                    percent: progress.percent
                )
            }
            return sendingDetail
        }
        if let paused = snapshot.rows.first(where: { $0.kind == .paused }),
           let progress = paused.progress {
            return pausedSubline(
                sent: importFormatBytes(progress.bytesSent),
                total: importFormatBytes(progress.bytesTotal)
            )
        }
        if let hold = queueHoldLine(snapshot) { return hold }
        return waitingDetail
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
}

/// Distinct shape + color markers for every import state (never color alone).
enum ImportMarkerKind: Equatable {
    case waiting
    case paused
    case sending
    case readyToReview
    case expired
    case needsAttention
    case delivered
}

struct ImportStateMarker: View {
    let kind: ImportMarkerKind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch kind {
            case .waiting:
                Circle()
                    .stroke(SetupChromeColor.softInk(for: scheme), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
            case .paused:
                HStack(spacing: 2) {
                    Capsule()
                        .fill(SetupChromeColor.softInk(for: scheme))
                        .frame(width: 2.2, height: 8)
                    Capsule()
                        .fill(SetupChromeColor.softInk(for: scheme))
                        .frame(width: 2.2, height: 8)
                }
            case .sending:
                ZStack {
                    Circle()
                        .fill(SetupChromeColor.orangeWash(for: scheme))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(SetupChromeColor.solOrange)
                        .frame(width: 6, height: 6)
                }
            case .readyToReview:
                ZStack {
                    Circle()
                        .stroke(SetupChromeColor.orangeText(for: scheme), lineWidth: 1.6)
                        .frame(width: 9, height: 9)
                    Circle()
                        .fill(SetupChromeColor.solOrange)
                        .frame(width: 3.5, height: 3.5)
                }
            case .expired:
                Circle()
                    .stroke(
                        SetupChromeColor.orangeText(for: scheme),
                        style: StrokeStyle(lineWidth: 1.5, dash: [2.2, 1.8])
                    )
                    .frame(width: 8.5, height: 8.5)
            case .needsAttention:
                Rectangle()
                    .fill(DeckStyle.attentionInk)
                    .frame(width: 6.5, height: 6.5)
                    .rotationEffect(.degrees(45))
            case .delivered:
                ZStack {
                    Circle()
                        .fill(SetupChromeColor.successDot(for: scheme).opacity(scheme == .dark ? 0.24 : 0.16))
                        .frame(width: 14, height: 14)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(SetupChromeColor.successInk(for: scheme))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ImportProgressBar: View {
    let fraction: Double
    let active: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let clamped = min(1.0, max(0.0, fraction))
            let width = geo.size.width * clamped
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SetupChromeColor.hairline(for: scheme))
                if clamped > 0 {
                    Capsule()
                        .fill(active ? SetupChromeColor.solOrange : SetupChromeColor.softInk(for: scheme))
                        .frame(width: min(geo.size.width, max(4, width)))
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// `import` on the deck: calm when idle (`import` / `files`, no switch, no `on`/`off`), live
/// worst-signal-wins status (`needs attention` > `ready to review` > `sending` > `paused` > `waiting`)
/// while active or awaiting the owner.
struct ImportTile: View {
    var snapshot = ImportSnapshot()
    var selected = false
    var compact = false
    var keyboardFocused = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let presentation = deriveImportTile(snapshot)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15))
                        .foregroundStyle(glyphTint(for: presentation.state))
                        .accessibilityHidden(true)
                    if compact { name }
                }
                if !compact {
                    Spacer(minLength: 8)
                    name
                }
                if let word = presentation.displayedWord {
                    HStack(spacing: 5) {
                        ImportStateMarker(kind: markerKind(for: presentation.state))
                        Text(word)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(stateInk(for: presentation.state))
                            .lineLimit(1)
                    }
                }
                Text(presentation.subline)
                    .font(.system(size: 11))
                    .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 66 : 104, alignment: .topLeading)
            .padding(compact ? 11 : 13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SetupChromeColor.card(for: scheme)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor(for: presentation.state), lineWidth: borderWidth(for: presentation.state))
        )
        .overlay {
            if keyboardFocused {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(ImportCopy.title)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(AXID.Deck.importTile)
        .overlay(alignment: .topLeading) {
            AXStateCompanion(id: AXID.Deck.importTileState, value: presentation.state.axToken)
        }
    }

    private var name: some View {
        Text(ImportCopy.title)
            .font(DeckStyle.name(compact ? 16 : 17))
            .foregroundStyle(SetupChromeColor.ink(for: scheme))
    }

    private func markerKind(for state: ImportTileState) -> ImportMarkerKind {
        switch state {
        case .idle, .waiting: return .waiting
        case .paused: return .paused
        case .sending: return .sending
        case .readyToReview: return .readyToReview
        case .needsAttention: return .needsAttention
        }
    }

    private func glyphTint(for state: ImportTileState) -> Color {
        switch state {
        case .needsAttention: return DeckStyle.attentionInk
        case .readyToReview: return SetupChromeColor.orangeText(for: scheme)
        case .idle, .waiting, .paused, .sending: return SetupChromeColor.softInk(for: scheme)
        }
    }

    private func stateInk(for state: ImportTileState) -> Color {
        switch state {
        case .needsAttention: return DeckStyle.attentionInk
        case .readyToReview: return SetupChromeColor.orangeText(for: scheme)
        case .sending: return SetupChromeColor.ink(for: scheme)
        case .idle, .waiting, .paused: return SetupChromeColor.softInk(for: scheme)
        }
    }

    private func borderColor(for state: ImportTileState) -> Color {
        if selected { return SetupChromeColor.solOrange }
        switch state {
        case .needsAttention: return DeckStyle.attentionInk
        case .readyToReview: return SetupChromeColor.orangeText(for: scheme)
        case .idle, .waiting, .paused, .sending: return SetupChromeColor.hairline(for: scheme)
        }
    }

    private func borderWidth(for state: ImportTileState) -> CGFloat {
        if selected { return 2 }
        switch state {
        case .needsAttention, .readyToReview: return 1.25
        case .idle, .waiting, .paused, .sending: return 1
        }
    }
}

/// The import page: intro + actions, screenshots pointer, `waiting for your review`,
/// `on this device`, 24h `recent` receipts, and lifetime `so far` / `last taken in` totals.
struct DesktopImportPage: View {
    let appState: AppState
    let header: AnyView
    let openScreenshots: () -> Void
    var announce: @MainActor (String) -> Void = { message in
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
    }

    @State private var confirming: ImportRow?
    @State private var changeLine: String?
    @State private var previousRowKinds: [String: ImportRowKind] = [:]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let source = appState.importSource
        let snapshot = source?.snapshot ?? ImportSnapshot()
        let reviewRows = snapshot.reviewRows
        let onDeviceRows = snapshot.onDeviceRows

        VStack(alignment: .leading, spacing: 14) {
            header

            actionsCard(snapshot: snapshot)

            if let intake = snapshot.intake, !snapshot.storeUnreadable {
                intakeLines(intake)
                    .onDisappear { Task { await source?.intakeSeen() } }
            }

            if snapshot.interruptedAdd {
                HStack(spacing: 8) {
                    Text(ImportCopy.interrupted).font(.callout)
                    Spacer(minLength: 8)
                    Button(ImportCopy.ok) { Task { await source?.dismissInterrupted() } }
                }
            }

            if let changeLine {
                Text(changeLine)
                    .font(.callout)
                    .foregroundStyle(SetupChromeColor.softInk(for: scheme))
            }

            if !snapshot.storeUnreadable && !reviewRows.isEmpty {
                reviewCard(rows: reviewRows, snapshot: snapshot)
            }

            if !snapshot.storeUnreadable && !onDeviceRows.isEmpty {
                onDeviceCard(rows: onDeviceRows, snapshot: snapshot)
            }

            if !snapshot.storeUnreadable && (!snapshot.recentReceipts.isEmpty || !snapshot.hasActiveOrHeldItems || snapshot.canOpenJournalImport) {
                recentCard(snapshot: snapshot)
            }

            ImportTotalRows(appState: appState)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.importPage)
        .onAppear {
            previousRowKinds = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0.kind) })
            appState.importSource?.reconcile()
        }
        .onChange(of: snapshot.intake) { _, newValue in
            guard case .finished(let accepted, _) = newValue else { return }
            announce(accepted == 0 ? ImportCopy.nothingSaved : ImportCopy.saved(accepted))
        }
        .onChange(of: snapshot.rows) { _, newRows in
            for row in newRows {
                let old = previousRowKinds[row.id]
                guard old != row.kind else { continue }
                switch row.kind {
                case .readyToReview:
                    announce(ImportCopy.stateAnnouncement(name: row.name, state: ImportCopy.readyToReview))
                case .reviewExpired:
                    announce(ImportCopy.stateAnnouncement(name: row.name, state: ImportCopy.expired))
                case .refused, .missingCopy:
                    announce(ImportCopy.stateAnnouncement(name: row.name, state: DeckStateWord.needsAttention.word))
                case .waiting, .sending, .paused, .goingAgain:
                    break
                }
            }
            previousRowKinds = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0.kind) })
        }
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
            Text(removeConfirmMessage(for: row))
        }
    }

    private var screenshotsOn: Bool { appState.screenshotSource?.snapshot.switchOn ?? false }

    private func removeConfirmMessage(for row: ImportRow) -> String {
        if row.kind == .missingCopy { return ImportCopy.missingCopyRemove }
        if row.kind == .readyToReview || (row.savedAtJournal && row.kind != .reviewExpired) {
            return ImportCopy.savedRemove
        }
        return ImportCopy.plainRemove
    }

    // MARK: - cards

    private func actionsCard(snapshot: ImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ImportCopy.adds)
                .font(.callout)
                .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                .fixedSize(horizontal: false, vertical: true)

            if snapshot.storeUnreadable {
                Text(ImportCopy.storeUnreadable)
                    .font(.callout)
                    .foregroundStyle(DeckStyle.attentionInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    chooseFiles()
                } label: {
                    Text(ImportCopy.choose)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SetupChromeColor.primaryLabel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(SetupChromeColor.solOrange.opacity(snapshot.storeUnreadable ? 0.45 : 1.0))
                        )
                }
                .buttonStyle(.plain)
                .disabled(snapshot.storeUnreadable)
                .accessibilityIdentifier(AXID.Deck.importChoose)

                if snapshot.canOpenJournalImport {
                    Button {
                        appState.openJournalImportPage()
                    } label: {
                        Text(ImportCopy.moreImports)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SetupChromeColor.ink(for: scheme))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(SetupChromeColor.card(for: scheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(SetupChromeColor.hairline2(for: scheme), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AXID.Deck.importMore)
                }
            }

            if snapshot.canOpenJournalImport {
                Text(ImportCopy.moreImportsSubline)
                    .font(.caption)
                    .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .overlay(SetupChromeColor.hairline(for: scheme))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ImportCopy.screenshotsPointer)
                    .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                Spacer(minLength: 8)
                Button(action: openScreenshots) {
                    Text(screenshotsOn ? ImportCopy.openScreenshots : ImportCopy.setUpScreenshots)
                        .underline()
                        .foregroundStyle(SetupChromeColor.orangeText(for: scheme))
                }
                .buttonStyle(.plain)
            }
            .font(.callout)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SetupChromeColor.card(for: scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SetupChromeColor.hairline(for: scheme), lineWidth: 1))
    }

    private func reviewCard(rows: [ImportRow], snapshot: ImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ImportCopy.waitingForYourReview)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SetupChromeColor.orangeText(for: scheme))
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().overlay(SetupChromeColor.hairline(for: scheme))
                }
                reviewRow(row, canOpenJournal: snapshot.canOpenJournalImport)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SetupChromeColor.card(for: scheme)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SetupChromeColor.orangeText(for: scheme), lineWidth: 1.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.importReviewSection)
    }

    private func reviewRow(_ row: ImportRow, canOpenJournal: Bool) -> some View {
        let isExpired = row.kind == .reviewExpired || row.reviewExpired
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupChromeColor.ink(for: scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                statusChip(
                    marker: isExpired ? .expired : .readyToReview,
                    label: isExpired ? ImportCopy.expired : ImportCopy.readyToReview,
                    ink: SetupChromeColor.ink(for: scheme),
                    fill: SetupChromeColor.orangeWash(for: scheme),
                    border: nil
                )
            }

            Text(ImportCopy.reviewDetailLine(for: row))
                .font(.caption)
                .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if isExpired {
                    Button {
                        Task {
                            changeLine = ImportCopy.change(await appState.importSource?.sendAgain(row.id) ?? .gone)
                        }
                    } label: {
                        Text(ImportCopy.sendAgainToReview)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SetupChromeColor.primaryLabel)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SetupChromeColor.solOrange))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ImportCopy.sendItemAgainA11y(row.name))
                } else {
                    Button {
                        if let importID = row.importID, appState.openJournalImport(id: importID) {
                            return
                        }
                        appState.openJournalImportPage()
                    } label: {
                        Text(ImportCopy.reviewInYourJournal)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SetupChromeColor.primaryLabel)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(SetupChromeColor.solOrange.opacity(canOpenJournal ? 1.0 : 0.45))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canOpenJournal)
                    .accessibilityLabel(ImportCopy.reviewItemA11y(row.name))
                }

                quietRowButton(ImportCopy.remove, accessibilityLabel: ImportCopy.removeItemA11y(row.name)) {
                    confirming = row
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.importItem(row.id))
    }

    private func onDeviceCard(rows: [ImportRow], snapshot: ImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ImportCopy.onThisDevice)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
                .accessibilityAddTraits(.isHeader)

            if let hold = ImportCopy.queueHoldLine(snapshot) {
                Text(hold)
                    .font(.caption)
                    .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SetupChromeColor.sheet(for: scheme)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SetupChromeColor.hairline(for: scheme), lineWidth: 1))
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().overlay(SetupChromeColor.hairline(for: scheme))
                }
                onDeviceRow(row)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SetupChromeColor.card(for: scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SetupChromeColor.hairline(for: scheme), lineWidth: 1))
    }

    private func onDeviceRow(_ row: ImportRow) -> some View {
        let detail: String
        let marker: ImportMarkerKind
        let chipLabel: String
        let isFault: Bool
        let showProgressBar: Bool
        let progressFraction: Double
        let progressActive: Bool
        let canCancelActiveResumable: Bool
        switch row.kind {
        case .sending:
            marker = .sending
            isFault = false
            if let progress = row.progress {
                showProgressBar = true
                progressActive = true
                if progress.phase == .checking {
                    chipLabel = ImportCopy.checkingFile
                    detail = ImportCopy.checkingCompleteFile
                    progressFraction = 1.0
                    canCancelActiveResumable = false
                } else {
                    chipLabel = ImportCopy.sending
                    let sent = importFormatBytes(progress.bytesSent)
                    let total = importFormatBytes(progress.bytesTotal)
                    detail = progress.resuming
                        ? ImportCopy.resumingFrom(sent: sent, total: total)
                        : ImportCopy.progressBytes(sent: sent, total: total, percent: progress.percent)
                    progressFraction = progress.fraction
                    canCancelActiveResumable = true
                }
            } else {
                detail = ImportCopy.sendingDetail
                chipLabel = ImportCopy.sending
                showProgressBar = false
                progressFraction = 0
                progressActive = true
                canCancelActiveResumable = false
            }
        case .paused:
            marker = .paused
            chipLabel = ImportCopy.paused
            isFault = false
            canCancelActiveResumable = false
            if let progress = row.progress {
                detail = ImportCopy.pausedDetail(progress: progress)
                showProgressBar = true
                progressFraction = progress.fraction
                progressActive = false
            } else {
                detail = ImportCopy.waitingDetail
                showProgressBar = false
                progressFraction = 0
                progressActive = false
            }
        case .waiting, .goingAgain:
            detail = ImportCopy.waitingDetail
            marker = .waiting
            chipLabel = ImportCopy.waiting
            isFault = false
            showProgressBar = false
            progressFraction = 0
            progressActive = false
            canCancelActiveResumable = false
        case .refused(let sentence):
            detail = ImportCopy.faultDetail(for: row, serverSentence: sentence)
            marker = .needsAttention
            chipLabel = DeckStateWord.needsAttention.word
            isFault = true
            showProgressBar = false
            progressFraction = 0
            progressActive = false
            canCancelActiveResumable = false
        case .missingCopy:
            detail = ImportCopy.missingCopy
            marker = .needsAttention
            chipLabel = DeckStateWord.needsAttention.word
            isFault = true
            showProgressBar = false
            progressFraction = 0
            progressActive = false
            canCancelActiveResumable = false
        case .readyToReview, .reviewExpired:
            detail = ImportCopy.reviewDetailLine(for: row)
            marker = row.kind == .reviewExpired ? .expired : .readyToReview
            chipLabel = row.kind == .reviewExpired ? ImportCopy.expired : ImportCopy.readyToReview
            isFault = false
            showProgressBar = false
            progressFraction = 0
            progressActive = false
            canCancelActiveResumable = false
        }
        let refusedHere: Bool = { if case .refused = row.kind { return true } else { return false } }()

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupChromeColor.ink(for: scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                statusChip(
                    marker: marker,
                    label: chipLabel,
                    ink: isFault ? DeckStyle.attentionInk : (row.kind == .sending ? SetupChromeColor.ink(for: scheme) : SetupChromeColor.softInk(for: scheme)),
                    fill: isFault ? DeckStyle.attentionInk.opacity(scheme == .dark ? 0.16 : 0.10) : SetupChromeColor.sheet(for: scheme),
                    border: isFault ? nil : SetupChromeColor.hairline(for: scheme)
                )
            }

            if showProgressBar {
                ImportProgressBar(fraction: progressFraction, active: progressActive)
                    .padding(.vertical, 2)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(isFault ? DeckStyle.attentionInk : SetupChromeColor.softInk(for: scheme))
                .fixedSize(horizontal: false, vertical: true)

            if row.kind == .sending {
                if canCancelActiveResumable {
                    HStack(spacing: 8) {
                        quietRowButton(ImportCopy.cancel, accessibilityLabel: ImportCopy.cancelItemA11y(row.name)) {
                            Task { changeLine = ImportCopy.change(await appState.importSource?.cancel(row.id) ?? .gone) }
                        }
                    }
                }
            } else if row.kind == .paused {
                HStack(spacing: 8) {
                    Button {
                        Task { changeLine = ImportCopy.change(await appState.importSource?.resume(row.id) ?? .gone) }
                    } label: {
                        Text(ImportCopy.tryNow)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SetupChromeColor.ink(for: scheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SetupChromeColor.sheet(for: scheme)))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SetupChromeColor.hairline2(for: scheme), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ImportCopy.tryNowItemA11y(row.name))
                    quietRowButton(ImportCopy.cancel, accessibilityLabel: ImportCopy.cancelItemA11y(row.name)) {
                        Task { changeLine = ImportCopy.change(await appState.importSource?.cancel(row.id) ?? .gone) }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if refusedHere && row.retryable {
                        Button {
                            Task { changeLine = ImportCopy.change(await appState.importSource?.retry(row.id) ?? .gone) }
                        } label: {
                            Text(ImportCopy.tryNow)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SetupChromeColor.ink(for: scheme))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SetupChromeColor.sheet(for: scheme)))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SetupChromeColor.hairline2(for: scheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ImportCopy.tryNowItemA11y(row.name))
                    }
                    quietRowButton(ImportCopy.remove, accessibilityLabel: ImportCopy.removeItemA11y(row.name)) {
                        confirming = row
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.importItem(row.id))
    }

    private func recentCard(snapshot: ImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ImportCopy.recent)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
                .accessibilityAddTraits(.isHeader)

            if !snapshot.recentReceipts.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(snapshot.recentReceipts.enumerated()), id: \.element.id) { index, receipt in
                            if index > 0 {
                                Divider().overlay(SetupChromeColor.hairline(for: scheme))
                            }
                            recentReceiptRow(receipt, now: context.date, canOpenJournal: snapshot.canOpenJournalImport)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AXID.Deck.importRecent)
            } else if !snapshot.hasActiveOrHeldItems {
                Text(ImportCopy.nothingYet)
                    .font(.callout)
                    .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                    .accessibilityIdentifier(AXID.Deck.importRecent)
            }

            if snapshot.canOpenJournalImport {
                Button {
                    appState.openJournalImportPage()
                } label: {
                    Text(ImportCopy.allImportHistory)
                        .font(.callout)
                        .underline()
                        .foregroundStyle(SetupChromeColor.orangeText(for: scheme))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityIdentifier(AXID.Deck.importAllHistory)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SetupChromeColor.card(for: scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SetupChromeColor.hairline(for: scheme), lineWidth: 1))
    }

    @ViewBuilder
    private func recentReceiptRow(_ receipt: ImportRecentReceipt, now: Date, canOpenJournal: Bool) -> some View {
        let relative = relativeWords(receipt.deliveredAt, now: now)
        let validID = validImportID(receipt.importID)
        let linkable = canOpenJournal && validID != nil
        let content = HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.filename)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupChromeColor.ink(for: scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    ImportStateMarker(kind: .delivered)
                    Text(ImportCopy.inYourJournalRelative(relative))
                        .font(.caption)
                        .foregroundStyle(SetupChromeColor.successInk(for: scheme))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if linkable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())

        if linkable, let importID = validID {
            Button {
                _ = appState.openJournalImport(id: importID)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ImportCopy.recentRowA11y(name: receipt.filename, relative: relative, linkable: true))
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(ImportCopy.recentRowA11y(name: receipt.filename, relative: relative, linkable: false))
        }
    }

    private func statusChip(
        marker: ImportMarkerKind,
        label: String,
        ink: Color,
        fill: Color,
        border: Color?
    ) -> some View {
        HStack(spacing: 5) {
            ImportStateMarker(kind: marker)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(fill))
        .overlay {
            if let border {
                Capsule().stroke(border, lineWidth: 1)
            }
        }
    }

    private func quietRowButton(_ title: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SetupChromeColor.hairline2(for: scheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func intakeLines(_ intake: ImportIntakeLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch intake {
            case .copying(let done, let total):
                Text(ImportCopy.saving(done, total))
            case .finished(let accepted, let refused):
                Text(accepted == 0 ? ImportCopy.nothingSaved : ImportCopy.saved(accepted))
                ForEach(Array(refused.enumerated()), id: \.offset) { _, item in
                    Text("\(item.name): \(ImportCopy.refusal(item.reason))")
                        .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.Deck.importIntake)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await appState.importSource?.add(urls) }
    }
}

/// Lifetime `so far` and `last taken in` rows on the import pane, matching other macOS source pages.
/// Absent when `source-totals.json` cannot be read.
struct ImportTotalRows: View {
    let appState: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let facts = importTotalFacts(appState.sourceTotalsView, now: context.date) {
                VStack(spacing: 6) {
                    factRow(ImportCopy.soFar, facts.soFar)
                    if let last = facts.lastTakenIn {
                        factRow(ImportCopy.lastTakenIn, last)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 4)
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(SetupChromeColor.softInk(for: scheme))
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
