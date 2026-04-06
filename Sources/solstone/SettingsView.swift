// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI
import os

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
    enum Tab: Hashable {
        case permissions, observer, service, microphones, privacy, status
    }

    @Bindable var appState: AppState
    @State var selectedTab: Tab = .observer
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: TestResult = .none
    @State private var isTesting = false
    @State private var storageUsedMB: Int?

    // Permissions tab state
    @State private var screenRecordingPrompted = false

    // Privacy tab state
    @State private var newTitlePattern = ""
    @State private var newExcludedApp = ""

    // Service tab state
    @State private var localStatus: LocalStatus = .idle
    @State private var remoteExpanded = false
    @State private var remoteURL = ""
    @State private var remoteKey = ""
    @State private var remoteError: String?
    @State private var remoteTesting = false

    enum TestResult: Equatable {
        case none
        case success
        case failure(String)
    }

    enum LocalStatus: Equatable {
        case idle
        case detecting
        case connected
        case failed(String)
    }

    private static let localServerURL = "http://localhost:5015"

    init(appState: AppState, selectedTab: Tab = .observer, initialStorageUsedMB: Int? = nil) {
        self.appState = appState
        self.selectedTab = selectedTab
        self._storageUsedMB = State(initialValue: initialStorageUsedMB)
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
        TabView(selection: $selectedTab) {
            observerTab
                .tag(Tab.observer)
                .tabItem { Label("observer", systemImage: "eye") }

            serviceTab
                .tag(Tab.service)
                .tabItem { Label("service", systemImage: "server.rack") }

            microphoneTab
                .tag(Tab.microphones)
                .tabItem { Label("microphones", systemImage: "mic") }

            privacyTab
                .tag(Tab.privacy)
                .tabItem { Label("privacy", systemImage: "eye.slash") }

            statusTab
                .tag(Tab.status)
                .tabItem { Label("status", systemImage: "info.circle") }

            permissionsTab
                .tag(Tab.permissions)
                .tabItem { Label("permissions", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 380)
        .onAppear {
            appState.syncMicrophonePriorityList()
            if let pending = appState.pendingSettingsTab {
                switch pending {
                case "permissions": selectedTab = .permissions
                case "service": selectedTab = .service
                default: break
                }
                appState.pendingSettingsTab = nil
            }
        }
        .onExitCommand {
            dismiss()
        }
    }

    // MARK: - Permissions Tab

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("solstone observer needs screen recording and microphone access to build your memory.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("screen recording")
                        .font(.headline)
                    if appState.screenRecordingGranted {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("all good")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("to search your entire history — every meeting, document, and idea — solstone observer captures your screen continuously. everything stays on your mac and goes only to your server.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            if screenRecordingPrompted {
                                Button("restart solstone observer") {
                                    relaunchApp()
                                }
                            } else {
                                Button("enable screen recording →") {
                                    Logger.setup.info("Button tapped: enable screen recording")
                                    PermissionChecker().promptScreenRecording()
                                    screenRecordingPrompted = true
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .opacity(appState.screenRecordingGranted ? 0.7 : 1.0)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("microphone")
                        .font(.headline)
                    if appState.microphoneGranted {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("all good")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("to capture conversations and meetings, solstone observer needs mic access. same rules: stored locally, sent only to your server. no third parties, no exceptions.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("grant access") {
                                Task {
                                    await PermissionChecker().requestMicrophone()
                                    appState.microphoneGranted = PermissionChecker().microphoneGranted
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .opacity(appState.microphoneGranted ? 0.7 : 1.0)

            Text("you can review or revoke these anytime in system settings → privacy & security.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.screenRecordingGranted && appState.microphoneGranted && !appState.config.isUploadConfigured {
                HStack {
                    Spacer()
                    Button("continue to service configuration →") {
                        selectedTab = .service
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }

            Spacer()
        }
    }

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundlePath]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Observer Tab

    private var observerTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("general") {
                Toggle("start at login", isOn: Binding(
                    get: { appState.isLoginItemEnabled },
                    set: { appState.setLoginItemEnabled($0) }
                ))
                .padding(.vertical, 4)
            }

            GroupBox("local storage") {
                LabeledContent("currently using") {
                    if let used = storageUsedMB {
                        Text("\(used) MB")
                    } else {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .padding(.vertical, 4)

                LabeledContent("local storage limit") {
                    Stepper("\(appState.config.localRetentionMB) MB", value: localRetentionBinding, in: 50...10000, step: 50)
                }
                .padding(.vertical, 4)
            }
            .task {
                if storageUsedMB == nil {
                    let bytes = await appState.storageManager.calculateStorageUsed()
                    storageUsedMB = Int(bytes / (1024 * 1024))
                }
            }

            Spacer()
        }
    }

    // MARK: - Service Tab

    private var serviceTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            if appState.config.isUploadConfigured {
                // Connected state — show current config
                connectedServiceSection
            } else {
                // Not connected — show setup options
                serviceSetupSection
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var connectedServiceSection: some View {
        GroupBox("connected") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("server URL") {
                    TextField("https://solstone.example.com", text: serverURLBinding)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("API key") {
                    SecureField("paste key from server", text: serverKeyBinding)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button("test connection") {
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
    }

    @ViewBuilder
    private var serviceSetupSection: some View {
        GroupBox("connect to solstone service") {
            VStack(alignment: .leading, spacing: 12) {
                Text("connect to a solstone service to store and search your captures.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Local detection
                HStack {
                    Button("detect local service") {
                        Task { await detectLocalService() }
                    }
                    .disabled(localDetectDisabled)

                    switch localStatus {
                    case .idle:
                        EmptyView()
                    case .detecting:
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                        Text("detecting...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .connected:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .failed(let reason):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Remote service option
                Button(remoteExpanded ? "hide remote setup" : "connect to remote service...") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        remoteExpanded.toggle()
                    }
                }
                .buttonStyle(.link)
                .font(.callout)

                if remoteExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("server URL") {
                            TextField("https://solstone.example.com", text: $remoteURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        LabeledContent("API key") {
                            SecureField("paste key from server", text: $remoteKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Spacer()
                            if remoteTesting {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 16, height: 16)
                            }
                            if let error = remoteError {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Button("connect") {
                                Task { await connectRemoteService() }
                            }
                            .disabled(remoteURL.isEmpty || remoteKey.isEmpty || remoteTesting)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Service Connection Logic

    private var localDetectDisabled: Bool {
        if case .detecting = localStatus { return true }
        return false
    }

    private func detectLocalService() async {
        localStatus = .detecting

        // Check existing config first
        if let existingKey = appState.config.serverKey, !existingKey.isEmpty {
            Logger.setup.info("local detect: key found in config")
            let error = await UploadCoordinator.testConnection(
                serverURL: Self.localServerURL, serverKey: existingKey
            )
            if let error {
                Logger.setup.info("local detect: keychain key failed — \(error, privacy: .public)")
                localStatus = .failed("local service not reachable — \(error)")
                return
            }
            saveServiceAndStart(url: Self.localServerURL, key: existingKey)
            localStatus = .connected
            return
        }

        // Find sol binary
        let solPath = await findSolBinary()
        guard let solPath else {
            Logger.setup.info("local detect: sol binary not found")
            localStatus = .failed("sol CLI not found — try again")
            return
        }
        Logger.setup.info("local detect: sol found at \(solPath, privacy: .public)")

        // Run remote create
        let result = await runSolRemoteCreate(solPath: solPath)
        switch result {
        case .success(let key):
            Logger.setup.info("local detect: CLI success, verifying connectivity")
            let error = await UploadCoordinator.testConnection(
                serverURL: Self.localServerURL, serverKey: key
            )
            if let error {
                localStatus = .failed("registered but can't connect — \(error)")
                return
            }
            saveServiceAndStart(url: Self.localServerURL, key: key)
            localStatus = .connected
        case .failure(let reason):
            Logger.setup.info("local detect: CLI failed — \(reason, privacy: .public)")
            localStatus = .failed("\(reason) — try again")
        }
    }

    private func connectRemoteService() async {
        remoteTesting = true
        remoteError = nil

        let error = await UploadCoordinator.testConnection(
            serverURL: remoteURL, serverKey: remoteKey
        )
        remoteTesting = false

        if let error {
            remoteError = error
        } else {
            saveServiceAndStart(url: remoteURL, key: remoteKey)
        }
    }

    private func saveServiceAndStart(url: String, key: String) {
        var config = appState.config
        config.serverURL = url
        config.serverKey = key
        appState.updateConfig(config)

        // Open browser to solstone service
        if let browserURL = URL(string: url) {
            NSWorkspace.shared.open(browserURL)
        }

        // Try recording — startRecording sets screenRecordingGranted based on result
        if appState.microphoneGranted {
            Task {
                await appState.startRecording()
                Task.detached { await appState.uploadCoordinator?.syncOnStartup() }
            }
        }
    }

    // MARK: - Sol CLI Helpers

    private func findSolBinary() async -> String? {
        let preferred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/sol").path
        if FileManager.default.fileExists(atPath: preferred) {
            return preferred
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = ["sol"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let path, !path.isEmpty {
                            continuation.resume(returning: path)
                            return
                        }
                    }
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private enum SolResult {
        case success(String)
        case failure(String)
    }

    private struct RemoteCreateResponse: Decodable {
        let name: String
        let key: String
        let prefix: String
    }

    private func runSolRemoteCreate(solPath: String) async -> SolResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: solPath)
                process.arguments = ["remote", "--json", "create", "solstone-macos"]
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()

                    let timer = DispatchSource.makeTimerSource()
                    timer.schedule(deadline: .now() + 10)
                    timer.setEventHandler {
                        process.terminate()
                    }
                    timer.resume()

                    process.waitUntilExit()
                    timer.cancel()

                    if process.terminationStatus == 0 {
                        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        if let response = try? JSONDecoder().decode(RemoteCreateResponse.self, from: data) {
                            continuation.resume(returning: .success(response.key))
                        } else {
                            continuation.resume(returning: .failure("could not parse JSON response"))
                        }
                    } else {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        if stderr.contains("already exists") {
                            continuation.resume(returning: .failure("remote already exists"))
                        } else {
                            continuation.resume(returning: .failure("exit code \(process.terminationStatus)"))
                        }
                    }
                } catch {
                    continuation.resume(returning: .failure(error.localizedDescription))
                }
            }
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
            GroupBox("microphone priority") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("drag to reorder. the microphone at the top is used first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if microphoneDisplayEntries.isEmpty {
                        Text("no microphones detected")
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

            GroupBox("microphone gain") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("boost microphone input level. changes take effect immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("gain", selection: microphoneGainBinding) {
                        ForEach(1...8, id: \.self) { value in
                            Text("\(value)x").tag(Float(value))
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 4)
            }

            GroupBox("audio processing") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("silence music in system audio", isOn: silenceMusicBinding)
                        .help("when enabled, music-only portions of system audio are silenced during remix")

                    Text("silences portions of system audio where music is detected but no speech.")
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
                GroupBox("excluded apps") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("windows from these apps are never captured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if appState.config.excludedApps.isEmpty {
                            Text("no apps excluded")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
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
                                        .help("remove app")
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        HStack {
                            TextField("app name (e.g., slack)", text: $newExcludedApp)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addExcludedApp() }
                            Button("add") { addExcludedApp() }
                                .disabled(newExcludedApp.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("title patterns") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("hide windows whose title contains these keywords.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if appState.config.excludedTitlePatterns.isEmpty {
                            Text("no patterns configured")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
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
                                        .help("remove pattern")
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        HStack {
                            TextField("reddit, facebook, etc.", text: $newTitlePattern)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addTitlePattern() }
                            Button("add") { addTitlePattern() }
                                .disabled(newTitlePattern.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("private browsing") {
                    Toggle("exclude private/incognito browser windows", isOn: excludePrivateBrowsingBinding)
                        .help("automatically excludes safari private, chrome incognito, and firefox private browsing windows")
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
            GroupBox("recording") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("state") {
                        Text(appState.isRecording ? (appState.isPaused ? "paused" : "recording") : "stopped")
                    }

                    if appState.isRecording && !appState.isPaused {
                        // TimelineView only updates when visible, avoiding background timer
                        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                            LabeledContent("time remaining") {
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

            GroupBox("upload") {
                VStack(alignment: .leading, spacing: 8) {
                    uploadStatusView
                    Button("resync all") {
                        appState.uploadCoordinator.forceFullSync()
                    }
                    .help("re-check all days, including previously synced ones")
                }
                .padding(.vertical, 4)
            }

            #if DEBUG
            GroupBox("debug") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("1-minute segments", isOn: debugSegmentsBinding)
                        .help("use 1-minute segments instead of 5-minute for testing")
                    Toggle("keep rejected audio", isOn: debugKeepRejectedBinding)
                        .help("move rejected mic tracks to rejected/ folder instead of deleting")
                }
                .padding(.vertical, 4)
            }
            #endif

            Spacer()
        }
    }

    #if DEBUG
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
    #endif

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
            return "connecting..."
        case .synced:
            return "synced"
        case .syncing(let checked, let total):
            return "syncing: \(checked)/\(total)"
        case .uploading(let segment):
            return "uploading: \(segment)"
        case .retrying(let segment, let attempts):
            return "retrying \(segment) (attempt \(attempts))"
        case .offline(let error):
            return "offline: \(error)"
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
            .help(entry.isDisabled ? "enable microphone" : "disable microphone")

            // Delete button (only for connected mics)
            if entry.isConnected {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("remove from priority list")
            } else {
                Text("disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
