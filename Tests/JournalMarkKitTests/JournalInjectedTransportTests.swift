// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalMarkKit

struct JournalInjectedTransportTests {
    @Test func setupProbeUsesInjectedTransportWithoutFollowingRedirect() async throws {
        let client = JournalInitClient(dataLoader: { request in
            #expect(request.url?.path == "/init")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "/"])!)
        })
        #expect(try await client.probeSetupComplete() == .complete)
    }

    @Test func identityStillChecksExpectedInstanceWithInjectedTransport() async throws {
        let fetcher = JournalIdentityFetcher(dataLoader: { request in
            #expect(request.url?.path == "/app/link/api/identity")
            return (Data(#"{"committed":false,"instance_id":"other"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        })
        #expect(await fetcher.resolveIdentity(baseURL: "http://localhost", expectedInstanceID: "own") == .failed(.instanceMismatch))
    }
}
