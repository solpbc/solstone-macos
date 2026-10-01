// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

/// Every title below was read from a real window on macOS 27 in English: the window title the app
/// reads for capture, and, for Safari, Chrome, Edge and Brave, the window's Accessibility title.
@Suite("Private browser window verdicts")
struct WindowExclusionTests {
    // MARK: - Firefox: the private mark is in the window title

    @Test(arguments: [
        "Example Domain \u{2014} Private Browsing",
        "Mozilla Firefox \u{2014} Private Browsing",
    ])
    func firefoxPrivateWindowIsPrivate(title: String) {
        #expect(PrivateBrowser.firefoxVerdict(windowTitle: title) == .privateWindow)
    }

    @Test(arguments: [
        "Mozilla Firefox",
        "Example Domain",
        "Private browsing - Wikipedia",
        "Private Browsing - Use Firefox without saving history | Firefox Help",
        "Private browsing - Incognito (InPrivate) explained",
        "Private Browsing",
        "Private Browsing \u{2014} Example Domain",
        "Example Domain - Private Browsing",
    ])
    func firefoxOrdinaryWindowIsOrdinary(title: String) {
        #expect(PrivateBrowser.firefoxVerdict(windowTitle: title) == .ordinary)
    }

    @Test func firefoxWindowWithoutATitleIsUndecided() {
        #expect(PrivateBrowser.firefoxVerdict(windowTitle: "") == .undecided)
    }

    // MARK: - Safari, Chrome, Edge, Brave: the mark is in the Accessibility title

    /// (browser, window title, Accessibility title) of a real private window.
    @Test(arguments: [
        (PrivateBrowser.chrome, "Example Domain", "Example Domain - Google Chrome (Incognito)"),
        (PrivateBrowser.chrome, "Untitled", "Untitled - Google Chrome (Incognito)"),
        (PrivateBrowser.edge, "Example Domain", "Example Domain - Microsoft Edge (InPrivate)"),
        (PrivateBrowser.brave, "Example Domain", "Example Domain - Brave (Private)"),
        (PrivateBrowser.safari, "Example Domain", "Example Domain, Private Browsing"),
        (PrivateBrowser.safari, "Start Page", "Start Page, Private Browsing"),
    ])
    func accessibilityPrivateWindowIsPrivate(browser: PrivateBrowser, title: String, accessibilityTitle: String) {
        #expect(browser.accessibilityVerdict(windowTitle: title, accessibilityTitle: accessibilityTitle) == .privateWindow)
    }

    /// Real ordinary windows, including pages that title themselves with each browser's private tail.
    @Test(arguments: [
        (PrivateBrowser.chrome, "Example Domain", "Example Domain - Google Chrome"),
        (PrivateBrowser.chrome, "Forged - Google Chrome (Incognito)", "Forged - Google Chrome (Incognito) - Google Chrome"),
        (PrivateBrowser.chrome, "Private browsing - Incognito (InPrivate) explained", "Private browsing - Incognito (InPrivate) explained - Google Chrome"),
        (PrivateBrowser.edge, "Forged - Microsoft Edge (InPrivate)", "Forged - Microsoft Edge (InPrivate) - Microsoft Edge"),
        (PrivateBrowser.edge, "Example Domain", "Example Domain - Microsoft Edge"),
        (PrivateBrowser.brave, "Forged - Brave (Private)", "Forged - Brave (Private) - Brave"),
        (PrivateBrowser.brave, "Welcome to Brave", "Welcome to Brave - Brave"),
        (PrivateBrowser.safari, "Forged, Private Browsing", "Forged, Private Browsing"),
        (PrivateBrowser.safari, "Example Domain", "Example Domain"),
    ])
    func accessibilityOrdinaryWindowIsOrdinary(browser: PrivateBrowser, title: String, accessibilityTitle: String) {
        #expect(browser.accessibilityVerdict(windowTitle: title, accessibilityTitle: accessibilityTitle) == .ordinary)
    }

    @Test func chromeProfileNameAfterTheOrdinaryTailIsOrdinary() {
        #expect(PrivateBrowser.chrome.accessibilityVerdict(
            windowTitle: "Example Domain", accessibilityTitle: "Example Domain - Google Chrome - Work") == .ordinary)
    }

    /// Titles caught mid-change, or in a form never measured, are neither.
    @Test(arguments: [
        (PrivateBrowser.chrome, "Example Domain", ""),
        (PrivateBrowser.chrome, "Example Domain", "Untitled - Google Chrome (Incognito)"),
        (PrivateBrowser.safari, "Example Domain", "Loading, Private Browsing"),
        (PrivateBrowser.edge, "Example Domain", "Something else entirely"),
    ])
    func mismatchedTitlesAreUndecided(browser: PrivateBrowser, title: String, accessibilityTitle: String) {
        #expect(browser.accessibilityVerdict(windowTitle: title, accessibilityTitle: accessibilityTitle) == .undecided)
    }
}
