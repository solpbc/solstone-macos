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
                Button("stop recording") {
                    Task {
                        await appState.stopRecording()
                    }
                }
            } else if appState.errorMessage == nil {
                Button("start recording") {
                    Task {
                        await appState.startRecording()
                    }
                }
            }
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
            Button("About solstone...") {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()

        Button("Quit solstone") {
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
            Button("screen recording blocked — open privacy settings →") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .foregroundStyle(.red)
        } else {
            Text(recordingStatusText)
        }
    }

    private var recordingStatusText: String {
        if appState.isPaused {
            return "paused"
        }
        if !appState.isRecording {
            return "not recording"
        }
        return "recording"
    }

    // MARK: - Mute Menus

    @ViewBuilder
    private var muteMenu: some View {
        if appState.isRecording {
            if appState.muteManager.isMuted {
                // Reference refreshTick to trigger view updates
                let _ = appState.muteManager.refreshTick
                if let timeText = appState.muteManager.formatTimeRemaining() {
                    Button("unmute (\(timeText) remaining)") {
                        appState.muteManager.unmute()
                    }
                } else {
                    Button("unmute") {
                        appState.muteManager.unmute()
                    }
                }
            } else {
                Menu("mute") {
                    let now = Date()
                    let nextQuarter = MuteManager.nextQuarterHour(after: now)
                    let secondQuarter = MuteManager.secondQuarterHour(after: now)
                    let nextHour = MuteManager.nextFullHour(after: now)

                    Button("mute for 15 minutes (until \(MuteManager.formatTime(nextQuarter)))") {
                        appState.muteManager.mute(for: .until(nextQuarter))
                    }
                    Button("mute for 30 minutes (until \(MuteManager.formatTime(secondQuarter)))") {
                        appState.muteManager.mute(for: .until(secondQuarter))
                    }
                    Button("mute for 1 hour (until \(MuteManager.formatTime(nextHour)))") {
                        appState.muteManager.mute(for: .until(nextHour))
                    }
                    Button("until tomorrow morning") {
                        appState.muteManager.mute(for: .untilTomorrowMorning)
                    }
                    Button("indefinitely") {
                        appState.muteManager.mute(for: .indefinite)
                    }
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
