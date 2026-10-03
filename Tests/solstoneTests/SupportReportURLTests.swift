// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

struct SupportReportURLTests {
    @Test func reportUsesFixedFragmentContract() {
        let url = SupportReportURL.make(
            version: "2.0.0",
            build: "30",
            osVersion: "15.6",
            state: "paused",
            recent: "app.launch\ncapture.stopped",
            about: "solstone macos app 2.0.0 (30) · macos 15.6 · arm64\njournal unknown"
        ).absoluteString

        #expect(url.hasPrefix("https://support.solstone.app/#report=v1&app=solstone+for+macos"))
        #expect(url.contains("&state=paused"))
        #expect(url.contains("&recent=app.launch%0Acapture.stopped"))
        #expect(url.contains("&about=solstone+macos+app+2.0.0+%2830%29+%C2%B7+macos+15.6+%C2%B7+arm64%0Ajournal+unknown"))
        #expect(!url.contains("?"))
        #expect(!url.contains("journal="))
    }

    @Test func optionalFieldsAreOmittedAndStateIsBounded() {
        let url = SupportReportURL.make(
            version: "1",
            build: "2",
            osVersion: "",
            state: String(repeating: "é", count: 501),
            recent: nil,
            about: "line one\nline two"
        ).absoluteString

        #expect(!url.contains("os_version="))
        #expect(url.components(separatedBy: "%C3%A9").count - 1 == 500)
        #expect(!SupportReportURL.make(
            version: "1", build: "2", osVersion: "", state: "", recent: nil, about: "journal unknown"
        ).absoluteString.contains("state="))
        #expect(SupportReportURL.make(
            version: "1", build: "2", osVersion: "", state: "", recent: nil, about: "line one\nline two"
        ).absoluteString.hasSuffix("&about=line+one%0Aline+two"))
    }
}
