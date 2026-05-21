// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import SolstoneCore

/// The content of the status bar menu
struct MenuContent: View {
    @Bindable var appState: AppState
    @Bindable var updateController: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let pending = appState.solChatPending {
            Section {
                Button("· \(pending.summary)") {
                    Task {
                        await AppState.shared?.solChatBridge.handleClick(requestID: pending.id)
                    }
                }
            }

            Divider()
        }

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
                    if let url = journalURLToOpen(from: appState.config.serverURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button {
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                if let iconName = settingsAttentionIconName(anyTabNeedsAttention: appState.anyTabNeedsAttention) {
                    Label {
                        Text("settings...")
                    } icon: {
                        Image(systemName: iconName)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("settings...")
                }
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
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Status Row

    @ViewBuilder
    private var statusRow: some View {
        if appState.permissionsNeedAttention {
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
        } else if appState.bundledPipelineStatusAvailable,
                  let pipelineRow = pipelineStatusRowModel(
                    pipelineDead: appState.pipelineDead,
                    isRestartingPipeline: appState.isRestartingPipeline,
                    pipelineBinaryMissing: appState.pipelineBinaryMissing
                  ) {
            if pipelineRow.isEnabled {
                Button(pipelineRow.text) {
                    appState.requestPipelineRestart()
                }
                .foregroundStyle(.red)
            } else {
                Text(pipelineRow.text)
                    .foregroundStyle(.red)
            }
        } else if appState.isRecording && !appState.config.isUploadConfigured && !appState.isPaused && !appState.pauseManager.isPaused {
            Button("observing - local only →") {
                appState.pendingSettingsTab = "journal"
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
                    Button("observing - offline (saved locally) →") {
                        appState.pendingSettingsTab = "status"
                        openWindow(id: "settings")
                        appState.didOpenWindow(.settings)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                default:
                    Text(recordingStatusText)
                }
            }
        } else if appState.pauseManager.isPaused {
            let _ = appState.pauseManager.refreshTick
            Text(pausedHeaderText(timeRemaining: appState.pauseManager.formatTimeRemaining()))
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
            return "observing - offline (saved locally)"
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
            Button("resume") { appState.pauseManager.resume() }
        } else if !appState.isRecording && appState.errorMessage == nil && !appState.permissionsNeedAttention {
            Button("start observing") {
                Task {
                    await appState.startRecording()
                }
            }
        }

        if appState.bundledPipelineRestartAvailable {
            Button("restart pipeline") {
                appState.requestPipelineRestart()
            }
            .disabled(appState.isRestartingPipeline)
        }
    }

    // MARK: - Upload Status Row

}

func journalURLToOpen(from serverURL: String?) -> URL? {
    URL(string: serverURL ?? "")
}

func pipelineStatusRowModel(
    pipelineDead: Bool,
    isRestartingPipeline: Bool,
    pipelineBinaryMissing: Bool
) -> (text: String, isEnabled: Bool)? {
    if pipelineBinaryMissing {
        return ("solstone is not fully installed", false)
    }
    if isRestartingPipeline {
        return ("restarting…", false)
    }
    if pipelineDead {
        return ("pipeline stopped — click to restart", true)
    }
    return nil
}

func pausedHeaderText(timeRemaining: String?) -> String {
    guard let t = timeRemaining else { return "paused" }
    let compact = t.replacingOccurrences(of: " mins", with: " min")
                   .replacingOccurrences(of: " secs", with: " sec")
                   .replacingOccurrences(of: " hrs", with: " hr")
    return "paused - \(compact) left"
}

func settingsAttentionIconName(anyTabNeedsAttention: Bool) -> String? {
    anyTabNeedsAttention ? "exclamationmark.circle.fill" : nil
}
