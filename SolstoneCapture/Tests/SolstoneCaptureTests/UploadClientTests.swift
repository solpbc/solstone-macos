// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import SolstoneCapture

@Suite("UploadClient")
struct UploadClientTests {
    private let client = UploadClient()

    @Test func stripSegmentPrefixMatchesAndStrips() {
        let result = client.stripSegmentPrefix("143022_300_audio.m4a", segment: "143022_300")
        #expect(result == "audio.m4a")
    }

    @Test func stripSegmentPrefixNoMatchPassesThrough() {
        let result = client.stripSegmentPrefix("other_file.m4a", segment: "143022_300")
        #expect(result == "other_file.m4a")
    }

    @Test func stripSegmentPrefixHandlesMultiComponentSegment() {
        let result = client.stripSegmentPrefix("143022_300_display_1_screen.mp4", segment: "143022_300")
        #expect(result == "display_1_screen.mp4")
    }
}
