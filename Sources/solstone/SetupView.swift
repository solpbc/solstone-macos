// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI
import os

struct SetupView: View {
    @Bindable var appState: AppState
    @State private var screenRecordingGranted: Bool
    @State private var microphoneGranted: Bool
    @Environment(\.openWindow) private var openWindow

    init(appState: AppState) {
        self.appState = appState
        let checker = PermissionChecker()
        self._screenRecordingGranted = State(initialValue: checker.screenRecordingGranted)
        self._microphoneGranted = State(initialValue: checker.microphoneGranted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("two permissions, once.")
                    .font(.title)
                    .bold()

                Text("solstone observer needs screen recording and microphone access to build your memory. here's what each does and why.")
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
                                Logger.setup.info("Button tapped: enable screen recording")
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

            Text("you can review or revoke these anytime in system settings → privacy & security.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()

                if appState.config.serverURL != nil {
                    // Returning user — just needs permissions
                    Button("continue →") {
                        NSApp.keyWindow?.close()
                        Task {
                            await appState.startRecording()
                        }
                    }
                    .disabled(!(screenRecordingGranted && microphoneGranted))
                    .keyboardShortcut(.defaultAction)
                } else {
                    // First-time setup — go to service configuration
                    Button("continue to service configuration →") {
                        NSApp.keyWindow?.close()
                        appState.pendingSettingsTab = "service"
                        openWindow(id: "settings")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .disabled(!(screenRecordingGranted && microphoneGranted))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(30)
        .frame(width: 420)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let checker = PermissionChecker()
            screenRecordingGranted = checker.screenRecordingGranted
            microphoneGranted = checker.microphoneGranted
        }
    }
}
