// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
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
        case .finishInBrowser:
            finishInBrowserView
        }
    }

    private var nameLocationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(JournalFirstRunCopy.nameLocationTitle)
                .font(.title2.weight(.semibold))

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .center)
    }

    private var finishInBrowserView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(JournalFirstRunCopy.finishInBrowserTitle)
                .font(.title2.weight(.semibold))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(JournalFirstRunCopy.finishInBrowserLine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.reopenInBrowser()
            } label: {
                Label(JournalFirstRunCopy.reopenInBrowserButton, systemImage: "safari")
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(AXID.Journal.Ritual.browserReopen)
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
