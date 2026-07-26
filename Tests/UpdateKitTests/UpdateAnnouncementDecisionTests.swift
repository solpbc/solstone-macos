// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import UpdateKit

@Suite("UpdateAnnouncement")
struct UpdateAnnouncementDecisionTests {
    @Test func availableAndStagedReturnUnannouncedVersion() {
        #expect(updateAnnouncementVersion(
            for: .available(version: "1.3.9", releaseNotes: nil),
            lastAnnounced: nil
        ) == "1.3.9")
        #expect(updateAnnouncementVersion(
            for: .staged(version: "1.3.9", releaseNotes: nil),
            lastAnnounced: nil
        ) == "1.3.9")
    }

    @Test func alreadyAnnouncedVersionReturnsNil() {
        #expect(updateAnnouncementVersion(
            for: .available(version: "1.3.9", releaseNotes: nil),
            lastAnnounced: "1.3.9"
        ) == nil)
        #expect(updateAnnouncementVersion(
            for: .staged(version: "1.3.9", releaseNotes: nil),
            lastAnnounced: "1.3.9"
        ) == nil)
    }

    @Test func nonAvailableStatusesDoNotAnnounce() {
        #expect(updateAnnouncementVersion(for: .failedWithAvailable(version: "1.3.9"), lastAnnounced: nil) == nil)
        #expect(updateAnnouncementVersion(for: .deferred(version: "1.3.9"), lastAnnounced: nil) == nil)
        #expect(updateAnnouncementVersion(for: .failed, lastAnnounced: nil) == nil)
        #expect(updateAnnouncementVersion(for: .upToDate, lastAnnounced: nil) == nil)
        #expect(updateAnnouncementVersion(for: .idle, lastAnnounced: nil) == nil)
    }
}
