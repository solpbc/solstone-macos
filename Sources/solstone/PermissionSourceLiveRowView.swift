// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI
import SolstoneCore

struct PermissionSourceLiveRowView: View {
    let source: CaptureSources
    let appState: AppState
    var showOffHint: Bool = true
    var onOpenSources: (() -> Void)? = nil
    var onCheckStatus: (() -> Void)? = nil

    var body: some View {
        let liveState = appState.permissionSourceLiveState(for: source)
        let controls = appState.permissionSourceLiveControls(for: source)
        let isScreen = source.contains(.screen)
        let liveStateAXID = isScreen ? AXID.Settings.Permissions.screenRecordingLiveState : AXID.Settings.Permissions.microphoneLiveState
        let pauseAXID = isScreen ? AXID.Settings.Permissions.screenRecordingPause : AXID.Settings.Permissions.microphonePause
        let resumeAXID = isScreen ? AXID.Settings.Permissions.screenRecordingResume : AXID.Settings.Permissions.microphoneResume
        let openSourcesAXID = isScreen ? AXID.Settings.Permissions.screenRecordingOpenSources : AXID.Settings.Permissions.microphoneOpenSources
        let checkStatusAXID = isScreen ? AXID.Settings.Permissions.screenRecordingCheckStatus : AXID.Settings.Permissions.microphoneCheckStatus

        AXStateCompanion(id: liveStateAXID, value: liveState.axState.axToken)

        HStack(spacing: 6) {
            if liveState == .on {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                Text(UICopy.SETTINGS_PERMISSIONS_LIVE_ON)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                switch liveState {
                case .on:
                    EmptyView()
                case .paused(.owner):
                    let _ = appState.pauseManager.refreshTick
                    Text(pausedHeaderText(timeRemaining: appState.pauseManager.formatTimeRemaining()))
                case .paused(.protectedVideo):
                    Text(UICopy.SETTINGS_OBSERVATION_PROTECTED_VIDEO)
                case .off:
                    Text(UICopy.SETTINGS_PERMISSIONS_LIVE_OFF)
                case .notRunning:
                    Text(UICopy.SETTINGS_PERMISSIONS_LIVE_NOT_RUNNING)
                }
            }

            if !isScreen, liveState == .on {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    MicrophoneLevelMeter(peak: appState.microphoneInputPeak)
                }
            }

            Spacer()

            if controls.pause {
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
                .fixedSize()
                .accessibilityIdentifier(pauseAXID)
            } else if controls.resume {
                Button("resume") {
                    appState.pauseManager.resume()
                }
                .accessibilityIdentifier(resumeAXID)
            } else if controls.openSources {
                if let onOpenSources {
                    Button(UICopy.SOURCES_OPEN_ACTION) {
                        onOpenSources()
                    }
                    .accessibilityIdentifier(openSourcesAXID)
                }
            } else if controls.checkStatus {
                if let onCheckStatus {
                    Button(UICopy.SETTINGS_PERMISSIONS_CHECK_STATUS) {
                        onCheckStatus()
                    }
                    .accessibilityIdentifier(checkStatusAXID)
                }
            }
        }

        switch liveState {
        case .on:
            Text(UICopy.SETTINGS_PERMISSIONS_LIVE_ON_HINT)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .paused:
            Text(UICopy.pausedHint(activityKeptOn: appState.config.isActivityKeptOnThroughPause))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .off:
            if showOffHint {
                Text(UICopy.SETTINGS_PERMISSIONS_LIVE_OFF_HINT)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notRunning:
            EmptyView()
        }
    }
}

struct MicrophonePermissionRepairView: View {
    let cause: MicrophoneAuthorizationCause
    let onRequestAccess: () -> Void

    var body: some View {
        HStack {
            Spacer()
            switch cause {
            case .authorized:
                EmptyView()
            case .denied:
                microphoneSettingsButton(message: UICopy.SETTINGS_PERMISSIONS_MIC_DENIED)
            case .restricted:
                microphoneSettingsButton(message: UICopy.SETTINGS_PERMISSIONS_MIC_RESTRICTED)
            case .notDetermined:
                Button(UICopy.SETTINGS_PERMISSIONS_ENABLE_MICROPHONE) {
                    onRequestAccess()
                }
                .accessibilityIdentifier(AXID.Settings.Permissions.microphoneGrantAccess)
            case .unknown:
                microphoneSettingsButton(message: UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK)
            }
        }
    }

    private func microphoneSettingsButton(message: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(UICopy.SETTINGS_PERMISSIONS_OPEN_SYSTEM_SETTINGS) {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                )
            }
            .accessibilityIdentifier(AXID.Settings.Permissions.microphoneGrantAccess)
        }
    }
}

struct ScreenRecordingPermissionRepairView: View {
    let isWaiting: Bool
    let showResetHint: Bool
    let onEnable: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UICopy.SETTINGS_PERMISSIONS_SCREEN_EXPLAINER)
                .font(.body)
                .foregroundStyle(.secondary)
            if showResetHint {
                Text(UICopy.SETTINGS_PERMISSIONS_SCREEN_RECORDING_RESET_HINT)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingResetHint)
            }
            HStack {
                if isWaiting {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(UICopy.SETTINGS_PERMISSIONS_SCREEN_WAITING)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        HStack {
                            Button(UICopy.SETTINGS_PERMISSIONS_OPEN_SYSTEM_SETTINGS) {
                                PermissionChecker().promptScreenRecording()
                                NSWorkspace.shared.open(
                                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                                )
                            }
                            .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingOpenSystemSettings)
                            Button(UICopy.SETTINGS_PERMISSIONS_SCREEN_REOPEN) {
                                onRestart()
                            }
                            .buttonStyle(.link)
                            .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingReopen)
                        }
                    }
                } else {
                    Spacer()
                    Button(UICopy.SETTINGS_PERMISSIONS_ENABLE_SCREEN_RECORDING) {
                        onEnable()
                    }
                    .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingEnable)
                }
            }
        }
    }
}
