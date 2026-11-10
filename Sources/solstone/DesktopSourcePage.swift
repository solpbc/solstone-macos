// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI

// A source's page, in one order on every computer: the verdict, the reason and one action,
// what it takes in, what it has taken in, what goes along with it, its children, and what is
// left out of it.
extension SettingsView {
    @ViewBuilder
    func sourcePage(_ source: DeckSource, scrollProxy: ScrollViewProxy) -> some View {
        let tile = deriveDeckTile(source, appState.deckInputs)
        VStack(alignment: .leading, spacing: 16) {
            paneHeader(source.label, systemImage: source.systemImage)
            pageVerdict(tile)
            pageReason(tile)
            Text(takesInSentence(source))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SourceTotalRows(appState: appState, source: source)
            pageBody(source, scrollProxy: scrollProxy)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.page(source))
        .onAppear { pageAppeared(source) }
        .onDisappear { pageDisappeared(source) }
    }

    private func takesInSentence(_ source: DeckSource) -> String {
        switch source {
        case .audio: return DeckCopy.audioTakesIn
        case .screen: return DeckCopy.screenTakesIn
        case .terminal: return DeckCopy.terminalTakesIn
        case .browsers: return DeckCopy.browsersTakesIn
        case .obsidian: return UICopy.Obsidian.EXPLAINER
        }
    }

