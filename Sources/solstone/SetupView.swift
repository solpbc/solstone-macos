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
                Text("checking for local server...")
                    .font(.title)
                    .bold()

                Text("looking for a solstone server on this mac.")
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
        let url = URL(string: "\(Self.localServerURL)/app/remote/api/create")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["name": "solstone-macos"])

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                struct RegistrationResponse: Decodable {
                    let key: String
                }

                let registration = try JSONDecoder().decode(RegistrationResponse.self, from: data)
                Log.info("auto-registration: success")

                var appConfig = appState.config
                appConfig.serverURL = Self.localServerURL
                appConfig.setServerKey(registration.key)
                appState.updateConfig(appConfig)
                NSApp.keyWindow?.close()
                Task {
                    await appState.startRecording()
                }
                Task.detached {
                    await appState.uploadCoordinator?.syncOnStartup()
                }
            } else {
                Log.info("auto-registration: server returned non-200")
                fallbackToManualSetup()
            }
        } catch {
            Log.info("auto-registration: failed — \(error.localizedDescription)")
            fallbackToManualSetup()
        }

        session.invalidateAndCancel()
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
                    LabeledContent("Server URL") {
                        TextField("https://solstone.example.com", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("API Key") {
                        SecureField("Paste key from server", text: $serverKey)
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
