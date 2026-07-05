// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import SolstoneCore
import SwiftUI

struct JournalFirstRunView: View {
    @Bindable var model: JournalFirstRunModel

    var body: some View {
        Group {
            switch model.route {
            case .deciding:
                decidingView
            case .ritual(let step):
                ritualView(step)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AXID.Journal.Ritual.root)
                    .overlay {
                        AXStateCompanion(id: AXID.Journal.Ritual.routeState, value: model.route.axToken)
                    }
            case .adopting:
                adoptView
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AXID.Journal.Adopt.root)
            case .home:
                EmptyView()
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var decidingView: some View {
        VStack {
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            AXStateCompanion(id: AXID.Journal.Ritual.routeState, value: model.route.axToken)
        }
    }

    @ViewBuilder
    private func ritualView(_ step: JournalFirstRunStep) -> some View {
        switch step {
        case .nameLocation:
            nameLocationView
        case .setupProgress:
            setupProgressView
        case .markReveal:
            markRevealView
        case .finalizing:
            finalizingView
        }
    }

    private var nameLocationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(JournalFirstRunCopy.nameLocationTitle)
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                Text(JournalFirstRunCopy.nameField)
                    .font(.headline)
                TextField(JournalFirstRunCopy.nameField, text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(AXID.Journal.Ritual.nameField)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(JournalFirstRunCopy.locationField)
                    .font(.headline)
                HStack(spacing: 8) {
                    TextField(
                        JournalFirstRunCopy.locationField,
                        text: Binding(
                            get: { model.journalRoot.path },
                            set: { model.journalRoot = URL(fileURLWithPath: $0, isDirectory: true) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(AXID.Journal.Ritual.locationField)

                    Button {
                        chooseJournalLocation()
                    } label: {
                        Label(JournalFirstRunCopy.chooseLocation, systemImage: "folder")
                    }
                    .accessibilityIdentifier(AXID.Journal.Ritual.locationChoose)
                }
            }

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                AXStateCompanion(id: AXID.Journal.Ritual.nameLocationErrorState, value: error)
            } else {
                AXStateCompanion(id: AXID.Journal.Ritual.nameLocationErrorState, value: "")
            }

            Button {
                Task { await model.continueFromNameLocation() }
            } label: {
                Label(JournalFirstRunCopy.continueButton, systemImage: "arrow.right")
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AXID.Journal.Ritual.nameLocationContinue)
        }
        .padding(32)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
    }

    private var setupProgressView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(JournalFirstRunCopy.setupTitle)
                .font(.title2.weight(.semibold))
            Text(JournalFirstRunCopy.setupSubtitle)
                .foregroundStyle(.secondary)

            ProgressView()
                .controlSize(.large)
                .accessibilityIdentifier(AXID.Journal.Ritual.setupProgress)

            Text(model.currentStep ?? JournalFirstRunCopy.setupTitle)
                .foregroundStyle(.secondary)
            AXStateCompanion(id: AXID.Journal.Ritual.setupStepState, value: model.currentStep ?? "")

            if !model.setupRenderedLog.isEmpty {
                ScrollView {
                    Text(model.setupRenderedLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            AXStateCompanion(id: AXID.Journal.Ritual.setupLogState, value: model.setupRenderedLog)

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                AXStateCompanion(id: AXID.Journal.Ritual.setupErrorState, value: error)
                Button {
                    Task { await model.runSetupThenStartSupervisor() }
                } label: {
                    Label(JournalFirstRunCopy.tryAgain, systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(AXID.Journal.Ritual.setupRetry)
            } else {
                AXStateCompanion(id: AXID.Journal.Ritual.setupErrorState, value: "")
            }
        }
        .padding(32)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
    }

    private var markRevealView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(JournalFirstRunCopy.markTitle)
                .font(.title2.weight(.semibold))
            Text(JournalFirstRunCopy.markRevealSubtitle)
                .foregroundStyle(.secondary)

            if let mark = model.currentMark {
                JournalMarkView(mark: mark, isConfirmed: model.markLocked)
                    .journalMarkPop(generation: model.markRenderGeneration)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AXID.Journal.Ritual.markCard)
            }

            Text(JournalFirstRunCopy.markRevealExplainer)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    Task { await model.regenerateMark() }
                } label: {
                    Label(JournalFirstRunCopy.tryAnotherButton, systemImage: "shuffle")
                }
                .disabled(model.isTryingAnotherMark || model.isLockingMark)
                .accessibilityIdentifier(AXID.Journal.Ritual.markTryAnother)

                Button {
                    Task { await model.lockCurrentMark() }
                } label: {
                    Label(JournalFirstRunCopy.lockButton, systemImage: "lock")
                }
                .disabled(model.currentMark == nil || model.isTryingAnotherMark || model.isLockingMark)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AXID.Journal.Ritual.markLock)
            }

            if model.isTryingAnotherMark {
                Text(JournalFirstRunCopy.tryAnotherLoading)
                    .foregroundStyle(.secondary)
            }
            AXStateCompanion(
                id: AXID.Journal.Ritual.markLoadingState,
                value: (model.isTryingAnotherMark ? JournalFirstRunBusyState.running : .idle).axToken
            )
            AXStateCompanion(id: AXID.Journal.Ritual.markLockedState, value: model.markState.axToken)

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                AXStateCompanion(id: AXID.Journal.Ritual.markErrorState, value: error)
            } else {
                AXStateCompanion(id: AXID.Journal.Ritual.markErrorState, value: "")
            }
        }
        .padding(32)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
    }

    private var finalizingView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(JournalFirstRunCopy.finishingTitle)
                .font(.title2.weight(.semibold))

            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(JournalFirstRunCopy.finishingLoading)
                    .foregroundStyle(.secondary)
            }
            AXStateCompanion(
                id: AXID.Journal.Ritual.finalizeProgressState,
                value: (model.isFinalizing ? JournalFirstRunBusyState.running : .idle).axToken
            )

            if !model.finalizeWarnings.isEmpty {
                Text(JournalFirstRunCopy.finishedWithNotes)
                    .font(.headline)
                ForEach(model.finalizeWarnings, id: \.self) { warning in
                    Text(warning)
                        .foregroundStyle(.secondary)
                }
            }
            AXStateCompanion(
                id: AXID.Journal.Ritual.finalizeWarningsState,
                value: model.finalizeWarnings.joined(separator: "\n")
            )

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                AXStateCompanion(id: AXID.Journal.Ritual.finalizeErrorState, value: error)
                Button {
                    Task { await model.finalizeAndLandHome() }
                } label: {
                    Label(JournalFirstRunCopy.tryAgain, systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(AXID.Journal.Ritual.finalizeRetry)
            } else {
                AXStateCompanion(id: AXID.Journal.Ritual.finalizeErrorState, value: "")
            }
        }
        .padding(32)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
    }

    private var adoptView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(JournalFirstRunCopy.adoptTitle)
                .font(.title2.weight(.semibold))

            if model.errorMessage == nil, model.adoptState != .landed {
                ProgressView()
                    .controlSize(.large)
            }

            Text(model.adoptMessage ?? JournalFirstRunCopy.adoptOpening)
                .foregroundStyle(.secondary)
            AXStateCompanion(id: AXID.Journal.Adopt.statusState, value: model.adoptState.axToken)
            AXStateCompanion(id: AXID.Journal.Adopt.messageState, value: model.adoptMessage ?? "")
            AXStateCompanion(id: AXID.Journal.Adopt.locationPathState, value: model.journalRoot.path)

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                AXStateCompanion(id: AXID.Journal.Adopt.errorState, value: error)
                Button {
                    Task { await model.adoptFromHandoff() }
                } label: {
                    Label(JournalFirstRunCopy.tryAgain, systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(AXID.Journal.Adopt.continueButton)
            } else {
                AXStateCompanion(id: AXID.Journal.Adopt.errorState, value: "")
            }
        }
        .padding(32)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
    }

    private func chooseJournalLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.journalRoot.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            model.journalRoot = url.standardizedFileURL
        }
    }
}
