// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SwiftUI

extension SettingsView {
    @ViewBuilder
    func foldersPage() -> some View {
        FolderSourcePaneView(
            appState: appState,
            header: { title in AnyView(paneHeader(title, systemImage: DeckSource.folders.systemImage)) }
        )
        .tint(SetupChromeColor.solOrange)
        .groupBoxStyle(PageGroupBoxStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Deck.page(.folders))
        .onAppear {
            appState.markSettingsTabVisited(.sources)
            Task { await appState.folderSource?.refreshFacets() }
        }
    }
}

private enum FolderPickNotice: Equatable {
    case alreadyAdded(id: String, name: String)
    case overlap(path: String, name: String, overlap: FolderOverlapInfo)
    case refusedLocal
    case refusedStorageProvider
}

private struct FolderSourcePaneView: View {
    let appState: AppState
    let header: (String) -> AnyView

    @State private var selectedFolderID: String?
    @State private var pickNotice: FolderPickNotice?
    @State private var removingFolder: FolderSummary?
    @Environment(\.colorScheme) private var scheme

    private var snapshot: FoldersSnapshot {
        appState.folderSource?.snapshot ?? appState.deckInputs.folders
    }

    private var selectedFolder: FolderSummary? {
        guard let selectedFolderID else { return nil }
        return snapshot.folders.first { $0.id == selectedFolderID }
    }

