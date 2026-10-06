// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("IngestProtocolV3 decoder")
struct IngestProtocolV3DecoderTests {
    @Test func collisionItemsMayShareOriginalKeyAcrossDistinctStreams() throws {
        let data = Data(#"{"protocol_version":3,"total":2,"items":[{"key":"12~a","original_key":"12","segment":"12","stream":"browser-a","files":[{"name":"browser_pages.jsonl","size":7,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"present"}]},{"key":"13~b","original_key":"12","segment":"13","stream":"browser-b","files":[{"name":"browser_pages.jsonl","size":7,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","status":"processed"}]}]}"#.utf8)

        let decoded = try JSONDecoder().decode(IngestProtocolV3.SegmentsDay.self, from: data)

        #expect(decoded.total == 2)
        #expect(decoded.items.map(\.key) == ["12~a", "13~b"])
        #expect(decoded.items.map(\.stream) == ["browser-a", "browser-b"])
    }

    @Test func segmentsDayRejectsFalseTotalsDuplicateKeysAndMalformedCoordinates() {
        let validFile = #"{"name":"browser_pages.jsonl","size":7,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"present"}"#
        let fixtures = [
            #"{"protocol_version":3,"total":2,"items":[]}"#,
            #"{"protocol_version":3,"total":2,"items":[{"key":"same","files":["# + validFile + #"]},{"key":"same","files":["# + validFile + #"]}]}"#,
            #"{"protocol_version":3,"total":1,"items":[{"key":"one","segment":"12","files":["# + validFile + #"]}]}"#,
            #"{"protocol_version":3,"total":1,"items":[{"key":"one","segment":null,"stream":null,"files":["# + validFile + #"]}]}"#,
            #"{"protocol_version":3,"total":1,"items":[{"key":"one","segment":"","stream":"a","files":["# + validFile + #"]}]}"#,
            #"{"protocol_version":3,"total":2,"items":[{"key":"a","original_key":"12","segment":"12","stream":"one","files":["# + validFile + #"]},{"key":"b","original_key":"12","segment":"12","stream":"one","files":["# + validFile + #"]}]}"#
        ]

        for fixture in fixtures {
            #expect(throws: UploadError.invalidResponse) {
                try JSONDecoder().decode(IngestProtocolV3.SegmentsDay.self, from: Data(fixture.utf8))
            }
        }
    }

    @Test func dayManifestRequiresFilesOnlyForEachSegmentValue() throws {
        let valid = Data(#"{"version":1,"day":"20260815","segments":{"143000":{"files":[{"name":"audio.m4a","size":4096,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"present"}]}}}"#.utf8)
        let decoded = try JSONDecoder().decode(IngestProtocolV3.DayManifest.self, from: valid)
        #expect(decoded.day == "20260815")
        #expect(decoded.segments["143000"]?.files.count == 1)

        let extraSegmentField = Data(#"{"version":1,"day":"20260815","segments":{"143000":{"files":[],"stream":"audio"}}}"#.utf8)
        #expect(throws: UploadError.invalidResponse) {
            try JSONDecoder().decode(IngestProtocolV3.DayManifest.self, from: extraSegmentField)
        }
    }
}
