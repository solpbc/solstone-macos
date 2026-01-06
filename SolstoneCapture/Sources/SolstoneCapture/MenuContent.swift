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
            uploadStatusRow
        }

        Divider()

        // Mute controls
        Section {
            muteAudioMenu
            muteVideoMenu

            if appState.muteManager.isAnyMuted {
                Button("Unmute All") {
                    appState.muteManager.unmuteAll()
                }
            }
        }

        // Active mute status
        if appState.muteManager.audioMute.isMuted {
            muteStatusRow(for: .audio)
        }
        if appState.muteManager.videoMute.isMuted {
            muteStatusRow(for: .video)
        }

        Divider()

        // Recording control
        Section {
            if appState.isRecording && !appState.isPaused {
                Button("Stop Recording") {
                    Task {
                        await appState.stopRecording()
                    }
                }
            } else {
                Button("Start Recording") {
                    Task {
                        await appState.startRecording()
                    }
                }
            }
        }

        Divider()

        // Settings
        Section {
            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button("Quit Solstone Capture") {
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
        if let error = appState.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        } else {
            Text(recordingStatusText)
        }
    }

    private var recordingStatusText: String {
        if !appState.isRecording || appState.isPaused {
            return "Not Recording"
        }

        if appState.muteManager.audioMute.isMuted {
            return "Recording (video-only)"
        } else {
            return "Recording"
        }
    }

    // MARK: - Mute Menus

    @ViewBuilder
    private var muteAudioMenu: some View {
        if appState.muteManager.audioMute.isMuted {
            Button("Unmute Audio") {
                appState.muteManager.unmute(.audio)
            }
        } else {
            Menu("Mute Audio") {
                Button("15 minutes") {
                    appState.muteManager.mute(.audio, for: .minutes(15))
                }
                Button("30 minutes") {
                    appState.muteManager.mute(.audio, for: .minutes(30))
                }
                Button("1 hour") {
                    appState.muteManager.mute(.audio, for: .minutes(60))
                }
                Button("Until unmute") {
                    appState.muteManager.mute(.audio, for: .indefinite)
                }
            }
        }
    }

    @ViewBuilder
    private var muteVideoMenu: some View {
        if appState.muteManager.videoMute.isMuted {
            Button("Unmute Video") {
                appState.muteManager.unmute(.video)
            }
        } else {
            Menu("Mute Video") {
                Button("15 minutes") {
                    appState.muteManager.mute(.video, for: .minutes(15))
                }
                Button("30 minutes") {
                    appState.muteManager.mute(.video, for: .minutes(30))
                }
                Button("1 hour") {
                    appState.muteManager.mute(.video, for: .minutes(60))
                }
                Button("Until unmute") {
                    appState.muteManager.mute(.video, for: .indefinite)
                }
            }
        }
    }

    // MARK: - Mute Status Row

    @ViewBuilder
    private func muteStatusRow(for type: MuteManager.MuteType) -> some View {
        if let timeText = appState.muteManager.formatTimeRemaining(for: type) {
            let typeName = type == .audio ? "Audio" : "Video"
            Text("\(typeName) Muted (\(timeText))")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    // MARK: - Upload Status Row

    @ViewBuilder
    private var uploadStatusRow: some View {
        if appState.config.isUploadConfigured {
            if appState.config.syncPaused {
                Button("Resume Sync") {
                    var config = appState.config
                    config.syncPaused = false
                    appState.updateConfig(config)
                }
            } else {
                Button("Pause Sync") {
                    var config = appState.config
                    config.syncPaused = true
                    appState.updateConfig(config)
                }
                Text("Upload: \(uploadStatusText)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var uploadStatusText: String {
        let status = appState.uploadCoordinator.status
        let pending = appState.uploadCoordinator.pendingCount

        switch status {
        case .notSynced:
            return "Connecting..."
        case .synced:
            return pending > 0 ? "\(pending) pending" : "Synced"
        case .syncing(let checked, let total):
            return "Syncing \(checked)/\(total)"
        case .uploading(let segment):
            return "Uploading \(segment)"
        case .retrying(let segment, let attempts):
            return "Retry #\(attempts): \(segment)"
        case .offline(let error):
            return "Offline: \(error)"
        }
    }
}
