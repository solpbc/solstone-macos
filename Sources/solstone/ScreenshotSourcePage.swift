// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SwiftUI

extension SettingsView {
    @ViewBuilder
    func screenshotPage() -> some View {
        let tile = deriveDeckTile(.screenshots, appState.deckInputs)
        let source = appState.screenshotSource
        // A live source publishes the snapshot. The render harness has none, and the deck input
        // is that same snapshot, so the page draws it.
        let snapshot = source?.snapshot ?? appState.deckInputs.screenshot
        VStack(alignment: .leading, spacing: 16) {
            paneHeader(DeckSource.screenshots.label, systemImage: DeckSource.screenshots.systemImage)
            screenshotVerdict(tile)
            if let notice = snapshot.pageNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(tile.state == .needsAttention ? DeckStyle.attentionInk : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AXID.Settings.Sources.screenshotsProgress)
            }
            screenshotAction(snapshot, source: source)
            Text(snapshot.takesIn)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let leaves = snapshot.leavesAlone {
                Text(leaves)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.showChooser {
                screenshotChooser(snapshot, source: source)
            }
            SourceTotalRows(appState: appState, source: .screenshots)
            screenshotFacts(snapshot)
            if let refused = snapshot.refusedLine {
                Text(refused)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Sources.screenshotsRefused)
            }
            if let unreadable = snapshot.unreadableLine {
                VStack(alignment: .leading, spacing: 8) {
                    Text(unreadable)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(ScreenshotCopy.tryAgain) {
                        guard let source else { return }
                        Task { await source.retryUnreadable() }
                    }
                    .accessibilityIdentifier(AXID.Settings.Sources.screenshotsRetry)
                }
                .accessibilityIdentifier(AXID.Settings.Sources.screenshotsUnreadable)
            }
            DisclosureGroup(ScreenshotCopy.moreAboutThis) {
                Text(ScreenshotCopy.clipboard)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier(AXID.Settings.Sources.screenshotsDetail)
            Button(ScreenshotCopy.chooseFolder) { chooseScreenshotFolder(source) }
                .accessibilityIdentifier(AXID.Settings.Sources.screenshotsChooseFolder)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.page(.screenshots))
        .onAppear { appState.markSettingsTabVisited(.sources) }
    }

    private func screenshotVerdict(_ tile: DeckTile) -> some View {
        HStack(spacing: 8) {
            DeckStateLine(state: tile.state)
            Spacer()
            if let on = tile.switchOn {
                Toggle(tile.source.label, isOn: Binding(get: { on }, set: { switchSource(.screenshots, on: $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(SetupChromeColor.solOrange)
                    .accessibilityLabel(tile.source.label)
                    .accessibilityValue(tile.state.word)
                    .accessibilityIdentifier(AXID.Deck.tileSwitch(.screenshots) + ".page")
            }
        }
    }

    @ViewBuilder
    private func screenshotAction(_ snapshot: ScreenshotSnapshot, source: ScreenshotSource?) -> some View {
        switch snapshot.action {
        case .allowScreenshotFolder:
            Button(ScreenshotCopy.allow) { Task { await source?.allow() } }
                .accessibilityIdentifier(AXID.Settings.Sources.screenshotsAllow)
        case .openScreenshotSettings:
            Button(ScreenshotCopy.openSystemSettings) { ScreenshotMac.openFilesSettings() }
                .accessibilityIdentifier(AXID.Settings.Sources.screenshotsOpenSettings)
        case .retryScreenshotCount:
            Button(ScreenshotCopy.tryAgain) { Task { await source?.retryCount() } }
                .accessibilityIdentifier(AXID.Settings.Sources.screenshotsRetry)
        case .resumeIntake:
            Button(ScreenshotCopy.resume) { appState.pauseManager.resume() }
                .accessibilityIdentifier(AXID.Settings.Sources.screenshotsResume)
        default:
            EmptyView()
        }
    }

    private func screenshotChooser(_ snapshot: ScreenshotSnapshot, source: ScreenshotSource?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ScreenshotCopy.fromBeforeToday)
                .font(.callout)
            Picker(ScreenshotCopy.fromBeforeToday, selection: Binding(
                get: { snapshot.span },
                set: { span in Task { await source?.select(span: span) } }
            )) {
                ForEach(ScreenshotSpan.allCases, id: \.self) { span in
                    Text(span.label).tag(span)
                }
            }
            .pickerStyle(.radioGroup)
            .tint(SetupChromeColor.solOrange)
            .labelsHidden()
            .accessibilityIdentifier(AXID.Settings.Sources.screenshotsSpan)
            Text(ScreenshotCopy.seeTheCount)
                .font(.caption)
                .foregroundStyle(.secondary)
            if snapshot.showReturnNote {
                Text(ScreenshotCopy.notBroughtAgain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(snapshot.confirmTitle) { Task { await source?.confirm() } }
                .disabled(!snapshot.confirmEnabled)
                .accessibilityIdentifier(AXID.Settings.Sources.screenshotsConfirm)
        }
    }

    @ViewBuilder
    private func screenshotFacts(_ snapshot: ScreenshotSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ScreenshotCopy.staysIfDeleted)
            Text(ScreenshotCopy.staysWhenPaused)
            Text(ScreenshotCopy.onlyWhatWeCanTell)
            if let path = snapshot.folderPath {
                factLine(ScreenshotCopy.folderLabel, path)
                    .accessibilityIdentifier(AXID.Settings.Sources.screenshotsFolder)
            }
            if let checked = snapshot.lastChecked {
                factLine(ScreenshotCopy.lastChecked, relativeWords(checked, now: Date()))
                    .accessibilityIdentifier(AXID.Settings.Sources.screenshotsLastChecked)
            }
            if snapshot.waiting > 0 {
                factLine(ScreenshotCopy.waitingLabel, String(snapshot.waiting))
                    .accessibilityIdentifier(AXID.Settings.Sources.screenshotsWaiting)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func factLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        // One element for VoiceOver, read as "folder, /Users/…", as the totals rows are.
        .accessibilityElement(children: .combine)
    }

    private func chooseScreenshotFolder(_ source: ScreenshotSource?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = ScreenshotCopy.chooseFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = ScreenshotMac.folder(url)
        Task { await source?.choose(folder) }
    }
}
