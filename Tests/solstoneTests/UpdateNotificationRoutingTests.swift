// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
import UserNotifications
@testable import solstone

@Suite("Update notification routing")
struct UpdateNotificationRoutingTests {
    @Test func identifierDestinationRoutesUpdateNamespaceWithoutAppKit() {
        let updateIdentifier = UpdateNotificationIdentifier.make(version: "1.3.9")

        #expect(UpdateNotificationIdentifier.isUpdateNotification(updateIdentifier))
        #expect(!UpdateNotificationIdentifier.isUpdateNotification("req-1"))
    }

    @Test func willPresentOptionsRouteUpdateAndOtherIdentifiers() {
        #expect(userNotificationPresentationOptions(
            for: UpdateNotificationIdentifier.make(version: "1.3.9")
        ) == [.list])
        #expect(userNotificationPresentationOptions(for: "req-1") == [])
    }
}
