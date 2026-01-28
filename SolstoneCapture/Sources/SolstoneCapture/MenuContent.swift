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
            muteMenu
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
        return "Recording"
    }

    // MARK: - Mute Menus

    @ViewBuilder
    private var muteMenu: some View {
        if appState.muteManager.isMuted {
            // Reference refreshTick to trigger view updates
            let _ = appState.muteManager.refreshTick
            if let timeText = appState.muteManager.formatTimeRemaining() {
                Button("Unmute (\(timeText) remaining)") {
                    appState.muteManager.unmute()
                }
            } else {
                Button("Unmute") {
                    appState.muteManager.unmute()
                }
            }
        } else {
            Menu("Mute") {
                let now = Date()
                let nextQuarter = MuteManager.nextQuarterHour(after: now)
                let secondQuarter = MuteManager.secondQuarterHour(after: now)
                let nextHour = MuteManager.nextFullHour(after: now)
                let nextMins = Int(nextQuarter.timeIntervalSince(now) / 60)
                let secondMins = Int(secondQuarter.timeIntervalSince(now) / 60)
                let hourMins = Int(nextHour.timeIntervalSince(now) / 60)

                Button("Until \(MuteManager.formatTime(nextQuarter)) (~\(nextMins) mins)") {
                    appState.muteManager.mute(for: .until(nextQuarter))
                }
                Button("Until \(MuteManager.formatTime(secondQuarter)) (~\(secondMins) mins)") {
                    appState.muteManager.mute(for: .until(secondQuarter))
                }
                Button("Until \(MuteManager.formatTime(nextHour)) (~\(hourMins) mins)") {
                    appState.muteManager.mute(for: .until(nextHour))
                }
                Button("Until tomorrow morning") {
                    appState.muteManager.mute(for: .untilTomorrowMorning)
                }
                Button("Until unmute") {
                    appState.muteManager.mute(for: .indefinite)
                }
            }
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
            }
        }
    }
}
