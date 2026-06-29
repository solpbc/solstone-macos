// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("GlyphParser")
struct GlyphParserTests {
    @Test func lucideCorpusParsesNonEmptyPaths() throws {
        for (name, svg) in Self.corpus {
            let path = try #require(GlyphParser.parse(innerMarkup: svg), "\(name) did not parse")
            #expect(!path.isEmpty, "\(name) parsed to an empty path")
        }
    }

    @Test func pathDataEdgeCasesParse() throws {
        let samples = [
            #"<path d="M1.35.09 L2-1" />"#,
            #"<path d="M12 2 A10 10 0 0 1 22 12" />"#,
            #"<path d="M22 12 a10 10 0 0 1-10 10" />"#,
            #"<ellipse cy="9" ry="5" cx="12" rx="10" />"#,
            #"<rect ry="2" width="18" rx="2" height="18" y="3" x="3" />"#
        ]

        for sample in samples {
            let path = try #require(GlyphParser.parse(innerMarkup: sample))
            #expect(!path.isEmpty)
        }
    }

    @Test func unsupportedCommandFailsWholeGlyph() {
        #expect(GlyphParser.parse(innerMarkup: #"<path d="M0 0 R1 1" />"#) == nil)
    }

    @Test func unknownElementFailsWholeGlyph() {
        #expect(GlyphParser.parse(innerMarkup: #"<path d="M0 0L1 1" /><polygon points="0,0 1,1 2,0" />"#) == nil)
    }

    private static let corpus: [(String, String)] = [
        (
            "anchor",
            #"<path d="M12 6v16" /> <path d="m19 13 2-1a9 9 0 0 1-18 0l2 1" /> <path d="M9 11h6" /> <circle cx="12" cy="4" r="2" />"#
        ),
        (
            "bug",
            JournalMark.uiTestSample.icon1.svg
        ),
        (
            "gem",
            JournalMark.uiTestSample.icon2.svg
        ),
        (
            "drum",
            #"<path d="m2 2 8 8" /> <path d="m22 2-8 8" /> <ellipse cx="12" cy="9" rx="10" ry="5" /> <path d="M7 13.4v7.9" /> <path d="M12 14v8" /> <path d="M17 13.4v7.9" /> <path d="M2 9v8a10 5 0 0 0 20 0V9" />"#
        ),
        (
            "banana",
            #"<path d="M4 13c3.5-2 8-2 10 2a5.5 5.5 0 0 1 8 5" /> <path d="M5.15 17.89c5.52-1.52 8.65-6.89 7-12C11.55 4 11.5 2 13 2c3.22 0 5 5.5 5 8 0 6.5-4.2 12-10.49 12C5.11 22 2 22 2 20c0-1.5 1.14-1.55 3.15-2.11Z" />"#
        ),
        (
            "dice-5",
            #"<rect width="18" height="18" x="3" y="3" rx="2" ry="2" /> <path d="M16 8h.01" /> <path d="M8 8h.01" /> <path d="M8 16h.01" /> <path d="M16 16h.01" /> <path d="M12 12h.01" />"#
        ),
        (
            "lock",
            #"<rect width="18" height="11" x="3" y="11" rx="2" ry="2" /> <path d="M7 11V7a5 5 0 0 1 10 0v4" />"#
        ),
    ]
}
