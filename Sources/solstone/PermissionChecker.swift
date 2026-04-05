// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import AVFoundation
import ScreenCaptureKit

/// Checks macOS permissions required for capture.
/// Does not batch-request — callers trigger each permission individually.
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

    /// Creates the TCC entry so the app appears in System Settings, and shows
    /// the OS dialog pointing the user there. This is the only way to get the
    /// app into the screen recording list.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    /// Shows the native microphone permission dialog. Returns when the user responds.
    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
}