    var body: some View {
        Group {
            if let folder = selectedFolder {
                folderDetailView(folder)
            } else {
                folderListView
            }
        }
        .confirmationDialog(
            removingFolder.map { FolderSourceCopy.removeHeading($0.name) } ?? "",
            isPresented: Binding(
                get: { removingFolder != nil },
                set: { if !$0 { removingFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let folder = removingFolder {
                Button(FolderSourceCopy.remove, role: .destructive) {
                    let targetID = folder.id
                    removingFolder = nil
                    if selectedFolderID == targetID { selectedFolderID = nil }
                    Task { await appState.folderSource?.removeFolder(id: targetID) }
                }
                Button(FolderSourceCopy.cancel, role: .cancel) {
                    removingFolder = nil
                }
            }
        } message: {
            if let folder = removingFolder {
                Text(FolderSourceCopy.removeBody(folder.name))
            }
        }
    }

    // MARK: - Level 1: folders list

    private var folderListView: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(DeckSource.folders.label)

            if snapshot.folders.isEmpty {
                DeckStateLine(state: .readyToSetUp)
                Text(FolderSourceCopy.intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(FolderSourceCopy.chooseFolder) {
                    pickNewFolder()
                }
                .buttonStyle(.borderedProminent)
                .tint(SetupChromeColor.solOrange)
                .accessibilityIdentifier(AXID.Settings.Sources.foldersAdd)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.folders) { folder in
                        folderListRow(folder)
                    }
                }
                .accessibilityIdentifier(AXID.Settings.Sources.foldersList)

                Button(FolderSourceCopy.addFolder) {
                    pickNewFolder()
                }
                .accessibilityIdentifier(AXID.Settings.Sources.foldersAdd)

                SourceTotalRows(appState: appState, source: .folders)
            }

            if let pickNotice {
                pickNoticeCard(pickNotice)
            }

            DisclosureGroup(FolderSourceCopy.moreAboutThis) {
                Text(FolderSourceCopy.icloudNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .accessibilityIdentifier(AXID.Settings.Sources.foldersDetail)
        }
    }

    private func folderListRow(_ folder: FolderSummary) -> some View {
        Button {
            pickNotice = nil
            selectedFolderID = folder.id
            if folder.mode == .settingUp || folder.widening {
                Task {
                    await appState.folderSource?.refreshFacets()
                    await appState.folderSource?.refreshPreview(id: folder.id)
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(folder.name)
                            .font(DeckStyle.name(14))
                            .foregroundStyle(SetupChromeColor.ink(for: scheme))
                            .lineLimit(1)
                        if let facet = facetTitle(for: folder.facet) {
                            Text(facet)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(folder.displayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    DeckStateLine(state: folder.state)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(folder.name)
        .accessibilityValue(folder.state.word)
    }

    @ViewBuilder
    private func pickNoticeCard(_ notice: FolderPickNotice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch notice {
            case .alreadyAdded(let id, let name):
                Text(FolderSourceCopy.alreadyAdded(name))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button(FolderSourceCopy.openFolder(name)) {
                    pickNotice = nil
                    selectedFolderID = id
                }

            case .overlap(let path, _, let overlap):
                Text(FolderSourceCopy.overlapHeading(overlap.displayTarget))
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(FolderSourceCopy.overlapBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(FolderSourceCopy.overlapChoose) {
                        pickNotice = nil
                        pickNewFolder()
                    }
                    Button(FolderSourceCopy.overlapOverride) {
                        pickNotice = nil
                        let url = URL(fileURLWithPath: path, isDirectory: true)
                        Task { await addPickedFolder(url: url, allowOverlap: true) }
                    }
                    .accessibilityIdentifier(AXID.Settings.Sources.foldersOverlapOverride)
                }

            case .refusedLocal:
                Text(FolderSourceCopy.refusedLocal)
                    .font(.callout)
                    .foregroundStyle(DeckStyle.attentionInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button(FolderSourceCopy.overlapChoose) {
                    pickNotice = nil
                    pickNewFolder()
                }

            case .refusedStorageProvider:
                Text(FolderSourceCopy.refusedStorage)
                    .font(.callout)
                    .foregroundStyle(DeckStyle.attentionInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button(FolderSourceCopy.overlapChoose) {
                    pickNotice = nil
                    pickNewFolder()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .accessibilityIdentifier(AXID.Settings.Sources.foldersOverlapNotice)
    }

    // MARK: - Level 2: single folder detail / setup

    private func folderDetailView(_ folder: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                selectedFolderID = nil
            } label: {
                Text("‹ \(FolderSourceCopy.label)")
                    .font(.system(size: 13))
                    .foregroundStyle(SetupChromeColor.solOrange)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AXID.Settings.Sources.foldersBack)

            header(folder.name)
            folderVerdictRow(folder)
            folderReasonBlock(folder)

            Text(FolderSourceCopy.oneIntro(folder.name))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            kindsSection(folder)
            facetSection(folder)

            if folder.mode == .settingUp || folder.widening {
                spanAndPreviewSection(folder)
            }

            if folder.mode == .on && !folder.widening && folder.attention == nil {
                Button(FolderSourceCopy.bringInOlder) {
                    Task { await appState.folderSource?.startWidening(id: folder.id) }
                }
                .accessibilityIdentifier(AXID.Settings.Sources.foldersBringInOlder)
            }

            folderFactsSection(folder)

            DisclosureGroup(FolderSourceCopy.moreAboutThis) {
                Text(FolderSourceCopy.icloudNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .accessibilityIdentifier(AXID.Settings.Sources.foldersDetail)

            Divider()

            Button(FolderSourceCopy.remove, role: .destructive) {
                removingFolder = folder
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DeckStyle.attentionInk)
            .accessibilityIdentifier(AXID.Settings.Sources.foldersRemove)
        }
    }

    private func folderVerdictRow(_ folder: FolderSummary) -> some View {
        HStack(spacing: 8) {
            DeckStateLine(state: folder.state)
            Spacer()
            if folder.attention == nil {
                if folder.pausedByMac {
                    Button(FolderSourceCopy.resume) {
                        appState.pauseManager.resume()
                    }
                    .accessibilityIdentifier(AXID.Settings.Sources.foldersResume)
                } else if folder.mode == .on {
                    Button(FolderSourceCopy.pause) {
                        Task { await appState.folderSource?.pauseFolder(id: folder.id) }
                    }
                    .accessibilityIdentifier(AXID.Settings.Sources.foldersPause)
                } else if folder.mode == .paused {
                    Button(FolderSourceCopy.resume) {
                        Task { await appState.folderSource?.resumeFolder(id: folder.id) }
                    }
                    .accessibilityIdentifier(AXID.Settings.Sources.foldersResume)
                }
            }
            if folder.mode != .settingUp {
                let isOn = folder.mode != .off
                Toggle(folder.name, isOn: Binding(
                    get: { isOn },
                    set: { next in
                        Task {
                            if next {
                                await appState.folderSource?.turnOnFolder(id: folder.id)
                            } else {
                                await appState.folderSource?.turnOffFolder(id: folder.id)
                            }
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(SetupChromeColor.solOrange)
                .accessibilityLabel(folder.name)
                .accessibilityValue(folder.state.word)
                .accessibilityIdentifier(AXID.Settings.Sources.foldersSwitch)
            }
        }
    }

    @ViewBuilder
    private func folderReasonBlock(_ folder: FolderSummary) -> some View {
        if let attention = folder.attention {
            VStack(alignment: .leading, spacing: 8) {
                switch attention {
                case .accessOff:
                    Text(FolderSourceCopy.accessOff(folder.name))
                        .font(.callout)
                        .foregroundStyle(DeckStyle.attentionInk)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(FolderSourceCopy.openSystemSettings) {
                            FolderSourceMacUI.openFilesSettings()
                        }
                        .accessibilityIdentifier(AXID.Settings.Sources.foldersOpenSettings)
                        Button(FolderSourceCopy.chooseFolder) {
                            repointFolder(folder)
                        }
                    }
                case .missing:
                    Text(FolderSourceCopy.missing(folder.name))
                        .font(.callout)
                        .foregroundStyle(DeckStyle.attentionInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(FolderSourceCopy.chooseFolder) {
                        repointFolder(folder)
                    }
                case .unreadable:
                    Text(FolderSourceCopy.unreadable(folder.name))
                        .font(.callout)
                        .foregroundStyle(DeckStyle.attentionInk)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(FolderSourceCopy.chooseFolder) {
                            repointFolder(folder)
                        }
                        Button(FolderSourceCopy.tryAgain) {
                            Task { await appState.folderSource?.retryScan() }
                        }
                    }
                }
            }
        } else if folder.mode == .off {
            Text(FolderSourceCopy.offReason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if folder.pausedByMac {
            Text(FolderSourceCopy.pausedMac)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if folder.mode == .paused {
            Text(FolderSourceCopy.pausedFolder)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if folder.mode == .on && !snapshot.paired {
            Text(FolderSourceCopy.unpaired)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if folder.mode == .on && snapshot.journalNeedsUpdate {
            Text(FolderSourceCopy.journalUpdate)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if folder.isBackfilling, let total = folder.backfillTotal {
            VStack(alignment: .leading, spacing: 4) {
                Text(FolderSourceCopy.pageProgress(done: folder.backfillDone, total: total))
                    .font(.callout)
                    .accessibilityIdentifier(AXID.Settings.Sources.foldersProgress)
                Text(FolderSourceCopy.backfillStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func kindsSection(_ folder: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FolderSourceCopy.whatComesIn)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            kindToggleRow(
                title: FolderSourceCopy.kindNotes,
                detail: FolderSourceCopy.kindNotesDesc,
                isOn: folder.kinds.notes
            ) { val in updateKind(folder) { $0.notes = val } }

            kindToggleRow(
                title: FolderSourceCopy.kindDocuments,
                detail: FolderSourceCopy.kindDocumentsDesc,
                isOn: folder.kinds.documents
            ) { val in updateKind(folder) { $0.documents = val } }

            kindToggleRow(
                title: FolderSourceCopy.kindTranscripts,
                detail: FolderSourceCopy.kindTranscriptsDesc,
                isOn: folder.kinds.transcripts
            ) { val in updateKind(folder) { $0.transcripts = val } }

            kindToggleRow(
                title: FolderSourceCopy.kindScreenshots,
                detail: FolderSourceCopy.kindScreenshotsDesc,
                isOn: folder.kinds.screenshots
            ) { val in updateKind(folder) { $0.screenshots = val } }

            kindToggleRow(
                title: FolderSourceCopy.kindPhotos,
                detail: FolderSourceCopy.kindPhotosDesc,
                isOn: folder.kinds.photos
            ) { val in updateKind(folder) { $0.photos = val } }

            kindToggleRow(
                title: FolderSourceCopy.kindOther,
                detail: FolderSourceCopy.kindOtherDesc,
                isOn: folder.kinds.other
            ) { val in updateKind(folder) { $0.other = val } }

            if !folder.kinds.anySelected {
                Text(FolderSourceCopy.chooseAtLeastOne)
                    .font(.caption)
                    .foregroundStyle(DeckStyle.attentionInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else if folder.mode != .settingUp {
                Text(FolderSourceCopy.kindsGoingForward)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(AXID.Settings.Sources.foldersKinds)
    }

    private func kindToggleRow(title: String, detail: String, isOn: Bool, onChange: @escaping @Sendable @MainActor (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: onChange)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .tint(SetupChromeColor.solOrange)
    }

    private func facetSection(_ folder: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(FolderSourceCopy.facetHeading)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            if snapshot.facetsState == .ready || folder.facet != nil {
                Picker(FolderSourceCopy.facetHeading, selection: Binding(
                    get: { folder.facet ?? "" },
                    set: { next in
                        Task { await appState.folderSource?.setFacet(id: folder.id, facet: next.isEmpty ? nil : next) }
                    }
                )) {
                    Text(FolderSourceCopy.facetNone).tag("")
                    ForEach(snapshot.facets) { facet in
                        Text(facet.title).tag(facet.name)
                    }
                    if let current = folder.facet, !snapshot.facets.contains(where: { $0.name == current }) {
                        Text(current).tag(current)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier(AXID.Settings.Sources.foldersFacet)
            }

            facetHelperLine(folder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func facetHelperLine(_ folder: FolderSummary) -> some View {
        if snapshot.facetsState == .unpaired {
            Text(FolderSourceCopy.facetUnpaired)
        } else if snapshot.facetsState == .needsJournalUpdate {
            Text(FolderSourceCopy.journalUpdate)
        } else if snapshot.facetsState == .offline {
            Text(FolderSourceCopy.facetOffline)
        } else if let title = facetTitle(for: folder.facet) {
            Text(folder.mode == .settingUp
                ? FolderSourceCopy.facetHelpSetup(title)
                : FolderSourceCopy.facetHelpActive(title))
        } else {
            Text(FolderSourceCopy.facetHelpNone)
        }
    }

    private func spanAndPreviewSection(_ folder: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FolderSourceCopy.fromBeforeToday)
                .font(.callout)

            Picker(FolderSourceCopy.fromBeforeToday, selection: Binding(
                get: { folder.span },
                set: { next in Task { await appState.folderSource?.selectSpan(id: folder.id, span: next) } }
            )) {
                ForEach(FolderSpan.allCases, id: \.self) { span in
                    Text(span.label).tag(span)
                }
            }
            .pickerStyle(.radioGroup)
            .tint(SetupChromeColor.solOrange)
            .labelsHidden()
            .accessibilityIdentifier(AXID.Settings.Sources.foldersSpan)

            previewCard(folder)

            if folder.mode == .settingUp && !folder.returning {
                Text(FolderSourceCopy.nothingUntilConfirm)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if folder.returning || folder.widening {
                Text(FolderSourceCopy.noRepeat)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(FolderSourceCopy.confirmTitle(span: folder.span, count: folder.preview.totalItems)) {
                    Task { await appState.folderSource?.confirmFolder(id: folder.id) }
                }
                .buttonStyle(.borderedProminent)
                .tint(SetupChromeColor.solOrange)
                .disabled(!folder.kinds.anySelected || folder.preview.scanning || folder.preview.scanFailed)
                .accessibilityIdentifier(AXID.Settings.Sources.foldersConfirm)

                if folder.widening {
                    Button(FolderSourceCopy.cancel) {
                        Task { await appState.folderSource?.cancelWidening(id: folder.id) }
                    }
                }
            }
        }
    }

    private func previewCard(_ folder: FolderSummary) -> some View {
        let preview = folder.preview
        return VStack(alignment: .leading, spacing: 6) {
            Text(FolderSourceCopy.previewHeading)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            if preview.scanning {
                Text(FolderSourceCopy.checkingFolder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if preview.scanFailed {
                Text(FolderSourceCopy.previewFailed)
                    .font(.callout)
                    .foregroundStyle(DeckStyle.attentionInk)
                Button(FolderSourceCopy.tryAgain) {
                    Task { await appState.folderSource?.refreshPreview(id: folder.id) }
                }
            } else {
                Text(previewHeaderLine(preview))
                    .font(.callout.weight(.medium))

                if let breakdown = FolderSourceCopy.previewBreakdown(
                    contentItems: preview.contentItems,
                    contentBytes: preview.contentBytes,
                    metadataOnlyItems: preview.metadataOnlyItems
                ) {
                    Text(breakdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if folder.span != .fromToday && preview.totalItems > 0 {
                    estimateBlock(preview)
                }

                Text(FolderSourceCopy.scopeNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .accessibilityIdentifier(AXID.Settings.Sources.foldersPreview)
    }

    @ViewBuilder
    private func estimateBlock(_ preview: FolderPreviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch preview.estimateState {
            case .ready:
                if let est = preview.estimate {
                    Text(FolderSourceCopy.estHeading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(FolderSourceCopy.estimateLine(segments: est.segments, days: est.days, thoughts: est.thoughts))
                        .font(.callout)
                    Text(FolderSourceCopy.estGloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .loading:
                Text(FolderSourceCopy.checkingFolder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unpaired:
                Text(FolderSourceCopy.estUnpaired)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .needsJournalUpdate:
                Text(FolderSourceCopy.journalUpdate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .offline:
                Text(FolderSourceCopy.estOffline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
        }
        .padding(.top, 4)
    }

    private func folderFactsSection(_ folder: FolderSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(FolderSourceCopy.stays)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(folder.kinds.other ? FolderSourceCopy.otherOn : FolderSourceCopy.otherOff)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let overlap = folder.overlap {
                Text(FolderSourceCopy.overlapFact(overlap.displayTarget))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            folderFactRow(FolderSourceCopy.folderLabel, folder.displayPath)
            HStack {
                Spacer(minLength: 0)
                Button(FolderSourceCopy.chooseFolder) { repointFolder(folder) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(SetupChromeColor.solOrange)
            }

            if folder.deliveredTotal > 0 {
                folderFactRow(FolderSourceCopy.soFar, FolderSourceCopy.itemCount(folder.deliveredTotal))
            }
            if let lastAdded = folder.lastAddedAt {
                folderFactRow(FolderSourceCopy.lastTakenIn, relativeWords(lastAdded, now: Date()))
            }
            if let checked = folder.lastCheckedAt {
                folderFactRow(FolderSourceCopy.lastChecked, relativeWords(checked, now: Date()))
            }
            if folder.waiting > 0 {
                folderFactRow(FolderSourceCopy.waitingLabel, String(folder.waiting))
            }
            if let fallback = FolderSourceCopy.fallback(folder.fallbackToDetails) {
                Text(fallback)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cantRead = FolderSourceCopy.cantRead(folder.cantRead) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(cantRead)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(FolderSourceCopy.tryAgain) {
                        Task { await appState.folderSource?.retryScan() }
                    }
                }
            }
        }
        .font(.callout)
    }

    private func folderFactRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Helpers

    private func previewHeaderLine(_ preview: FolderPreviewSummary) -> String {
        guard preview.totalItems > 0 else { return FolderSourceCopy.previewZero }
        if let startMs = preview.earliestMs, let endMs = preview.latestMs {
            let startDate = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
            let endDate = Date(timeIntervalSince1970: Double(endMs) / 1000.0)
            let startText = shortMonthDay(startDate)
            let endText = shortMonthDay(endDate)
            if startText != endText {
                return FolderSourceCopy.previewSpan(count: preview.totalItems, start: startText, end: endText)
            }
        }
        return FolderSourceCopy.previewCount(preview.totalItems)
    }

    private func shortMonthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: MacStrings.language)
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date).lowercased(with: formatter.locale)
    }

    private func facetTitle(for slug: String?) -> String? {
        guard let slug, !slug.isEmpty else { return nil }
        return snapshot.facets.first(where: { $0.name == slug })?.title ?? slug
    }

    private func updateKind(_ folder: FolderSummary, mutate: (inout FolderKinds) -> Void) {
        var next = folder.kinds
        mutate(&next)
        Task { await appState.folderSource?.setKinds(id: folder.id, kinds: next) }
    }

    private func pickNewFolder() {
        guard let url = FolderSourceMacUI.chooseFolder() else { return }
        Task { await addPickedFolder(url: url, allowOverlap: false) }
    }

    private func addPickedFolder(url: URL, allowOverlap: Bool) async {
        guard let source = appState.folderSource else { return }
        let outcome = await source.pickFolder(url: url, allowOverlap: allowOverlap)
        switch outcome {
        case .added(let id):
            pickNotice = nil
            selectedFolderID = id
        case .alreadyAdded(let id, let name):
            pickNotice = .alreadyAdded(id: id, name: name)
        case .needsOverlapConfirmation(let path, let name, let overlap):
            pickNotice = .overlap(path: path, name: name, overlap: overlap)
        case .refusedLocal:
            pickNotice = .refusedLocal
        case .refusedStorageProvider:
            pickNotice = .refusedStorageProvider
        }
    }

    private func repointFolder(_ folder: FolderSummary) {
        guard let url = FolderSourceMacUI.chooseFolder() else { return }
        Task { _ = await appState.folderSource?.repointFolder(id: folder.id, url: url) }
    }
}
