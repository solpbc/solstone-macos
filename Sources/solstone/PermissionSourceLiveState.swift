// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI

enum PermissionSourcePauseReason: Equatable, Sendable {
    case owner
    case protectedVideo
}

enum PermissionSourceLiveState: Equatable, Sendable {
    case on
    case paused(PermissionSourcePauseReason)
    case off
    case notRunning

    var axState: PermissionSourceLiveAXState {
        switch self {
        case .on:
            return .on
        case .paused:
            return .paused
        case .off:
            return .off
        case .notRunning:
            return .notRunning
        }
    }
}

enum PermissionSourceLiveAXState: CaseIterable, Equatable, Sendable {
    case on, paused, off, notRunning

    var axToken: String {
        switch self {
        case .on:
            return "on"
        case .paused:
            return "paused"
        case .off:
            return "off"
        case .notRunning:
            return "not_running"
        }
    }
}

func permissionSourceLiveState(
    source: CaptureSources,
    isRecording: Bool,
    mediaPaused: Bool,
    activeSources: CaptureSources,
    selectedSources: CaptureSources,
    ownerPauseHeldIdle: Bool,
    protectedVideoHeld: Bool
) -> PermissionSourceLiveState {
    if isRecording && !mediaPaused && activeSources.contains(source) {
        return .on
    }
    if selectedSources.contains(source) && ((mediaPaused && activeSources.contains(source)) || ownerPauseHeldIdle || protectedVideoHeld) {
        return .paused(protectedVideoHeld ? .protectedVideo : .owner)
    }
    if !selectedSources.contains(source) {
        return .off
    }
    return .notRunning
}

struct PermissionSourceLiveControls: Equatable, Sendable {
    var pause: Bool
    var resume: Bool
    var openSources: Bool
    var checkStatus: Bool
}

func permissionSourceLiveControls(
    state: PermissionSourceLiveState,
    isUserPaused: Bool,
    ownerPauseHeldIdle: Bool
) -> PermissionSourceLiveControls {
    let pause = state == .on
    let resume: Bool
    if case .paused = state {
        resume = isUserPaused || ownerPauseHeldIdle
    } else {
        resume = false
    }
    let openSources = state == .off
    let checkStatus = state == .notRunning
    return PermissionSourceLiveControls(
        pause: pause,
        resume: resume,
        openSources: openSources,
        checkStatus: checkStatus
    )
}

func microphoneLevelDecibels(peak: Float) -> Float {
    20 * log10(max(peak, Float(1e-6)))
}

private let microphoneLevelThresholds: [Float] = [-50, -40, -30, -20, -10]

func microphoneLevelLitBarCount(decibels: Float?) -> Int {
    guard let decibels else { return 0 }
    return microphoneLevelThresholds.reduce(0) { count, threshold in
        decibels >= threshold ? count + 1 : count
    }
}

struct MicrophoneLevelMeter: View {
    let peak: Float?

    private static let barHeights: [CGFloat] = [4, 6, 8, 10, 12]

    var body: some View {
        let decibels = peak.map(microphoneLevelDecibels(peak:))
        let litCount = microphoneLevelLitBarCount(decibels: decibels)

        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Rectangle()
                    .fill(index < litCount ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: Self.barHeights[index])
            }
        }
        .accessibilityHidden(true)
    }
}

extension AppState {
    func permissionSourceLiveState(for source: CaptureSources) -> PermissionSourceLiveState {
        solstone.permissionSourceLiveState(
            source: source,
            isRecording: isRecording,
            mediaPaused: capture.isPaused,
            activeSources: captureManager.activeSources,
            selectedSources: config.selectedSources,
            ownerPauseHeldIdle: ownerPauseHeldIdle,
            protectedVideoHeld: protectedVideoHeld
        )
    }

    func permissionSourceLiveControls(for source: CaptureSources) -> PermissionSourceLiveControls {
        solstone.permissionSourceLiveControls(
            state: permissionSourceLiveState(for: source),
            isUserPaused: capture.isUserPaused,
            ownerPauseHeldIdle: ownerPauseHeldIdle
        )
    }
}
