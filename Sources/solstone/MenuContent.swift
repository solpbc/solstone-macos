// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The content of the status bar menu
struct MenuContent: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status section
        Section {
            statusRow
            if appState.isRecording && !appState.isPaused && !appState.pauseManager.isPaused
                && appState.config.isUploadConfigured {
                Text(syncStatusText)
            }
            uploadStatusRow
        }

        Divider()

        // Pause / Resume / Start recording controls
        Section {
            pauseResumeSection
        }

        Divider()

        // Settings
        Section {
            Button("settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Section {
            Button("about solstone observer...") {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button("quit solstone observer") {
            Task {
                // Stop recording gracefully before quitting
                if appState.isRecording {
                    await appState.stopRecording()
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Status Row

    @ViewBuilder
    private var statusRow: some View {
        if appState.errorMessage != nil {
            Button("permissions needed — open settings →") {
                appState.pendingSettingsTab = "permissions"
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .foregroundStyle(.red)
        } else {
            Text(recordingStatusText)
        }
    }

    private var recordingStatusText: String {
        if appState.pauseManager.isPaused {
            let _ = appState.pauseManager.refreshTick
            if let timeText = appState.pauseManager.formatTimeRemaining() {
                return "paused - \(timeText) remaining"
            }
            return "paused"
        }
        if appState.isPaused {
            return "paused"
        }
        if !appState.isRecording {
            return "not recording"
        }
        return "recording"
    }

    private var syncStatusText: String {
        if appState.config.syncPaused {
            return "sync: paused"
        }
        switch appState.uploadCoordinator.status {
        case .notSynced:
            return "sync: pending"
        case .syncing(let checked, let total):
            return "sync: checking (\(checked)/\(total))"
        case .synced:
            return "sync: up to date"
        case .uploading:
            return "sync: uploading"
        case .retrying(_, let attempts):
            return "sync: retrying (\(attempts))"
        case .offline:
            return "sync: offline"
        }
    }

    // MARK: - Pause Controls

    @ViewBuilder
    private var pauseResumeSection: some View {
        if appState.isRecording && !appState.isPaused && !appState.pauseManager.isPaused {
            Menu("pause") {
                Button("5 minutes") {
                    appState.pauseManager.pause(for: .minutes(5))
                }
                Button("15 minutes") {
                    appState.pauseManager.pause(for: .minutes(15))
                }
                Button("30 minutes") {
                    appState.pauseManager.pause(for: .minutes(30))
                }
                Button("1 hour") {
                    appState.pauseManager.pause(for: .minutes(60))
                }
                Button("2 hours") {
                    appState.pauseManager.pause(for: .minutes(120))
                }
                Button("indefinitely") {
                    appState.pauseManager.pause(for: .indefinite)
                }
            }
        } else if appState.pauseManager.isPaused {
            let _ = appState.pauseManager.refreshTick
            if let timeText = appState.pauseManager.formatTimeRemaining() {
                Button("resume (\(timeText) remaining)") {
                    appState.pauseManager.resume()
                }
            } else {
                Button("resume") {
                    appState.pauseManager.resume()
                }
            }
        } else if !appState.isRecording && appState.errorMessage == nil {
            Button("start recording") {
                Task {
                    await appState.startRecording()
                }
            }
        }
    }

    // MARK: - Upload Status Row

    @ViewBuilder
    private var uploadStatusRow: some View {
        if appState.config.isUploadConfigured {
            if appState.config.syncPaused {
                Button("resume sync") {
                    var config = appState.config
                    config.syncPaused = false
                    appState.updateConfig(config)
                }
            } else {
                Button("pause sync") {
                    var config = appState.config
                    config.syncPaused = true
                    appState.updateConfig(config)
                }
            }
        }
    }
}
