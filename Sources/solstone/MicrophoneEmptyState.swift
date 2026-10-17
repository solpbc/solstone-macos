// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Classification for empty microphone list in settings.
internal enum MicrophoneEmptyState: Equatable, Sendable {
    case access(MicrophoneAuthorizationCause)
    case connect
    case couldNotCheck

    static let soundSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
}

/// Pure classification function for microphone empty state.
internal func classifyMicrophoneEmptyState(
    authorizationCause: MicrophoneAuthorizationCause
) -> MicrophoneEmptyState {
    switch authorizationCause {
    case .denied, .restricted, .notDetermined:
        return .access(authorizationCause)
    case .authorized:
        return .connect
    case .unknown:
        return .couldNotCheck
    }
}

/// Reconciles priority list if devices are connected, then returns the empty state classification if the list remains empty.
internal func reconcileAndClassifyMicrophoneEmptyState(
    isPriorityListEmpty: () -> Bool,
    deviceCount: Int,
    authorizationCause: MicrophoneAuthorizationCause,
    syncMicrophonePriorityList: () -> Void
) -> MicrophoneEmptyState? {
    guard isPriorityListEmpty() else { return nil }
    if deviceCount > 0 {
        syncMicrophonePriorityList()
    }
    guard isPriorityListEmpty() else { return nil }
    return classifyMicrophoneEmptyState(authorizationCause: authorizationCause)
}
