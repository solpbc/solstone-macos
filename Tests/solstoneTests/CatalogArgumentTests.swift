// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
import Foundation
import Testing
@testable import solstone

struct CatalogArgumentTests {
    @Test func argumentTextRemainsData() {
        let label = "\u{E000}catalog1\u{E001} العربية \u{2068}%@ %d \" 🪶\u{2069}"
        let title = UICopy.Migration.replaceConfirmTitle(label)
        #expect(title == "replace \"\(label)\"?")
        let caution = UICopy.Websites.browserCaution(browser: label)
        #expect(caution.components(separatedBy: label).count == 3)
    }
}
