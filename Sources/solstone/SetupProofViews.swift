// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI

struct SetupProofDecision: Equatable {
    let title: String
    let kind: SetupProofKind
    let reason: String?
    let hint: String?
    let showMeter: Bool
    let isMeterPaused: Bool
    let showPauseMenu: Bool
    let showResume: Bool
    let showCheckStatus: Bool
    let showOffButtons: Bool
}

enum SetupProofDecisionResolver {
    static func resolve(
        source: CaptureSources,
        liveState: PermissionSourceLiveState,
        controls: PermissionSourceLiveControls,
        timeRemaining: String? = nil,
        activityKeptOn: Bool = false
    ) -> SetupProofDecision {
        let isScreen = source.contains(.screen)
        switch liveState {
        case .on:
            return SetupProofDecision(
                title: isScreen ? UICopy.SETUP_SCREEN_STATUS_ON : UICopy.SETUP_MICROPHONE_STATUS_ON,
                kind: .on,
                reason: nil,
                hint: UICopy.SETTINGS_PERMISSIONS_LIVE_ON_HINT,
                showMeter: !isScreen,
                isMeterPaused: false,
                showPauseMenu: controls.pause,
                showResume: false,
                showCheckStatus: false,
                showOffButtons: false
            )
        case .paused(let cause):
            let reason: String
            switch cause {
            case .owner:
                reason = pausedHeaderText(timeRemaining: timeRemaining)
            case .protectedVideo:
                reason = UICopy.SETTINGS_OBSERVATION_PROTECTED_VIDEO
            }
            return SetupProofDecision(
                title: isScreen ? UICopy.SETUP_SCREEN_STATUS_PAUSED : UICopy.SETUP_MICROPHONE_STATUS_PAUSED,
                kind: .paused,
                reason: reason,
                hint: UICopy.pausedHint(activityKeptOn: activityKeptOn),
                showMeter: !isScreen,
                isMeterPaused: true,
                showPauseMenu: false,
                showResume: controls.resume,
                showCheckStatus: false,
                showOffButtons: false
            )
        case .notRunning:
            return SetupProofDecision(
                title: UICopy.SETTINGS_PERMISSIONS_LIVE_NOT_RUNNING,
                kind: .notRunning,
                reason: nil,
                hint: nil,
                showMeter: false,
                isMeterPaused: false,
                showPauseMenu: false,
                showResume: false,
                showCheckStatus: controls.checkStatus,
                showOffButtons: false
            )
        case .off:
            return SetupProofDecision(
                title: isScreen ? UICopy.SETUP_SCREEN_STATUS_OFF : UICopy.SETUP_MICROPHONE_STATUS_OFF,
                kind: .off,
                reason: nil,
                hint: nil,
                showMeter: false,
                isMeterPaused: false,
                showPauseMenu: false,
                showResume: false,
                showCheckStatus: false,
                showOffButtons: true
            )
        }
    }
}

struct SetupMicrophoneProofView: View {
    @Environment(\.colorScheme) private var colorScheme
    let appState: AppState
    let model: SetupModel
    var onCheckStatus: (() -> Void)? = nil

