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

    @Test(arguments: [nil, "", "  "] as [String?])
    func validateRejectsAMarkWithoutItsColorName(name: String?) {
        let icon = JournalMark.uiTestSample.icon2
        let unnamed = JournalMark.Icon(
            name: icon.name,
            color: JournalMark.MarkColor(hex: icon.color.hex, name: name),
            rot: icon.rot,
            svg: icon.svg
        )
        let mark = JournalMark(icon1: JournalMark.uiTestSample.icon1, icon2: unnamed, words: JournalMark.uiTestSample.words)
        #expect(JournalMark.validate(mark) == nil)
    }

    @Test func wordsAndTheirJoinAreDrawnAsSeparateInks() {
        let words = JournalMark.uiTestSample.words
        let line = MarkGeometry.markWords(words)
        let runs = line.runs.map { (String(line[$0.range].characters), $0.swiftUI.foregroundColor) }

        #expect(runs.count == 3)
        #expect(runs[0].0 == words[0])
        #expect(runs[0].1 == MarkGeometry.wordInk)
        #expect(runs[1].1 == MarkGeometry.faintInk)
        #expect(runs[2].0 == words[1])
        #expect(runs[2].1 == MarkGeometry.wordInk)
        #expect(MarkGeometry.wordInk != MarkGeometry.faintInk)
    }

    @Test(arguments: ["#١٢٣٤٥٦", "#１２３４５６", "#⁰¹²³⁴⁵"])
    func validateRejectsNonAsciiColorDigits(color: String) {
        #expect(Self.decodeAndValidate(Self.sampleData(icon1Color: color)) == nil)
        #expect(Self.decodeAndValidate(Self.sampleData(icon1Color: "#A1b2C3")) != nil)
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
                "color": ["hex": icon1Color, "name": "amber"],
                "rot": 0,
                "svg": icon1SVG,
            ],
            "words": words,
        ]
        if includeIcon2 {
            root["icon2"] = [
                "name": "gem",
                "color": ["hex": "#84cc16", "name": "lime"],
                "rot": icon2Rot,
                "svg": JournalMark.uiTestSample.icon2.svg,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: root)
    }
}
