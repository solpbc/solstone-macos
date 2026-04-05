// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI

struct SetupView: View {
    @Bindable var appState: AppState
    @State private var screenRecordingGranted: Bool
    @State private var microphoneGranted: Bool

    // Service connection state
    @State private var localStatus: LocalStatus = .idle
    @State private var remoteExpanded = false
    @State private var remoteURL = ""
    @State private var remoteKey = ""
    @State private var remoteError: String?
    @State private var remoteTesting = false
    @State private var connectedURL: String?
    @State private var connectedKey: String?

    private static let localServerURL = "http://localhost:5015"

    enum LocalStatus {
        case idle
        case detecting
        case connected
        case failed(String)
    }

    init(appState: AppState, initialStep: Step? = nil) {
        self.appState = appState
        let checker = PermissionChecker()
        self._screenRecordingGranted = State(initialValue: checker.screenRecordingGranted)
        self._microphoneGranted = State(initialValue: checker.microphoneGranted)
    }

    // Keep Step enum for snapshot test compatibility
    enum Step {
        case permissions
    }

    private var isConnected: Bool { connectedURL != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("set up solstone observer")
                        .font(.title)
                        .bold()

                    Text("solstone observer needs two permissions and a connection to your solstone service.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Section 1: Screen Recording
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("screen recording")
                            .font(.headline)
                        if screenRecordingGranted {
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
                                Button("enable screen recording →") {
                                    Log.info("[Setup] Button tapped: enable screen recording")
                                    PermissionChecker().promptScreenRecording()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .opacity(screenRecordingGranted ? 0.7 : 1.0)

                // Section 2: Microphone
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("microphone")
                            .font(.headline)
                        if microphoneGranted {
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
                                        microphoneGranted = PermissionChecker().microphoneGranted
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .opacity(microphoneGranted ? 0.7 : 1.0)

                // Section 3: Service Connection
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("solstone service")
                            .font(.headline)

                        if isConnected {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("connected to \(connectedURL ?? "")")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("connect to a solstone service to store and search your captures.")
                                .font(.body)
                                .foregroundStyle(.secondary)

                            // Local detection button
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
                                    EmptyView() // handled by isConnected above
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .opacity(isConnected ? 0.7 : 1.0)

                Text("you can review or revoke permissions anytime in system settings → privacy & security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Final action button
                HStack {
                    Spacer()

                    Button("start observing and open browser →") {
                        completeSetup()
                    }
                    .disabled(!(screenRecordingGranted && microphoneGranted && isConnected))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(30)
        }
        .frame(width: 420)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let checker = PermissionChecker()
            screenRecordingGranted = checker.screenRecordingGranted
            microphoneGranted = checker.microphoneGranted
        }
    }

    // MARK: - Local Service Detection

    private var localDetectDisabled: Bool {
        if case .detecting = localStatus { return true }
        return false
    }

    private func detectLocalService() async {
        localStatus = .detecting

        // Check keychain first
        if let existingKey = KeychainManager.loadServerKey(), !existingKey.isEmpty {
            Log.info("[Setup] local detect: key found in keychain")
            let error = await UploadCoordinator.testConnection(
                serverURL: Self.localServerURL, serverKey: existingKey
            )
            if let error {
                Log.info("[Setup] local detect: keychain key failed connectivity — \(error)")
                localStatus = .failed("local service not reachable — \(error)")
                return
            }
            connectedURL = Self.localServerURL
            connectedKey = existingKey
            localStatus = .connected
            return
        }

        // Find sol binary
        let solPath = await findSolBinary()
        guard let solPath else {
            Log.info("[Setup] local detect: sol binary not found")
            localStatus = .failed("sol CLI not found — try again")
            return
        }
        Log.info("[Setup] local detect: sol found at \(solPath)")

        // Run remote create
        let result = await runSolRemoteCreate(solPath: solPath)
        switch result {
        case .success(let key):
            Log.info("[Setup] local detect: CLI success, verifying connectivity")
            let error = await UploadCoordinator.testConnection(
                serverURL: Self.localServerURL, serverKey: key
            )
            if let error {
                localStatus = .failed("registered but can't connect — \(error)")
                return
            }
            connectedURL = Self.localServerURL
            connectedKey = key
            localStatus = .connected
        case .failure(let reason):
            Log.info("[Setup] local detect: CLI failed — \(reason)")
            localStatus = .failed("\(reason) — try again")
        }
    }

    // MARK: - Remote Service Connection

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
            connectedURL = remoteURL
            connectedKey = remoteKey
            remoteError = nil
        }
    }

    // MARK: - Complete Setup

    private func completeSetup() {
        guard let url = connectedURL, let key = connectedKey else { return }

        var config = appState.config
        config.serverURL = url
        config.setServerKey(key)
        appState.updateConfig(config)
        NSApp.keyWindow?.close()

        // Open browser to solstone service
        if let browserURL = URL(string: url) {
            NSWorkspace.shared.open(browserURL)
        }

        Task {
            await appState.startRecording()
        }
        Task.detached {
            await appState.uploadCoordinator?.syncOnStartup()
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
}
