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

            VStack(alignment: .leading, spacing: 8) {
                Text("your journal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let facts = snapshotJournalFacts {
                    ForEach(facts, id: \.self) { fact in
                        LabeledContent(fact[0], value: fact[1])
                    }
                } else if appState.deckHasJournal {
                    LabeledContent("connection", value: appState.tunnelLifecycleOwner.connectionVerdict.message)
                    lastDeliveryDetailRow
                }
                if resolvedServiceMode(for: appState.config) == .external {
                    LabeledContent("kept on this mac", value: storageGlanceText)
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
            case .waitingToSync:
                Text("waiting to sync").font(DeckStyle.name(22))
                Text("on this device").foregroundStyle(.secondary)
            case .connecting:
                Text("connecting…").font(DeckStyle.name(22))
            case .offline(let n):
                Text("\(n)").font(DeckStyle.name(34))
                Text("waiting to sync").foregroundStyle(.secondary)
                Text("on this device").foregroundStyle(.secondary)
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
