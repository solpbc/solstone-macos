// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import AVFoundation
import ScreenCaptureKit
import os

/// Checks macOS permissions required for capture.
/// Does not batch-request — callers trigger each permission individually.
struct PermissionChecker {
    var screenRecordingGranted: Bool {
        let result = CGPreflightScreenCaptureAccess()
        Logger.setup.info("[Permissions] CGPreflightScreenCaptureAccess() = \(result, privacy: .public)")
        return result
    }

    var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var allGranted: Bool {
        screenRecordingGranted && microphoneGranted
    }

    /// Creates TCC entry and shows OS dialog pointing user to System Settings.
    func promptScreenRecording() {
        Logger.setup.warning("[Permissions] promptScreenRecording: calling CGRequestScreenCaptureAccess()")
        CGRequestScreenCaptureAccess()
    }

    /// Shows the native microphone permission dialog. Returns when the user responds.
    func requestMicrophone() async {
        Logger.setup.warning("[Permissions] requestMicrophone: calling AVCaptureDevice.requestAccess")
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        Logger.setup.warning("[Permissions] requestMicrophone: returned")
    }
}
