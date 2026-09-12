// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore
import Testing
import UpdateKit
@testable import solstone

@Suite("Update notification permissions", .serialized)
@MainActor
struct UpdateNotificationPermissionsTests {
    @Test func permissionsAttentionWithoutUpdateDoesNotAnnounce() {
        // Screen is the only source the owner wants, and macOS has not granted it — so there
        // is no usable source and permissions genuinely need attention. Spelling the microphone
        // out matters: it is on by default, and a granted second source would make this state
        // an honest "running on the microphone" instead.
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: false)
        )
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.notGranted)
        state.microphoneAuthorizationCause = .authorized
        var announcements: [String] = []
        let controller = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger(subsystem: "app.solstone.tests", category: "updates"),
            errorDomain: "app.solstone.tests.updates",
            announce: { version in announcements.append(version) }
        ) { _, _ in nil }

        // Permission attention is AppState presentation, not DurableUpdateStatus;
        // the UpdateKit announcement input for permissions-only attention is idle.
        let presentation = state.menubarPresentation(durableUpdateStatus: controller.durableUpdateStatus)
        #expect(presentation.observation == .permissions)
        #expect(presentation.attention == .permissions)

        controller.evaluatePendingUpdateAnnouncement()

        #expect(announcements.isEmpty)
    }
}
