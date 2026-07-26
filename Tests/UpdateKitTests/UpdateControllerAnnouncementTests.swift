// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import UpdateKit

@Suite("UpdateController announcements", .serialized)
@MainActor
struct UpdateControllerAnnouncementTests {
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="

    @Test func foundUpdateAnnouncesOnceAcrossFreshControllerWithSameDefaults() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        var announcements: [String] = []

        let first = makeController(defaults: isolated.defaults) { version in
            announcements.append(version)
        }
        first.ingestFoundUpdate(version: "1.3.9", releaseNotes: nil)

        let second = makeController(defaults: isolated.defaults) { version in
            announcements.append(version)
        }
        second.ingestFoundUpdate(version: "1.3.9", releaseNotes: nil)

        #expect(announcements == ["1.3.9"])
    }

    @Test func newerFoundVersionAnnouncesAfterEarlierVersionWasRecorded() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        var announcements: [String] = []

        let controller = makeController(defaults: isolated.defaults) { version in
            announcements.append(version)
        }
        controller.ingestFoundUpdate(version: "1.3.9", releaseNotes: nil)
        controller.ingestFoundUpdate(version: "1.4.0", releaseNotes: nil)

        #expect(announcements == ["1.3.9", "1.4.0"])
    }

    @Test func foundThenStagedSameVersionAnnouncesOnlyOnce() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        var announcements: [String] = []

        let controller = makeController(defaults: isolated.defaults) { version in
            announcements.append(version)
        }
        controller.ingestFoundUpdate(version: "1.3.9", releaseNotes: nil)
        controller.ingestStagedUpdate(version: "1.3.9")

        #expect(announcements == ["1.3.9"])
    }

    @Test func versionRestoredAtLaunchAnnouncesOnceWhenEvaluated() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        var announcements: [String] = []

        let persisting = makeController(defaults: isolated.defaults)
        persisting.ingestFoundUpdate(version: "1.3.9", releaseNotes: nil)

        let restored = makeController(defaults: isolated.defaults) { version in
            announcements.append(version)
        }
        restored.evaluatePendingUpdateAnnouncement()

        let restoredAgain = makeController(defaults: isolated.defaults) { version in
            announcements.append(version)
        }
        restoredAgain.evaluatePendingUpdateAnnouncement()

        #expect(announcements == ["1.3.9"])
    }

    private func makeController(
        defaults: UserDefaults,
        announce: (@MainActor (String) -> Void)? = nil
    ) -> UpdateController {
        let spy = SpyUpdater()
        return UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            announce: announce,
            defaults: defaults
        ) { _, _ in spy }
    }
}
