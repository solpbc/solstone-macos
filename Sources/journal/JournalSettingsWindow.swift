// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import SolstoneCore
import SwiftUI
import UpdateKit

struct JournalSettingsWindow: View {
    @Bindable var model: JournalWindowModel
    @Bindable var updateController: UpdateController
    var openURL: (URL) -> Void

    init(
        model: JournalWindowModel,
        updateController: UpdateController,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.model = model
        self.updateController = updateController
        self.openURL = openURL
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $model.selectedPane) {
                ForEach(JournalPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                        .accessibilityIdentifier(AXID.Journal.Sidebar.tab(pane))
                        .overlay {
                            AXStateCompanion(
                                id: AXID.Journal.Sidebar.tabState(pane),
                                value: (model.selectedPane == pane ? JournalSidebarTabState.selected : .unselected).axToken
                            )
                        }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                detailContent
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear {
            model.handlePaneOpen(model.selectedPane)
        }
        .onChange(of: model.selectedPane) { _, newValue in
            model.handlePaneOpen(newValue)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.selectedPane {
        case .home:
            homePane
        case .journal:
            journalPane
        case .runState:
            runStatePane
        case .backup:
            backupPane
        case .startup:
            startupPane
        case .updates:
            UpdatesTabView(controller: updateController, copy: UpdatesCopy(provider: .journal))
        }
    }

    private var homePane: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("your journal, at a glance")
                .font(.title2.weight(.semibold))

            if let mark = model.identityMark {
                JournalMarkView(mark: mark, isConfirmed: true)
                    .accessibilityIdentifier(AXID.Journal.Home.markCard)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(model.displayName)
                    .font(.title3.weight(.medium))
                AXStateCompanion(id: AXID.Journal.Home.nameState, value: model.displayName)

                statusLine(model.runDisplay.label, systemImage: "circle.fill")
                AXStateCompanion(id: AXID.Journal.Home.runDisplayGlanceState, value: model.runDisplay.axToken)
            }

            if let message = model.unconfiguredMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                AXStateCompanion(id: AXID.Journal.Home.unconfiguredMessageState, value: message)
            } else {
                Button {
                    openURL(URL(string: "http://127.0.0.1:5015/")!)
                } label: {
                    Label("open your journal", systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier(AXID.Journal.Home.openJournal)
            }
        }
    }

    private var journalPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("journal")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("name")
                    .font(.headline)
                HStack(spacing: 8) {
                    TextField("name", text: $model.draftJournalName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AXID.Journal.Pane.nameField)
                        .onSubmit {
                            Task { await model.saveDraftJournalName() }
                        }
                    Button {
                        Task { await model.saveDraftJournalName() }
                    } label: {
                        Label("save", systemImage: "checkmark")
                    }
                    .disabled(model.isSavingName)
                    .accessibilityIdentifier(AXID.Journal.Pane.nameSave)
                }
                if let error = model.nameError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            infoRow("location", value: model.journalRootPath)
            AXStateCompanion(id: AXID.Journal.Pane.locationPathState, value: model.journalRootPath)

            infoRow("disk used", value: model.diskUsageValue)
            AXStateCompanion(
                id: AXID.Journal.Pane.diskUsageState,
                value: String(model.diskUsageBytes ?? 0)
            )
        }
    }

    private var runStatePane: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("run state")
                .font(.title2.weight(.semibold))

            statusLine(model.runDisplay.label, systemImage: "circle.fill")
            AXStateCompanion(id: AXID.Journal.RunState.displayState, value: model.runDisplay.axToken)

            if model.runDisplay == .blocked, let blockedReason = model.supervisor.blockedReason {
                Text(blockedReason)
                    .foregroundStyle(.secondary)
                AXStateCompanion(id: AXID.Journal.RunState.blockedReasonState, value: blockedReason)
            } else {
                AXStateCompanion(id: AXID.Journal.RunState.blockedReasonState, value: "")
            }

            HStack(spacing: 8) {
                Button {
                    model.startJournal()
                } label: {
                    Label("start", systemImage: "play.fill")
                }
                .accessibilityIdentifier(AXID.Journal.RunState.start)

                Button {
                    model.stopJournal()
                } label: {
                    Label("stop", systemImage: "stop.fill")
                }
                .accessibilityIdentifier(AXID.Journal.RunState.stop)

                Button {
                    model.restartJournal()
                } label: {
                    Label("restart", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(AXID.Journal.RunState.restart)
            }

            infoRow("health", value: model.healthDisplay.label)
            AXStateCompanion(id: AXID.Journal.RunState.healthState, value: model.healthDisplay.axToken)

            infoRow("runtime version", value: model.runtimeVersion)
            AXStateCompanion(id: AXID.Journal.RunState.runtimeVersionState, value: model.runtimeVersion)

            infoRow("app version", value: model.appVersion)
            AXStateCompanion(id: AXID.Journal.RunState.appVersionState, value: model.appVersion)
        }
    }

    private var backupPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("backup")
                .font(.title2.weight(.semibold))
            Text("backup keeps your journal safe. set it up from your journal.")
                .foregroundStyle(.secondary)
            AXStateCompanion(
                id: AXID.Journal.Backup.messageState,
                value: "backup keeps your journal safe. set it up from your journal."
            )

            Button {
                openURL(URL(string: "http://127.0.0.1:5015/app/backup")!)
            } label: {
                Label("open backup", systemImage: "arrow.up.right.square")
            }
            .accessibilityIdentifier(AXID.Journal.Backup.openBackup)
        }
    }

    private var startupPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("startup")
                .font(.title2.weight(.semibold))
            Toggle(
                "launch the journal when you log in",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLoginEnabled($0) }
                )
            )
            .accessibilityIdentifier(AXID.Journal.Startup.launchAtLogin)
            AXStateCompanion(
                id: AXID.Journal.Startup.launchAtLoginState,
                value: (model.launchAtLoginEnabled ? JournalEnabledState.enabled : .disabled).axToken
            )
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.headline)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func statusLine(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 8))
        }
    }
}
