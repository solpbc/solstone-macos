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
    func requestAll() async {
        if !screenRecordingGranted {
            CGRequestScreenCaptureAccess()
            // Brief pause to let the OS dialog appear and dismiss
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !microphoneGranted {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
}
