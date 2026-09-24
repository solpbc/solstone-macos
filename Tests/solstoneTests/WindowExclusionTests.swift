// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

/// Every title below was read from a real window on macOS 27: the private titles from a private
/// window on a real page, the ordinary titles from an ordinary window of the same browser.
@Suite("WindowExclusionDetector.isPrivateBrowserWindow")
struct WindowExclusionTests {
    // MARK: - Firefox: the one browser that writes private mode into its title

    @Test(arguments: [
        "Example Domain \u{2014} Private Browsing",
        "Mozilla Firefox \u{2014} Private Browsing",
    ])
    func firefoxPrivateWindowIsExcluded(title: String) {
        #expect(WindowExclusionDetector.isPrivateBrowserWindow(ownerName: "firefox", windowTitle: title))
    }

    @Test(arguments: [
        "Mozilla Firefox",
        "Private browsing - Wikipedia",
        "Private Browsing - Use Firefox without saving history | Firefox Help",
        "Incognito (band) - Wikipedia",
        "Private equity - Wikipedia",
        "Private Browsing",
        "Private Browsing \u{2014} Example Domain",
        "Example Domain - Private Browsing",
    ])
    func firefoxOrdinaryWindowIsNotExcluded(title: String) {
        #expect(!WindowExclusionDetector.isPrivateBrowserWindow(ownerName: "firefox", windowTitle: title))
    }

    // MARK: - Browsers whose private windows show no marker in the title

    /// Their private windows read the bare page title, so the title check can never see them,
    /// and an ordinary window must never be excluded for words in its page title.
    @Test(arguments: [
        ("safari", "Example Domain"),
        ("safari", "Private equity - Wikipedia"),
        ("google chrome", "Example Domain"),
        ("google chrome", "Incognito (band) - Wikipedia"),
        ("microsoft edge", "Example Domain"),
        ("microsoft edge", "Private browsing - Wikipedia"),
        ("brave browser", "Example Domain"),
        ("brave browser", "Private browsing - Wikipedia"),
    ])
    func unmarkedBrowserIsNeverExcluded(owner: String, title: String) {
        #expect(!WindowExclusionDetector.isPrivateBrowserWindow(ownerName: owner, windowTitle: title))
    }

    // MARK: - Non-browsers

    @Test func nonBrowserWithTheFirefoxFormIsNotExcluded() {
        #expect(!WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "terminal", windowTitle: "notes \u{2014} Private Browsing"))
    }
}
