// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
import UserNotifications
@testable import solstone

@Suite("Update notification routing")
struct UpdateNotificationRoutingTests {
    @Test func identifierDestinationRoutesUpdateNamespaceWithoutAppKit() {
        let updateIdentifier = UpdateNotificationIdentifier.make(version: "1.3.9")

        #expect(userNotificationClickDestination(for: updateIdentifier) == .updatesSettings)
        #expect(userNotificationClickDestination(for: "req-1") == .solChat(requestID: "req-1"))
    }

    @Test func willPresentOptionsRouteUpdateAndSolChatIdentifiers() {
        #expect(userNotificationPresentationOptions(
            for: UpdateNotificationIdentifier.make(version: "1.3.9")
        ) == [.list])
        #expect(userNotificationPresentationOptions(for: "req-1") == [.banner, .list, .sound])
    }
}
