// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SolstoneCore
import SwiftUI

// The status pane: the status and its line, one row per source with what it has taken in, then the
// journal's own facts and the technical details. A source row never says the source's state or
// fault: its tile beside the pane says that.
extension SettingsView {
    var snapshotJournalFacts: [[String]]? {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        return appState.snapshotJournalFacts
#else
        return nil
#endif
    }

    var statusPane: some View {
        let pill = appState.journalPill
        return VStack(alignment: .leading, spacing: 16) {
            paneHeader("status", closable: false)
            statusLead(pill)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AXID.Deck.statusLead)
                .accessibilityValue(pill.axToken)

            StatusSourceRows(appState: appState)

            if let imports = appState.importSource?.snapshot, !imports.rows.isEmpty {
                // Imports still on this Mac get one row, saying why they wait; it opens import.
                Button { openPane(.importPage) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ImportCopy.title)
                            Text(ImportCopy.recent(imports)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .accessibilityIdentifier(AXID.Deck.importStatusRow)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("your journal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let facts = snapshotJournalFacts {
                    ForEach(facts, id: \.self) { fact in
                        StatusFactRow(label: fact[0], value: fact[1])
                    }
                } else if appState.deckHasJournal {
                    StatusFactRow(label: "connection", value: statusConnectionValue(
                        pill, connectionLine: appState.tunnelLifecycleOwner.connectionVerdict.message
                    ))
                    statusLastDeliveryRow
                    if !appState.uploadCoordinator.unwrittenSegments.isEmpty {
                        UnwrittenSegmentRows(appState: appState)
                    }
                }
                if resolvedServiceMode(for: appState.config) == .external {
                    StatusFactRow(label: "kept on this mac", value: storageGlanceText)
                }
            }
            .font(.callout)

            DisclosureGroup("technical details") {
                VStack(alignment: .leading, spacing: 12) {
                    statusSetupRows
                    #if DEBUG
                    Toggle("1-minute segments", isOn: debugSegmentsBinding)
                        .help("use 1-minute segments instead of 5-minute for testing")
                        .accessibilityIdentifier(AXID.Settings.Status.debugOneMinuteSegments)
                    #endif
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
        // Automation reads these two off the status pane, so they render whatever it shows.
        .overlay(alignment: .topLeading) {
            ZStack {
                AXStateCompanion(id: AXID.Settings.Status.observingState, value: renderedObservationAXState.axToken)
                if appState.isRecording && !appState.isPaused {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        AXStateCompanion(
                            id: AXID.Settings.Status.nextSegmentSeconds,
                            value: axIntegerString(Int(appState.captureManager.segmentTimeRemaining))
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.statusPane)
    }

    @ViewBuilder
    private func statusLead(_ pill: JournalPill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch pill {
            case .connected:
                Text("all caught up").font(DeckStyle.name(26))
                Text("everything is in your journal").foregroundStyle(.secondary)
            case .syncing(let n):
                Text("\(n)").font(DeckStyle.name(34))
                Text("syncing to your journal…").foregroundStyle(.secondary)
            case .waiting(let n):
                Text("\(n)").font(DeckStyle.name(34))
                Text(DeckCopy.onThisDevice).foregroundStyle(.secondary)
            case .waitingToSync:
                Text("waiting to sync").font(DeckStyle.name(22))
                Text("on this device").foregroundStyle(.secondary)
            case .connectedHeld(.segmentsNotWritten):
                Text("nothing waiting to sync").font(DeckStyle.name(22))
            case .connectedHeld(.importsNeedYou):
                Text(ImportCopy.importsNeedYou).font(DeckStyle.name(22))
                Text(ImportCopy.openImportToSeeWhy).foregroundStyle(.secondary)
            case .connecting:
                Text("connecting…").font(DeckStyle.name(22))
            case .offline:
                // The pill's own words, as every computer says them, then where the waiting items are.
                Text(pill.text).font(DeckStyle.name(22))
                Text(DeckCopy.onThisDevice).foregroundStyle(.secondary)
            case .syncPaused(let n):
                if n > 0 { Text("\(n)").font(DeckStyle.name(34)) }
                Text("sync paused").font(n > 0 ? .body : DeckStyle.name(22)).foregroundStyle(n > 0 ? .secondary : .primary)
                if n > 0 { Text("on this device").foregroundStyle(.secondary) }
                Button("your journal") { navigate(.service) }.buttonStyle(.link)
            case .notPaired:
                Text("not paired").font(DeckStyle.name(22))
                Button("connect a journal") { navigate(.service) }
            case .confirmMark(let n):
                if n > 0 { Text("\(n)").font(DeckStyle.name(34)) }
                Text("waiting for you to confirm your journal's mark")
                Text("nothing waiting goes into your journal until you do.").foregroundStyle(.secondary)
                Button("confirm the mark") {
                    NotificationCenter.default.post(name: .reaskJournalMark, object: nil)
                }
            case .pairAgain(let n):
                if n > 0 { Text("\(n)").font(DeckStyle.name(34)) }
                Text(appState.tunnelLifecycleOwner.connectionVerdict.message)
                configuredJournalRecoveryRow(for: appState.tunnelLifecycleOwner.connectionVerdict.failureCause)
            case .needsNewLink:
                Text(pill.text).font(DeckStyle.name(20))
                Button("your journal") { navigate(.service) }
            }
        }
    }

    /// The last delivery as a status fact row, keeping the companions automation reads.
    private var statusLastDeliveryRow: some View {
        let outcome = appState.uploadCoordinator.lastJournalDeliveryOutcome
        return VStack(alignment: .leading, spacing: 0) {
            StatusFactRow(label: UICopy.SETTINGS_LAST_DELIVERY_LABEL, value: diagnosticDeliveryValue(outcome, now: Date()))
            AXStateCompanion(
                id: AXID.Settings.Status.lastDeliveryState,
                value: outcome.diagnosticAXState.axToken
            )
            if case .delivered(let date) = outcome {
                AXStateCompanion(
                    id: AXID.Settings.Status.lastDeliveryTimestamp,
                    value: axIntegerString(Int(date.timeIntervalSince1970))
                )
            }
        }
    }

    /// `check my setup` without the two permission rows, which now sit on the audio and screen pages.
    private var statusSetupRows: some View {
        let rows = setupSnapshotPresentation.rows.filter { $0.id != .screenRecording && $0.id != .microphone }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                setupCheckRow(row)
            }
            Divider()
            HStack(alignment: .top) {
                Text(aboutBlock)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AXID.Settings.Status.setupAboutState)
                    .accessibilityValue(aboutBlock)
                Spacer(minLength: 8)
            }
        }
    }
}

/// One row per source with `so far` and `last taken in`, the iPad's status rows, for every source on
/// the deck. A row carries those two facts only: the tile beside it says the source's state. A source
/// with nothing recorded, or a record that can't be read, reads `nothing yet` under `so far`.
struct StatusSourceRows: View {
    let appState: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let view = appState.sourceTotalsView
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("sources")
                    Spacer()
                    Text("so far").frame(width: 92, alignment: .trailing)
                    Text("last taken in").frame(width: 92, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                ForEach(DeckSource.available, id: \.self) { source in
                    let row = statusSourceRow(view, source: source, now: context.date)
                    HStack {
                        Image(systemName: source.systemImage)
                            .font(.system(size: 12))
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(source.label)
                        Spacer()
                        Text(row.soFar)
                            .foregroundStyle(row.lastTakenIn == nil ? .secondary : .primary)
                            .frame(width: 92, alignment: .trailing)
                        Text(row.lastTakenIn ?? "")
                            .frame(width: 92, alignment: .trailing)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// One of the journal's facts in the status pane: the label at the left and the value at the same
/// right edge as the source rows' last column. A value too long for the row goes under its label.
struct StatusFactRow: View {
    let label: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(value)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Segments the journal answered it would not write, under `your journal` › `on this device`.
/// Each can be removed from this Mac. Sync still tries them again once their quiet window ends.
struct UnwrittenSegmentRows: View {
    let appState: AppState
    @State private var confirming: UnwrittenSegment?

    var body: some View {
        let coordinator: UploadCoordinator = appState.uploadCoordinator
        let passRunning = unwrittenRemoveBlocked(status: coordinator.status, syncPaused: coordinator.syncPaused)
        VStack(alignment: .leading, spacing: 6) {
            Text(DeckCopy.onThisDevice).foregroundStyle(.secondary)
            ForEach(coordinator.unwrittenSegments, id: \.self) { segment in
                let name = unwrittenSegmentName(segment)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        Text(UnwrittenCopy.reason).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(UnwrittenCopy.remove) { confirming = segment }
                        .disabled(passRunning)
                        .accessibilityLabel("\(UnwrittenCopy.remove) \(name)")
                        .accessibilityIdentifier(AXID.Deck.unwrittenRemove(segment.day, segment.segment))
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AXID.Deck.unwrittenRow(segment.day, segment.segment))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.unwrittenList)
        .confirmationDialog(
            confirming.map { UnwrittenCopy.confirmTitle(unwrittenSegmentName($0)) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { segment in
            Button(UnwrittenCopy.remove, role: .destructive) {
                Task { _ = await coordinator.removeUnwritten(segment) }
            }
            Button(UnwrittenCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(UnwrittenCopy.confirmMessage)
        }
    }
}

enum UnwrittenCopy {
    static let reason = "your journal couldn't take all of this."
    static let remove = "remove"
    static let cancel = "cancel"
    static let confirmMessage = "this removes the copy on this device, so what your journal didn't take won't reach it."
    static func confirmTitle(_ name: String) -> String { "remove \(name)?" }
}

/// Whether `remove` waits: a pass is running unless sync is paused.
func unwrittenRemoveBlocked(status: UploadCoordinator.Status, syncPaused: Bool) -> Bool {
    guard !syncPaused else { return false }
    switch status {
    case .syncing, .uploading, .retrying: return true
    case .notSynced, .awaitingTunnel, .synced, .offline, .blocked: return false
    }
}

/// A segment's start, from its day key (`yyyyMMdd`) and folder (`HHmmss_…`), as the owner reads it.
func unwrittenSegmentName(_ segment: UnwrittenSegment, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let day = segment.day
    let time = segment.segment.prefix(6)
    guard day.count == 8, time.count == 6,
          let y = Int(day.prefix(4)), let mo = Int(day.dropFirst(4).prefix(2)), let d = Int(day.suffix(2)),
          let h = Int(time.prefix(2)), let mi = Int(time.dropFirst(2).prefix(2)),
          let date = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi)) else {
        return segment.segment
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.timeZone = timeZone
    return formatter.string(from: date).lowercased()
}
