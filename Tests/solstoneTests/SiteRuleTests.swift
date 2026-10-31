// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("SiteRule")
struct SiteRuleTests {
    // MARK: - storedHost

    @Test func storedHostStandardCases() {
        #expect(SiteRule.storedHost("bank.com") == "bank.com")
        #expect(SiteRule.storedHost("BANK.com ") == "bank.com")
        #expect(SiteRule.storedHost("www.bank.com.") == "bank.com")
        #expect(SiteRule.storedHost(".bank.com") == "bank.com")
        #expect(SiteRule.storedHost("https://secure.bank.com/login") == "secure.bank.com")
        #expect(SiteRule.storedHost("*.bank.com") == "bank.com")
        #expect(SiteRule.storedHost("%2a.bank.com") == "bank.com")
        #expect(SiteRule.storedHost("https://%2A.bank.com") == "bank.com")
        #expect(SiteRule.storedHost("https://*.bank.com/x") == "bank.com")
        #expect(SiteRule.storedHost("http://example.com:8443/path") == "example.com")
        #expect(SiteRule.storedHost("example.com:8080") == "example.com")
        #expect(SiteRule.storedHost("localhost") == "localhost")
        #expect(SiteRule.storedHost("192.168.1.1") == "192.168.1.1")
        #expect(SiteRule.storedHost("http://[::1]") == "[::1]")
        #expect(SiteRule.storedHost("http://[::1]:8080") == "[::1]")
        #expect(SiteRule.storedHost("my_server.com") == "my_server.com")
        #expect(SiteRule.storedHost("foo.co.uk") == "foo.co.uk")
        #expect(SiteRule.storedHost("www.foo.co.uk") == "foo.co.uk")
        #expect(SiteRule.storedHost("www.mail.google.com") == "www.mail.google.com")
    }

    @Test func storedHostPunycode() {
        #expect(SiteRule.storedHost("bücher.de") == "xn--bcher-kva.de")
    }

    @Test func storedHostRejectsInvalid() {
        #expect(SiteRule.storedHost("") == nil)
        #expect(SiteRule.storedHost("   ") == nil)
        #expect(SiteRule.storedHost("bank .com") == nil)
        #expect(SiteRule.storedHost("a.*.bank.com") == nil)
        #expect(SiteRule.storedHost("https://person:secret@example.com") == nil)
        #expect(SiteRule.storedHost("javascript:alert(1)") == nil)
        #expect(SiteRule.storedHost("ftp://example.com") == "ftp")
        #expect(SiteRule.storedHost("https://") == nil)
        #expect(SiteRule.storedHost("example.com\nother.com") == nil)
    }

    // MARK: - covers

    @Test func coversSubdomainsAndExact() {
        #expect(SiteRule.covers(siteHost: "bank.com", host: "bank.com") == true)
        #expect(SiteRule.covers(siteHost: "bank.com", host: "www.bank.com") == true)
        #expect(SiteRule.covers(siteHost: "bank.com", host: "a.b.bank.com") == true)
        #expect(SiteRule.covers(siteHost: "bank.com", host: "notbank.com") == false)
        #expect(SiteRule.covers(siteHost: "bank.com", host: "bank.com.evil.net") == false)
        #expect(SiteRule.covers(siteHost: "mail.google.com", host: "docs.google.com") == false)
        #expect(SiteRule.covers(siteHost: "mail.google.com", host: "sub.mail.google.com") == true)
    }

    @Test func coversLocalAndIP() {
        #expect(SiteRule.covers(siteHost: "localhost", host: "localhost") == true)
        #expect(SiteRule.covers(siteHost: "localhost", host: "app.localhost") == false)
        #expect(SiteRule.covers(siteHost: "10.0.0.1", host: "10.0.0.1") == true)
        #expect(SiteRule.covers(siteHost: "10.0.0.1", host: "sub.10.0.0.1") == false)
        #expect(SiteRule.covers(siteHost: "[::1]", host: "[::1]") == true)
        #expect(SiteRule.covers(siteHost: "[::1]", host: "sub.[::1]") == false)
    }

    @Test func coversCaseInsensitive() {
        #expect(SiteRule.covers(siteHost: "BANK.COM", host: "login.bank.com") == true)
        #expect(SiteRule.covers(siteHost: "bank.com", host: "LOGIN.BANK.COM") == true)
    }

    // MARK: - normalizeReadHost

    @Test func normalizeReadHostWrappersAndCleaning() {
        #expect(SiteRule.normalizeReadHost("blob:https://sub.bank.com/uuid") == "sub.bank.com")
        #expect(SiteRule.normalizeReadHost("view-source:https://bank.com/") == "bank.com")
        #expect(SiteRule.normalizeReadHost("blob:http://localhost:3000/uuid") == "localhost")
        #expect(SiteRule.normalizeReadHost("https://Login.Bank.com./") == "login.bank.com")
        #expect(SiteRule.normalizeReadHost("https://bank.com:8443/") == "bank.com")
        #expect(SiteRule.normalizeReadHost("http://[::1]:8080/") == "[::1]")
    }

    @Test func normalizeReadHostPunycode() {
        #expect(SiteRule.normalizeReadHost("https://bücher.de/") == "xn--bcher-kva.de")
    }

    @Test func normalizeReadHostRejectsNonHttp() {
        #expect(SiteRule.normalizeReadHost("about:blank") == nil)
        #expect(SiteRule.normalizeReadHost("file:///tmp/x") == nil)
        #expect(SiteRule.normalizeReadHost("chrome://settings") == nil)
        #expect(SiteRule.normalizeReadHost("") == nil)
        #expect(SiteRule.normalizeReadHost("blob:ftp://example.com") == nil)
    }
}
