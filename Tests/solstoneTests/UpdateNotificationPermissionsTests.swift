// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import Testing
import UpdateKit
@testable import solstone

@Suite("Update notification permissions", .serialized)
@MainActor
struct UpdateNotificationPermissionsTests {
    @Test func permissionsAttentionWithoutUpdateDoesNotAnnounce() {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.screenRecordingGranted = false
        state.microphoneGranted = true
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
