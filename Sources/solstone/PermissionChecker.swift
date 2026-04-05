// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import ScreenCaptureKit

/// Checks and requests macOS permissions required for capture
struct PermissionChecker {
    var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var allGranted: Bool {
        screenRecordingGranted && microphoneGranted
    }

    /// Request all missing permissions in sequence.
    /// Screen recording dialog must be triggered first (it's the more critical one).
    /// After requesting, polls briefly to give the user time to grant in System Settings.
    func requestAll() async {
        if !screenRecordingGranted {
            CGRequestScreenCaptureAccess()
            // Poll for up to 30 seconds — user may need to toggle in System Settings
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if screenRecordingGranted { break }
            }
        }
        if !microphoneGranted {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
}
