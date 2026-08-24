// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

@MainActor
internal struct ScreenRecordingPermissionProvider {
    let hasPrompted: @MainActor @Sendable () -> Bool
    let preflight: @MainActor @Sendable () -> Bool
    let checkScreenRecording: @MainActor @Sendable () async -> Bool
    let resetPromptedFlag: @MainActor @Sendable () -> Void

    static var live: Self {
        Self(
            hasPrompted: { PermissionChecker().hasPromptedScreenRecording },
            preflight: { CGPreflightScreenCaptureAccess() },
            checkScreenRecording: { await PermissionChecker.checkScreenRecording() },
            resetPromptedFlag: { PermissionChecker.resetPromptedFlag() }
        )
    }
}
