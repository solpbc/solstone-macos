// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import AVFoundation
import ScreenCaptureKit
import os

/// Checks macOS permissions required for capture.
/// Does not batch-request — callers trigger each permission individually.
struct PermissionChecker {
    /// Non-prompting, real-time screen recording permission check.
    /// Uses CGWindowListCopyWindowInfo — kCGWindowName is only populated when the app
    /// has screen recording permission. Never triggers a dialog, never caches.
    /// Technique from Ice, alt-tab-macos, and widely-used community patterns.
    var screenRecordingGranted: Bool {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else {
            Logger.setup.debug("[Permissions] screenRecordingGranted: CGWindowListCopyWindowInfo returned nil")
            return false
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for window in windowList {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID else { continue }
            // Skip Dock windows — they always expose names
            if let app = NSRunningApplication(processIdentifier: pid),
               app.executableURL?.lastPathComponent == "Dock" { continue }
            if window[kCGWindowName as String] as? String != nil {
                return true
            }
        }
        return false
    }

    var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Triggers the screen recording permission prompt.
    /// Uses SCShareableContent on macOS 15+ (CGRequestScreenCaptureAccess is broken).
    func promptScreenRecording() {
        Logger.setup.info("[Permissions] promptScreenRecording")
        SCShareableContent.getWithCompletionHandler { _, _ in }
    }

    /// Shows the native microphone permission dialog. Returns when the user responds.
    func requestMicrophone() async {
        Logger.setup.info("[Permissions] requestMicrophone: calling AVCaptureDevice.requestAccess")
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        Logger.setup.info("[Permissions] requestMicrophone: returned")
    }
}
