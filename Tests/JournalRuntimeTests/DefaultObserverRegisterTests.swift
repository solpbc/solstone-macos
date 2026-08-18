// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("DefaultObserverRegister")
struct DefaultObserverRegisterTests {
    @Test func postsDevicesRegisterPath() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"key":"observer-key","name":"observer-name"}"#)
        let session = URLSession(configuration: observerURLProtocolConfiguration(store: store))
        defer { session.invalidateAndCancel() }

        _ = await SolstoneInstaller.defaultObserverRegister(
            descriptor: ObserverRegistrationDescriptor(
                platform: "darwin",
                hostname: "observer-mac",
                streamType: "desktop",
                version: "1.2.3"
            ),
            session: session
        )

        let request = try #require(store.snapshotRequests().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == ServiceMode.bundledServiceURL + "/app/devices/register")
    }
}
