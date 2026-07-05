// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalMarkKit

@Suite("JournalMark")
struct JournalMarkTests {
    @Test func decodeAndValidateAcceptsSample() throws {
        let mark = try #require(Self.decodeAndValidate(Self.sampleData()))

        #expect(mark.icon1.name == "bug")
        #expect(mark.icon2.name == "gem")
        #expect(mark.icon1.rot == 0)
        #expect(mark.icon2.rot == 45)
        #expect(mark.words == ["afoot", "unfixed"])
    }

    @Test func encodeDecodeRoundTripPreservesValidatedMark() throws {
        let encoded = try JSONEncoder().encode(JournalMark.uiTestSample)
        let decoded = try JSONDecoder().decode(JournalMark.self, from: encoded)

        #expect(decoded == JournalMark.uiTestSample)
        #expect(JournalMark.validate(decoded) == JournalMark.uiTestSample)
    }

    @Test func decodeAndValidateReturnsNilForOneIcon() {
        #expect(Self.decodeAndValidate(Self.sampleData(includeIcon2: false)) == nil)
    }

    @Test func validateRejectsThreeWords() {
        #expect(Self.decodeAndValidate(Self.sampleData(words: ["afoot", "unfixed", "extra"])) == nil)
    }

    @Test func validateRejectsMissingHashHex() {
        #expect(Self.decodeAndValidate(Self.sampleData(icon1Color: "f59e0b")) == nil)
    }

    @Test func validateRejectsShortHex() {
        #expect(Self.decodeAndValidate(Self.sampleData(icon1Color: "#f59e0")) == nil)
    }

    @Test func validateRejectsRotNinety() {
        #expect(Self.decodeAndValidate(Self.sampleData(icon2Rot: 90)) == nil)
    }

    @Test func validateRejectsRotNegativeFortyFive() {
        #expect(Self.decodeAndValidate(Self.sampleData(icon2Rot: -45)) == nil)
    }

    @Test func validateRejectsEmptySVG() {
        #expect(Self.decodeAndValidate(Self.sampleData(icon1SVG: "")) == nil)
    }

    @Test func validateRejectsUnsupportedGlyphCommand() {
        #expect(Self.decodeAndValidate(Self.sampleData(icon1SVG: #"<path d="M0 0 R1 1" />"#)) == nil)
    }

    static func decodeAndValidate(_ data: Data) -> JournalMark? {
        guard let decoded = try? JSONDecoder().decode(JournalMark.self, from: data) else {
            return nil
        }
        return JournalMark.validate(decoded)
    }

    static func sampleData(
        includeIcon2: Bool = true,
        icon1Color: String = "#f59e0b",
        icon1SVG: String = JournalMark.uiTestSample.icon1.svg,
        icon2Rot: Int = 45,
        words: [String] = ["afoot", "unfixed"]
    ) -> Data {
        var root: [String: Any] = [
            "icon1": [
                "name": "bug",
                "color": ["hex": icon1Color],
                "rot": 0,
                "svg": icon1SVG,
            ],
            "words": words,
        ]
        if includeIcon2 {
            root["icon2"] = [
                "name": "gem",
                "color": ["hex": "#84cc16"],
                "rot": icon2Rot,
                "svg": JournalMark.uiTestSample.icon2.svg,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }
}
