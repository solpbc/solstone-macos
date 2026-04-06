// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import AVFoundation
import ScreenCaptureKit
import os

/// Checks macOS permissions required for capture.
/// Screen recording permission is verified via SCShareableContent — pre-check APIs
/// (CGPreflightScreenCaptureAccess, CGWindowListCopyWindowInfo) are unreliable
/// on macOS 26 with ad-hoc signing.
struct PermissionChecker {
    private static let hasPromptedKey = "hasPromptedScreenRecording"

    /// Whether the user has been through the screen recording prompt flow at least once.
    /// When true, a TCC entry exists and SCShareableContent can be checked without triggering a dialog.
    var hasPromptedScreenRecording: Bool {
        UserDefaults.standard.bool(forKey: Self.hasPromptedKey)
    }

    /// Check screen recording permission via SCShareableContent.
    /// Only safe to call when a TCC entry exists (after prompting), otherwise may trigger OS dialog.
    static func checkScreenRecording() async -> Bool {
        for attempt in 1...5 {
            do {
                _ = try await SCShareableContent.current
                return true
            } catch {
                // On macOS 26, SCShareableContent can transiently fail at cold boot
                // even when permission IS granted. Retry with linear backoff.
                if attempt < 5 {
                    Logger.setup.debug("[Permissions] Screen recording check attempt \(attempt, privacy: .public) failed, retrying...")
                    try? await Task.sleep(for: .seconds(attempt))
                }
            }
        }
        return false
    }

    var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Triggers the screen recording permission prompt and records that we've prompted.
    func promptScreenRecording() {
        Logger.setup.info("[Permissions] promptScreenRecording")
        UserDefaults.standard.set(true, forKey: Self.hasPromptedKey)
        SCShareableContent.getWithCompletionHandler { _, _ in }
    }

    /// Shows the native microphone permission dialog. Returns when the user responds.
    func requestMicrophone() async {
        Logger.setup.info("[Permissions] requestMicrophone: calling AVCaptureDevice.requestAccess")
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        Logger.setup.info("[Permissions] requestMicrophone: returned")
    }
}
