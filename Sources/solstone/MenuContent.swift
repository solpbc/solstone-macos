// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The content of the status bar menu
struct MenuContent: View {
    @Bindable var appState: AppState
    @Bindable var updateController: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status section
        Section {
            statusRow
        }

        Divider()

        // Pause / Resume / Start recording controls
        Section {
            pauseResumeSection
        }

        Divider()

        Section {
            if appState.config.isUploadConfigured {
                Button("open journal") {
                    NSWorkspace.shared.open(URL(string: appState.config.serverURL!)!)
                }
            }
            Button("settings...") {
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(UpdatesCopy.menuBarCheckForUpdates) {
                appState.pendingSettingsTab = "updates"
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
                updateController.checkForUpdates()
            }
            Button("about solstone observer") {
                openWindow(id: "about")
                appState.didOpenWindow(.about)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button("quit solstone observer") {
            Task { @MainActor in
                // Stop recording gracefully before quitting
                if appState.isRecording {
                    await appState.stopRecording()
                }
                appState.requestMenuBarQuit()
            }
        }
    }

    // MARK: - Status Row

    private var permissionsMissing: Bool {
        !appState.screenRecordingGranted || !appState.microphoneGranted
    }

    @ViewBuilder
    private var statusRow: some View {
        if permissionsMissing {
            Button("permissions needed — open settings →") {
                appState.pendingSettingsTab = "permissions"
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            .foregroundStyle(.red)
        } else if let error = appState.errorMessage {
            Button("error: \(error)") {
                appState.pendingSettingsTab = "status"
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            .foregroundStyle(.red)
        } else if appState.isRecording && !appState.config.isUploadConfigured && !appState.isPaused && !appState.pauseManager.isPaused {
            Button("observing - local only →") {
                appState.pendingSettingsTab = "service"
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else if appState.isRecording && !appState.isPaused && !appState.pauseManager.isPaused {
            if appState.config.syncPaused {
                Text(recordingStatusText)
            } else {
                switch appState.uploadCoordinator.status {
                case .offline, .retrying:
                    Button("observing - offline (recording locally) →") {
                        appState.pendingSettingsTab = "status"
                        openWindow(id: "settings")
                        appState.didOpenWindow(.settings)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                default:
                    Text(recordingStatusText)
                }
            }
        } else {
            Text(recordingStatusText)
        }
    }

    private var recordingStatusText: String {
        if appState.pauseManager.isPaused {
            return "paused"
        }
        if appState.isPaused {
            return "paused"
        }
        if !appState.isRecording {
            return "stopped"
        }
        if appState.config.syncPaused {
            return "observing - sync paused"
        }
        switch appState.uploadCoordinator.status {
        case .synced, .syncing, .uploading:
            return "observing - connected"
        case .notSynced:
            return "observing - offline"
        case .retrying, .offline:
            return "observing - offline (recording locally)"
        }
    }

    // MARK: - Pause Controls

    @ViewBuilder
    private var pauseResumeSection: some View {
        if appState.isRecording && !appState.isPaused && !appState.pauseManager.isPaused {
            Menu("pause") {
                Button("15 minutes") {
                    appState.pauseManager.pause(for: .minutes(15))
                }
                Button("30 minutes") {
                    appState.pauseManager.pause(for: .minutes(30))
                }
                Button("1 hour") {
                    appState.pauseManager.pause(for: .minutes(60))
                }
                Button("until I resume") {
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
        } else if !appState.isRecording && appState.errorMessage == nil && !permissionsMissing {
            Button("start recording") {
                Task {
                    await appState.startRecording()
                }
            }
        }
    }

    // MARK: - Upload Status Row

}