    var body: some View {
        let isRepair = appState.config.isMicrophoneCaptureEnabled && !appState.microphoneGranted
        if isRepair {
            MicrophonePermissionRepairView(
                cause: appState.microphoneAuthorizationCause,
                onRequestAccess: {
                    model.turnOnMicrophone()
                }
            )
        } else {
            let liveState = appState.permissionSourceLiveState(for: .microphone)
            let controls = appState.permissionSourceLiveControls(for: .microphone)
            let decision = SetupProofDecisionResolver.resolve(
                source: .microphone,
                liveState: liveState,
                controls: controls,
                timeRemaining: { _ = appState.pauseManager.refreshTick; return appState.pauseManager.formatTimeRemaining() }(),
                activityKeptOn: appState.config.isActivityKeptOnThroughPause
            )

            VStack(alignment: .leading, spacing: 12) {
                AXStateCompanion(
                    id: AXID.Settings.Permissions.microphoneLiveState,
                    value: liveState.axState.axToken
                )

                SetupProofLine(kind: decision.kind, title: decision.title) {
                    trailingControls(decision: decision)
                }

                if decision.showMeter {
                    SetupLevelMeter(
                        peak: { appState.microphoneInputPeak },
                        paused: decision.isMeterPaused
                    )
                }

                if let reason = decision.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                }

                if let hint = decision.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                }

                if !appState.config.isMicrophoneCaptureEnabled {
                    HStack(spacing: 8) {
                        Button(UICopy.SETUP_TURN_ON_MICROPHONE) {
                            model.turnOnMicrophone()
                        }
                        .buttonStyle(SetupPrimaryButtonStyle())
                        .accessibilityIdentifier(AXID.Settings.Setup.Microphone.turnOn)

                        Button(UICopy.SETUP_NOT_NOW) {
                            model.notNowMicrophone()
                        }
                        .buttonStyle(SetupTextButtonStyle())
                        .accessibilityIdentifier(AXID.Settings.Setup.Microphone.notNow)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trailingControls(decision: SetupProofDecision) -> some View {
        if decision.showPauseMenu {
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
            .accessibilityIdentifier(AXID.Settings.Permissions.microphonePause)
        } else if decision.showResume {
            Button("resume") {
                appState.pauseManager.resume()
            }
            .accessibilityIdentifier(AXID.Settings.Permissions.microphoneResume)
        } else if decision.showCheckStatus, let onCheckStatus {
            Button(UICopy.SETTINGS_PERMISSIONS_CHECK_STATUS) {
                onCheckStatus()
            }
            .accessibilityIdentifier(AXID.Settings.Permissions.microphoneCheckStatus)
        }
    }
}

struct SetupScreenProofView: View {
    @Environment(\.colorScheme) private var colorScheme
    let appState: AppState
    let model: SetupModel
    var onCheckStatus: (() -> Void)? = nil

    var body: some View {
        let isRepair = appState.config.isScreenCaptureEnabled && !appState.screenRecordingGranted
        VStack(alignment: .leading, spacing: 14) {
            if isRepair {
                ScreenRecordingPermissionRepairView(
                    isWaiting: appState.capture.screenRecordingNeedsRestart,
                    showResetHint: false,
                    onEnable: {
                        model.turnOnScreen()
                    },
                    onRestart: {
                        model.prepareScreenRestart(requestRestart: {
                            appState.appQuitCoordinator.requestSettingsRestart()
                        })
                    }
                )
            } else {
                let liveState = appState.permissionSourceLiveState(for: .screen)
                let controls = appState.permissionSourceLiveControls(for: .screen)
                let decision = SetupProofDecisionResolver.resolve(
                    source: .screen,
                    liveState: liveState,
                    controls: controls,
                    timeRemaining: { _ = appState.pauseManager.refreshTick; return appState.pauseManager.formatTimeRemaining() }(),
                    activityKeptOn: appState.config.isActivityKeptOnThroughPause
                )

                AXStateCompanion(
                    id: AXID.Settings.Permissions.screenRecordingLiveState,
                    value: liveState.axState.axToken
                )

                SetupProofLine(kind: decision.kind, title: decision.title) {
                    trailingControls(decision: decision)
                }

                if let reason = decision.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                }

                if let hint = decision.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                }

                if !appState.config.isScreenCaptureEnabled {
                    HStack(spacing: 8) {
                        Button(UICopy.SETUP_TURN_ON_SCREEN) {
                            model.turnOnScreen()
                        }
                        .buttonStyle(SetupPrimaryButtonStyle())
                        .accessibilityIdentifier(AXID.Settings.Setup.Screen.turnOn)

                        Button(UICopy.SETUP_NOT_NOW) {
                            model.notNowScreen()
                        }
                        .buttonStyle(SetupTextButtonStyle())
                        .accessibilityIdentifier(AXID.Settings.Setup.Screen.notNow)
                    }
                }
            }

            // Screen frame: shown for every screen-step state, including off and repair
            let hasLiveFrame = appState.latestFrame != nil
            AXStateCompanion(
                id: AXID.Settings.Setup.Screen.frame,
                value: hasLiveFrame ? SetupScreenFrameAXState.live.rawValue : SetupScreenFrameAXState.off.rawValue
            )

            let frameImage: NSImage? = appState.latestFrame.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }

            SetupScreenFrame(
                image: frameImage,
                placeholder: UICopy.SETUP_SCREEN_SHOWS_HERE,
                caption: UICopy.SETUP_SCREEN_FRAME_CAPTION,
                accessibilityIdentifier: AXID.Settings.Setup.Screen.frame,
                accessibilityValue: hasLiveFrame ? SetupScreenFrameAXState.live.rawValue : SetupScreenFrameAXState.off.rawValue
            )
        }
    }

    @ViewBuilder
    private func trailingControls(decision: SetupProofDecision) -> some View {
        if decision.showPauseMenu {
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
            .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingPause)
        } else if decision.showResume {
            Button("resume") {
                appState.pauseManager.resume()
            }
            .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingResume)
        } else if decision.showCheckStatus, let onCheckStatus {
            Button(UICopy.SETTINGS_PERMISSIONS_CHECK_STATUS) {
                onCheckStatus()
            }
            .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingCheckStatus)
        }
    }
}
