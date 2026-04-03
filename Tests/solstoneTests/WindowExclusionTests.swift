// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("WindowExclusionDetector.isPrivateBrowserWindow")
struct WindowExclusionTests {
    // MARK: - Safari

    @Test func safariPrivateWindow() {
        #expect(WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "safari", windowTitle: "Private — Apple"))
    }

    @Test func safariNormalWindow() {
        #expect(!WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "safari", windowTitle: "Apple — Start Page"))
    }

    // MARK: - Chrome

    @Test func chromeIncognitoWithParens() {
        #expect(WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "google chrome", windowTitle: "New Tab (Incognito)"))
    }

    @Test func chromeIncognitoWithoutParens() {
        #expect(WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "google chrome", windowTitle: "Incognito - New Tab"))
    }

    @Test func chromeNormalWindow() {
        #expect(!WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "google chrome", windowTitle: "Google Search"))
    }

    // MARK: - Firefox

    @Test func firefoxPrivateBrowsingWithParens() {
        #expect(WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "firefox", windowTitle: "Mozilla Firefox (Private Browsing)"))
    }

    @Test func firefoxPrivateBrowsingWithoutParens() {
        #expect(WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "firefox", windowTitle: "Private Browsing - Firefox"))
    }

    @Test func firefoxNormalWindow() {
        #expect(!WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "firefox", windowTitle: "Mozilla Firefox"))
    }

    // MARK: - Non-browsers

    @Test func nonBrowserAppReturnsFalse() {
        #expect(!WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "terminal", windowTitle: "Private Browsing"))
    }

    @Test func unknownAppReturnsFalse() {
        #expect(!WindowExclusionDetector.isPrivateBrowserWindow(
            ownerName: "slack", windowTitle: "Incognito"))
    }
}
