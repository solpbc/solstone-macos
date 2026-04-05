// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import AVFoundation
import ScreenCaptureKit

/// Checks macOS permissions required for capture.
/// Does not batch-request — callers trigger each permission individually.
struct PermissionChecker {
    private static let tccEntryCreatedKey = "screenRecordingTCCEntryCreated"

    var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var allGranted: Bool {
        screenRecordingGranted && microphoneGranted
    }

    /// Ensures the app appears in the System Settings screen recording list,
    /// then opens System Settings. On first call ever, uses CGRequestScreenCaptureAccess
    /// to create the TCC entry (which shows an OS dialog). On subsequent calls,
    /// opens System Settings directly via deep link since the entry already exists.
    func promptScreenRecording() {
        if UserDefaults.standard.bool(forKey: Self.tccEntryCreatedKey) {
            openScreenRecordingSettings()
        } else {
            CGRequestScreenCaptureAccess()
            UserDefaults.standard.set(true, forKey: Self.tccEntryCreatedKey)
        }
    }

    /// Shows the native microphone permission dialog. Returns when the user responds.
    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
