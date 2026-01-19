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

    // Privacy tab state
    @State private var newTitlePattern = ""
    @State private var newExcludedApp = ""

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

            privacyTab
                .tabItem { Label("Privacy", systemImage: "eye.slash") }

            statusTab
                .tabItem { Label("Status", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 380)
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

            GroupBox("Microphone Gain") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Boost microphone input level. Changes take effect immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Gain", selection: microphoneGainBinding) {
                        ForEach(1...8, id: \.self) { value in
                            Text("\(value)x").tag(Float(value))
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Audio Processing") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Silence music in system audio", isOn: silenceMusicBinding)
                        .help("When enabled, music-only portions of system audio are silenced during remix")

                    Text("Silences portions of system audio where music is detected but no speech.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
    }

    private var microphoneGainBinding: Binding<Float> {
        Binding(
            get: { appState.config.microphoneGain },
            set: { newValue in
                var config = appState.config
                config.microphoneGain = newValue
                appState.updateConfig(config)
            }
        )
    }

    private var silenceMusicBinding: Binding<Bool> {
        Binding(
            get: { appState.config.silenceMusic },
            set: { newValue in
                var config = appState.config
                config.silenceMusic = newValue
                appState.updateConfig(config)
            }
        )
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

    // MARK: - Privacy Tab

    private var privacyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Excluded Apps") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Always hide all windows from these apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if appState.config.excludedApps.isEmpty {
                            Text("No apps excluded")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(Array(appState.config.excludedApps.enumerated()), id: \.offset) { index, app in
                                    HStack {
                                        Text(app.name)
                                        Spacer()
                                        Button(action: { deleteExcludedApp(at: index) }) {
                                            Image(systemName: "minus.circle")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove app")
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        HStack {
                            TextField("App name (e.g., Slack)", text: $newExcludedApp)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addExcludedApp() }
                            Button("Add") { addExcludedApp() }
                                .disabled(newExcludedApp.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Title Patterns") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hide windows whose title contains these keywords.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if appState.config.excludedTitlePatterns.isEmpty {
                            Text("No patterns configured")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(Array(appState.config.excludedTitlePatterns.enumerated()), id: \.offset) { index, pattern in
                                    HStack {
                                        Text(pattern)
                                        Spacer()
                                        Button(action: { deleteTitlePattern(at: index) }) {
                                            Image(systemName: "minus.circle")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove pattern")
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        HStack {
                            TextField("reddit, facebook, etc.", text: $newTitlePattern)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addTitlePattern() }
                            Button("Add") { addTitlePattern() }
                                .disabled(newTitlePattern.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Private Browsing") {
                    Toggle("Exclude private/incognito browser windows", isOn: excludePrivateBrowsingBinding)
                        .help("Automatically excludes Safari Private, Chrome Incognito, and Firefox Private Browsing windows")
                        .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var excludePrivateBrowsingBinding: Binding<Bool> {
        Binding(
            get: { appState.config.excludePrivateBrowsing },
            set: { newValue in
                var config = appState.config
                config.excludePrivateBrowsing = newValue
                appState.updateConfig(config)
            }
        )
    }

    private func addTitlePattern() {
        let pattern = newTitlePattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }

        var config = appState.config
        if !config.excludedTitlePatterns.contains(where: { $0.lowercased() == pattern.lowercased() }) {
            config.excludedTitlePatterns.append(pattern)
            appState.updateConfig(config)
        }
        newTitlePattern = ""
    }

    private func deleteTitlePattern(at index: Int) {
        var config = appState.config
        config.excludedTitlePatterns.remove(at: index)
        appState.updateConfig(config)
    }

    private func addExcludedApp() {
        let name = newExcludedApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        var config = appState.config
        // Check if already excluded (case-insensitive)
        if !config.excludedApps.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            // Use a simple bundle ID based on the name
            let bundleID = "user.excluded.\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
            config.excludedApps.append(AppEntry(bundleID: bundleID, name: name))
            appState.updateConfig(config)
        }
        newExcludedApp = ""
    }

    private func deleteExcludedApp(at index: Int) {
        var config = appState.config
        config.excludedApps.remove(at: index)
        appState.updateConfig(config)
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
                        // TimelineView only updates when visible, avoiding background timer
                        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                            LabeledContent("Time Remaining") {
                                let remaining = appState.captureManager.segmentTimeRemaining
                                let mins = Int(remaining) / 60
                                let secs = Int(remaining) % 60
                                Text(String(format: "%d:%02d", mins, secs))
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Upload") {
                uploadStatusView
                    .padding(.vertical, 4)
            }

            GroupBox("Debug") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("1-minute segments", isOn: debugSegmentsBinding)
                        .help("Use 1-minute segments instead of 5-minute for testing")
                    Toggle("Keep rejected audio", isOn: debugKeepRejectedBinding)
                        .help("Move rejected mic tracks to rejected/ folder instead of deleting")
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
    }

    private var debugSegmentsBinding: Binding<Bool> {
        Binding(
            get: { appState.config.debugSegments },
            set: { newValue in
                var config = appState.config
                config.debugSegments = newValue
                appState.updateConfig(config)

                Task {
                    await appState.captureManager?.setDebugSegments(newValue)
                }
            }
        )
    }

    private var debugKeepRejectedBinding: Binding<Bool> {
        Binding(
            get: { appState.config.debugKeepRejectedAudio },
            set: { newValue in
                var config = appState.config
                config.debugKeepRejectedAudio = newValue
                appState.updateConfig(config)
            }
        )
    }

    // MARK: - Upload Status

    @ViewBuilder
    private var uploadStatusView: some View {
        let status = appState.uploadCoordinator.status
        let pending = appState.uploadCoordinator.pendingCount

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

    private func statusIcon(for status: UploadCoordinator.Status) -> some View {
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

    private func statusText(for status: UploadCoordinator.Status) -> String {
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
            let error = await UploadCoordinator.testConnection(serverURL: serverURL, serverKey: serverKey)
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
