// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

@Suite("Loopback capability request")
struct LoopbackCapabilityRequestTests {
    @Test func aLoopbackRequestCarriesTheCapabilityWithCookieHandlingOff() throws {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:50123/app/network/api/status")))
        request.attachLoopbackCapability()

        #expect(request.value(forHTTPHeaderField: "Cookie") == LoopbackCapability.process.cookieHeaderValue)
        #expect(!request.httpShouldHandleCookies)
    }

    @Test(arguments: ["http://192.168.1.20:5015/", "http://studio.local:5015/", "http://localhost:5015/"])
    func anyOtherHostIsLeftUnchanged(address: String) throws {
        var request = URLRequest(url: try #require(URL(string: address)))
        request.attachLoopbackCapability()

        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies)
    }
}