    private func pageVerdict(_ tile: DeckTile) -> some View {
        HStack(spacing: 8) {
            DeckStateLine(state: tile.state)
            Spacer()
            if let on = tile.switchOn {
                Toggle(tile.source.label, isOn: Binding(get: { on }, set: { switchSource(tile.source, on: $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(SetupChromeColor.solOrange)
                    .accessibilityLabel(tile.source.label)
                    .accessibilityValue(tile.state.word)
                    .accessibilityIdentifier(pageSwitchAXID(tile.source))
            }
        }
    }

    /// The page switches keep the ids their checkboxes had in the shipped sources pane.
    private func pageSwitchAXID(_ source: DeckSource) -> String {
        switch source {
        case .audio: return AXID.Settings.Sources.microphoneCaptureEnabled
        case .screen: return AXID.Settings.Sources.screenCaptureEnabled
        case .terminal: return AXID.Settings.Sources.terminalEnabled
        case .browsers: return AXID.Settings.Sources.browserIntakeEnabled
        case .obsidian: return AXID.Deck.tileSwitch(.obsidian) + ".page"
        }
    }

    @ViewBuilder
    private func pageReason(_ tile: DeckTile) -> some View {
        if let reason = tile.reason, tile.state != .on {
            VStack(alignment: .leading, spacing: 8) {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(tile.state == .needsAttention ? DeckStyle.attentionInk : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if tile.action == .tryAgain {
                    Button(tryAgainInFlight ? UICopy.SETTINGS_TRY_AGAIN_IN_FLIGHT : UICopy.SETTINGS_TRY_AGAIN) {
                        tryAgainInFlight = true
                        Task {
                            await appState.startRecording(reason: .user)
                            tryAgainInFlight = false
                        }
                    }
                    .disabled(tryAgainInFlight)
                    .accessibilityIdentifier(AXID.Settings.Status.tryAgain)
                }
            }
        }
    }

    private func pageSection(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func sharedListLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func pageBody(_ source: DeckSource, scrollProxy: ScrollViewProxy) -> some View {
        switch source {
        case .audio:
            VStack(alignment: .leading, spacing: 14) {
                if appState.config.isMicrophoneCaptureEnabled, !appState.microphoneGranted {
                    microphonePermissionCard
                }
                audioHealthNoteView
                pageSection("microphones")
                microphoneTab
            }
            .overlay(alignment: .topLeading) {
                AXStateCompanion(
                    id: AXID.Settings.Permissions.microphoneLiveState,
                    value: appState.permissionSourceLiveState(for: .microphone).axState.axToken
                )
            }
        case .screen:
            screenRecordingGrantWatcher(
                VStack(alignment: .leading, spacing: 14) {
                    if appState.config.isScreenCaptureEnabled, !appState.screenRecordingGranted || screenRestartPending {
                        screenRecordingPermissionCard
                    }
                    audioHealthNoteView
                    ForEach(appState.siteIntakeNotes, id: \.self) { note in
                        switch note {
                        case .safariKeptOut: Text(UICopy.MENUBAR_A11Y_SAFARI_KEPT_OUT).font(.caption).foregroundStyle(.secondary)
                        case .screenHeld: Text(UICopy.MENUBAR_SITE_SCREEN_HELD).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    pageSection("goes along with it")
                    activityControls
                    audioProcessingGroup
                    pageSection("left out")
                    excludedAppsGroup
                    titlePatternsGroup
                    sharedListLine("this list applies to activity too")
                    websitesGroup(scrollProxy: scrollProxy)
                    sharedListLine("this list applies to activity and browsers too")
                    protectedVideoGroup
                    privateBrowsingGroup(scrollProxy: scrollProxy)
                }
            )
            .overlay(alignment: .topLeading) {
                AXStateCompanion(
                    id: AXID.Settings.Permissions.screenRecordingLiveState,
                    value: appState.permissionSourceLiveState(for: .screen).axState.axToken
                )
            }
        case .terminal:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(terminalPageNotes, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            .alert(UICopy.Terminal.moveTitle, isPresented: Binding(
                get: { appState.terminalMoveOffer },
                set: { appState.terminalMoveOffer = $0 }
            )) {
                Button(UICopy.Terminal.moveConfirm) { appState.confirmTerminalMove() }
                Button(UICopy.Terminal.moveCancel, role: .cancel) {}
            } message: {
                Text(appState.currentDurablePairing == nil
                    ? "\(UICopy.Terminal.moveBody) \(UICopy.Terminal.moveBodyUnpaired)"
                    : UICopy.Terminal.moveBody)
            }
        case .browsers:
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            VStack(alignment: .leading, spacing: 14) {
                browserSourcesGroup
                pageSection("left out")
                websitesGroup(scrollProxy: scrollProxy)
                sharedListLine("this list applies to screen and activity too")
            }
#else
            EmptyView()
#endif
        case .obsidian:
            if let obsidianSource = appState.obsidianSource {
                ObsidianSourceSettingsView(source: obsidianSource, onSourcePage: true)
            }
        }
    }

    @ViewBuilder
    private var audioHealthNoteView: some View {
        if appState.isRecording, !appState.isPaused, let note = appState.capture.audioHealthNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AXID.Menubar.audioHealthNote)
        }
    }

    /// What the terminal page says beyond its state word: a move in progress or refused.
    private var terminalPageNotes: [String] {
        if let refusal = appState.terminalMoveRefusal { return [refusal] }
        switch appState.terminalTakeoverStore?.load() {
        case .unusable(let url):
            return [UICopy.Terminal.unreadableRecord(url.path)]
        case .present(let record):
            return UICopy.Terminal.moveLine(record)
        default:
            return []
        }
    }

    private func pageAppeared(_ source: DeckSource) {
        switch source {
        case .audio:
            appState.markSettingsTabVisited(.microphones)
            appState.markSettingsTabVisited(.permissions)
            appState.refreshMicrophoneAuthorization()
            appState.syncMicrophonePriorityList()
            refreshMicrophoneEmptyState()
        case .screen:
            appState.markSettingsTabVisited(.privacy)
            appState.markSettingsTabVisited(.permissions)
            privateWindowAnnouncements.reset(to: privateWindowAccessibilityState)
            refreshSetupProbes()
        case .terminal, .browsers, .obsidian:
            appState.markSettingsTabVisited(.sources)
        }
    }

    private func pageDisappeared(_ source: DeckSource) {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        if source == .browsers { appState.browserRepair.viewGeneration += 1 }
#endif
    }
}

/// `so far` and `last taken in`, read from the on-device record every 30 seconds while shown.
/// Both rows are absent when the record can't be read.
struct SourceTotalRows: View {
    let appState: AppState
    let source: DeckSource

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let facts = sourceTotalFacts(appState.sourceTotalsView, source: source, now: context.date) {
                VStack(spacing: 6) {
                    factRow("so far", facts.soFar)
                    if let last = facts.lastTakenIn {
                        factRow("last taken in", last)
                    }
                }
                .font(.callout)
            }
        }
    }
}

private func factRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(label).foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(value).multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
}
