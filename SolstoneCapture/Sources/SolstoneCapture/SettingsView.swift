// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCaptureCore
import SwiftUI

/// Display entry for microphone priority list
struct MicrophoneDisplayEntry: Identifiable {
    let id: String
    let uid: String
    let name: String
    let isConnected: Bool
    let isDisabled: Bool

    init(from entry: MicrophoneEntry, isConnected: Bool) {
        self.id = entry.uid
        self.uid = entry.uid
        self.name = entry.name
        self.isConnected = isConnected
        self.isDisabled = entry.isDisabled
    }
}

/// Settings window for configuring server upload
struct SettingsView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: TestResult = .none
    @State private var isTesting = false

    enum TestResult: Equatable {
        case none
        case success
        case failure(String)
    }

    // MARK: - Auto-saving Bindings

    private var serverURLBinding: Binding<String> {
        Binding(
            get: { appState.config.serverURL ?? "" },
            set: { newValue in
                var config = appState.config
                config.serverURL = newValue.isEmpty ? nil : newValue
                appState.updateConfig(config)
            }
        )
    }

    private var serverKeyBinding: Binding<String> {
        Binding(
            get: { appState.config.serverKey ?? "" },
            set: { newValue in
                var config = appState.config
                config.serverKey = newValue.isEmpty ? nil : newValue
                appState.updateConfig(config)
            }
        )
    }

    private var localRetentionBinding: Binding<Int> {
        Binding(
            get: { appState.config.localRetentionMB },
            set: { newValue in
                var config = appState.config
                config.localRetentionMB = newValue
                appState.updateConfig(config)
            }
        )
    }

    var body: some View {
        TabView {
            serverTab
                .tabItem { Label("Server", systemImage: "server.rack") }

            microphoneTab
                .tabItem { Label("Microphones", systemImage: "mic") }

            statusTab
                .tabItem { Label("Status", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(minWidth: 450, minHeight: 320)
        .onAppear {
            appState.syncMicrophonePriorityList()
        }
        .onExitCommand {
            dismiss()
        }
    }

    // MARK: - Server Tab

    private var serverTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Remote Server") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Server URL") {
                        TextField("https://solstone.example.com", text: serverURLBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("API Key") {
                        SecureField("Paste key from server", text: serverKeyBinding)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button("Test Connection") {
                            testConnection()
                        }
                        .disabled(!appState.config.isUploadConfigured || isTesting)

                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.5)
                        } else {
                            testResultIcon
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Local Storage") {
                LabeledContent("Retention Limit") {
                    Stepper("\(appState.config.localRetentionMB) MB", value: localRetentionBinding, in: 50...10000, step: 50)
                }
                .padding(.vertical, 4)
            }

            GroupBox("General") {
                Toggle("Start at Login", isOn: Binding(
                    get: { appState.isLoginItemEnabled },
                    set: { appState.setLoginItemEnabled($0) }
                ))
                .padding(.vertical, 4)
            }

            Spacer()
        }
    }

    // MARK: - Microphone Tab

    private var microphoneDisplayEntries: [MicrophoneDisplayEntry] {
        let connectedUIDs = Set(appState.audioDeviceMonitor.availableDevices.map { $0.uid })
        return appState.config.microphonePriority.map { entry in
            MicrophoneDisplayEntry(
                from: entry,
                isConnected: connectedUIDs.contains(entry.uid)
            )
        }
    }

    private var microphoneTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Microphone Priority") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Drag to reorder. Higher items are preferred for recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if microphoneDisplayEntries.isEmpty {
                        Text("No microphones detected")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        List {
                            ForEach(microphoneDisplayEntries) { entry in
                                MicrophoneRow(
                                    entry: entry,
                                    onDelete: { deleteMicrophone(uid: entry.uid) },
                                    onToggleDisabled: { toggleMicrophoneDisabled(uid: entry.uid) }
                                )
                            }
                            .onMove { from, to in
                                moveMicrophones(from: from, to: to)
                            }
                        }
                        .listStyle(.bordered)
                        .frame(minHeight: 120, maxHeight: 200)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
    }

    private func moveMicrophones(from: IndexSet, to: Int) {
        var newConfig = appState.config
        newConfig.reorderMicrophones(fromOffsets: from, toOffset: to)
        appState.updateConfig(newConfig)
    }

    private func deleteMicrophone(uid: String) {
        var newConfig = appState.config
        _ = newConfig.removeMicrophone(uid: uid)
        appState.updateConfig(newConfig)
    }

    private func toggleMicrophoneDisabled(uid: String) {
        var newConfig = appState.config
        newConfig.toggleMicrophoneDisabled(uid: uid)
        appState.updateConfig(newConfig)
    }

    // MARK: - Status Tab

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Recording") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("State") {
                        Text(appState.isRecording ? (appState.isPaused ? "Paused" : "Recording") : "Stopped")
                    }

                    if appState.isRecording && !appState.isPaused {
                        LabeledContent("Segment") {
                            Text("\(appState.segmentIndex + 1)")
                        }

                        LabeledContent("Time Remaining") {
                            let remaining = appState.segmentTimeRemaining
                            let mins = Int(remaining) / 60
                            let secs = Int(remaining) % 60
                            Text(String(format: "%d:%02d", mins, secs))
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Upload") {
                uploadStatusView
                    .padding(.vertical, 4)
            }

            Spacer()
        }
    }

    // MARK: - Upload Status

    @ViewBuilder
    private var uploadStatusView: some View {
        let status = appState.uploadService.status
        let pending = appState.uploadService.pendingCount

        HStack {
            statusIcon(for: status)
            Text(statusText(for: status))
            Spacer()
            if pending > 0 {
                Text("\(pending) pending")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusIcon(for status: UploadService.Status) -> some View {
        let (name, color): (String, Color) = switch status {
        case .notSynced:
            ("questionmark.circle", .gray)
        case .synced:
            ("checkmark.circle", .green)
        case .syncing:
            ("arrow.triangle.2.circlepath", .blue)
        case .uploading:
            ("arrow.up.circle", .blue)
        case .retrying:
            ("exclamationmark.triangle", .orange)
        case .offline:
            ("xmark.circle", .red)
        }

        return Image(systemName: name)
            .foregroundStyle(color)
    }

    private func statusText(for status: UploadService.Status) -> String {
        switch status {
        case .notSynced:
            return "Connecting..."
        case .synced:
            return "Synced"
        case .syncing(let checked, let total):
            return "Syncing: \(checked)/\(total)"
        case .uploading(let segment):
            return "Uploading: \(segment)"
        case .retrying(let segment, let attempts):
            return "Retrying \(segment) (attempt \(attempts))"
        case .offline(let error):
            return "Offline: \(error)"
        }
    }

    // MARK: - Test Result

    @ViewBuilder
    private var testResultIcon: some View {
        switch testResult {
        case .none:
            EmptyView()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }

    // MARK: - Actions

    private func testConnection() {
        guard let serverURL = appState.config.serverURL,
              let serverKey = appState.config.serverKey else { return }

        isTesting = true
        testResult = .none

        Task {
            let error = await UploadService.testConnection(serverURL: serverURL, serverKey: serverKey)
            await MainActor.run {
                if let error = error {
                    testResult = .failure(error)
                } else {
                    testResult = .success
                }
                isTesting = false
            }
        }
    }
}

/// Row view for a microphone in the priority list
struct MicrophoneRow: View {
    let entry: MicrophoneDisplayEntry
    let onDelete: () -> Void
    let onToggleDisabled: () -> Void

    private var indicatorColor: Color {
        if !entry.isConnected {
            return .gray
        }
        return entry.isDisabled ? .orange : .green
    }

    var body: some View {
        HStack {
            // Connection status indicator
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            // Microphone name
            Text(entry.name)
                .strikethrough(entry.isDisabled)
                .foregroundStyle(entry.isConnected ? (entry.isDisabled ? .secondary : .primary) : .secondary)

            Spacer()

            // Disable/Enable toggle
            Button(action: onToggleDisabled) {
                Image(systemName: entry.isDisabled ? "mic.slash" : "mic")
                    .foregroundStyle(entry.isDisabled ? .orange : .green)
            }
            .buttonStyle(.plain)
            .help(entry.isDisabled ? "Enable microphone" : "Disable microphone")

            // Delete button (only for connected mics)
            if entry.isConnected {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove from priority list")
            } else {
                Text("Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
