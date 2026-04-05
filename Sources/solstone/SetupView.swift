// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI

struct SetupView: View {
    @Bindable var appState: AppState
    @State private var serverURL = ""
    @State private var serverKey = ""
    @State private var permissionChecker = PermissionChecker()
    @State private var isRequestingPermissions = false
    @State private var step: Step

    private static let localServerURL = "http://localhost:5015"

    enum Step {
        case permissions
        case autoDetect
        case serverConfig
    }

    init(appState: AppState, initialServerURL: String = "", initialServerKey: String = "", initialStep: Step? = nil) {
        self.appState = appState
        self._serverURL = State(initialValue: initialServerURL)
        self._serverKey = State(initialValue: initialServerKey)
        self._step = State(initialValue: initialStep ?? (PermissionChecker().allGranted ? .autoDetect : .permissions))
    }

    var body: some View {
        Group {
            if step == .permissions {
                permissionsStep
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            } else if step == .serverConfig {
                serverConfigStep
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            } else {
                autoDetectStep
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("two permissions, once.")
                    .font(.title)
                    .bold()

                Text("solstone needs screen recording and microphone access to build your memory. here's what each does and why.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !permissionChecker.screenRecordingGranted {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("screen recording")
                            .font(.headline)
                        Text("to search your entire history — every meeting, document, and idea — solstone captures your screen continuously. everything stays on your mac and goes only to your server.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            if !permissionChecker.microphoneGranted {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("microphone")
                            .font(.headline)
                        Text("to capture conversations and meetings, solstone needs mic access. same rules: stored locally, sent only to your server. no third parties, no exceptions.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            Text("you can review or revoke these anytime in system settings → privacy & security.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                if isRequestingPermissions {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                }

                Button("continue →") {
                    isRequestingPermissions = true
                    Task {
                        await permissionChecker.requestAll()
                        isRequestingPermissions = false
                        if appState.config.serverURL != nil {
                            NSApp.keyWindow?.close()
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                step = .autoDetect
                            }
                        }
                    }
                }
                .disabled(isRequestingPermissions)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
    }

    @ViewBuilder
    private var autoDetectStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("setting up...")
                    .font(.title)
                    .bold()

                Text("registering this mac with your solstone journal.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                Spacer()
            }
            .padding(.vertical, 20)
        }
        .padding(30)
        .task {
            await attemptAutoRegistration()
        }
    }

    private func attemptAutoRegistration() async {
        if let existingKey = KeychainManager.loadServerKey(), !existingKey.isEmpty {
            Log.info("auto-registration: key found in keychain, skipping CLI")
            var config = appState.config
            config.serverURL = Self.localServerURL
            config.setServerKey(existingKey)
            appState.updateConfig(config)
            NSApp.keyWindow?.close()
            Task {
                await appState.startRecording()
            }
            Task.detached {
                await appState.uploadCoordinator?.syncOnStartup()
            }
            return
        }

        let solPath = await findSolBinary()
        guard let solPath else {
            Log.info("auto-registration: sol binary not found")
            fallbackToManualSetup()
            return
        }
        Log.info("auto-registration: sol found at \(solPath)")

        let result = await runSolRemoteCreate(solPath: solPath)

        switch result {
        case .success(let key):
            Log.info("auto-registration: CLI success")
            var config = appState.config
            config.serverURL = Self.localServerURL
            config.setServerKey(key)
            appState.updateConfig(config)
            NSApp.keyWindow?.close()
            Task {
                await appState.startRecording()
            }
            Task.detached {
                await appState.uploadCoordinator?.syncOnStartup()
            }
        case .failure(let reason):
            Log.info("auto-registration: CLI failed — \(reason)")
            fallbackToManualSetup()
        }
    }

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

    private func fallbackToManualSetup() {
        withAnimation(.easeInOut(duration: 0.25)) {
            step = .serverConfig
        }
    }

    @ViewBuilder
    private var serverConfigStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                bundleImage("sol-wordmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)

                Text("solstone")
                    .font(.title)
                    .bold()

                Text("captures everything you see and hear and makes it searchable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("by sol pbc — a public benefit corporation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GroupBox("server configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("server URL") {
                        TextField("https://solstone.example.com", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("API key") {
                        SecureField("paste key from server", text: $serverKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.vertical, 4)
            }

            Link("need a server? visit solstone.app/install", destination: URL(string: "https://solstone.app/install")!)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button("get started") {
                    var config = appState.config
                    config.serverURL = serverURL
                    config.setServerKey(serverKey)
                    appState.updateConfig(config)
                    NSApp.keyWindow?.close()
                    Task {
                        await appState.startRecording()
                    }
                    Task.detached {
                        await appState.uploadCoordinator?.syncOnStartup()
                    }
                }
                .disabled(serverURL.isEmpty || serverKey.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
    }
}
