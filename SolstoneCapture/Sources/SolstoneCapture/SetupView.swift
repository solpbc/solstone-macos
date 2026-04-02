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

    enum Step {
        case permissions
        case serverConfig
    }

    init(appState: AppState, initialServerURL: String = "", initialServerKey: String = "", initialStep: Step? = nil) {
        self.appState = appState
        self._serverURL = State(initialValue: initialServerURL)
        self._serverKey = State(initialValue: initialServerKey)
        self._step = State(initialValue: initialStep ?? (PermissionChecker().allGranted ? .serverConfig : .permissions))
    }

    var body: some View {
        Group {
            if step == .permissions {
                permissionsStep
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            } else {
                serverConfigStep
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
                                step = .serverConfig
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
    private var serverConfigStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                bundleImage("sol-wordmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)

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
