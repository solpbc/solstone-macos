// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI

struct SetupView: View {
    @Bindable var appState: AppState
    @State private var serverURL = ""
    @State private var serverKey = ""

    init(appState: AppState, initialServerURL: String = "", initialServerKey: String = "") {
        self.appState = appState
        self._serverURL = State(initialValue: initialServerURL)
        self._serverKey = State(initialValue: initialServerKey)
    }

    var body: some View {
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
        .frame(width: 420)
    }
}
