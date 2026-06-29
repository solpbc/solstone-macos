// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("HomeBaseURLResolver")
@MainActor
struct HomeBaseURLResolverTests {
    @Test func staticConfigReturnsExactConfiguredURL() async {
        let state = HomeBaseURLResolverFake(
            isTunnelManaged: false,
            localPort: nil,
            configuredServerURL: "https://journal.example/app-base"
        )
        let resolver = makeResolver(state: state)

        #expect(await resolver.resolve() == .url("https://journal.example/app-base"))
    }

    @Test func tunnelManagedWithLocalPortReturnsLoopbackBase() async {
        let state = HomeBaseURLResolverFake(
            isTunnelManaged: true,
            localPort: 23456,
            configuredServerURL: "https://journal.example"
        )
        let resolver = makeResolver(state: state)

        #expect(await resolver.resolve() == .url("http://127.0.0.1:23456"))
    }

    @Test func tunnelManagedWithoutLocalPortIsHeld() async {
        let state = HomeBaseURLResolverFake(
            isTunnelManaged: true,
            localPort: nil,
            configuredServerURL: "https://journal.example"
        )
        let resolver = makeResolver(state: state)

        #expect(await resolver.resolve() == .held)
    }

    @Test func resolverReadsPortPerRequest() async {
        let state = HomeBaseURLResolverFake(
            isTunnelManaged: true,
            localPort: 1111,
            configuredServerURL: "https://journal.example"
        )
        let resolver = makeResolver(state: state)

        #expect(await resolver.resolve() == .url("http://127.0.0.1:1111"))
        state.localPort = 2222
        #expect(await resolver.resolve() == .url("http://127.0.0.1:2222"))
    }

    private func makeResolver(state: HomeBaseURLResolverFake) -> HomeBaseURLResolver {
        HomeBaseURLResolver { [state] in
            await MainActor.run {
                if state.isTunnelManaged {
                    guard let localPort = state.localPort else {
                        return .held
                    }
                    return .url("http://127.0.0.1:\(localPort)")
                }
                guard let configuredServerURL = state.configuredServerURL else {
                    return .held
                }
                return .url(configuredServerURL)
            }
        }
    }
}

@MainActor
private final class HomeBaseURLResolverFake: @unchecked Sendable {
    var isTunnelManaged: Bool
    var localPort: Int?
    var configuredServerURL: String?

    init(isTunnelManaged: Bool, localPort: Int?, configuredServerURL: String?) {
        self.isTunnelManaged = isTunnelManaged
        self.localPort = localPort
        self.configuredServerURL = configuredServerURL
    }
}

@Suite("BundledJournalEndpoint")
struct BundledJournalEndpointTests {
    @Test func randomRelayLoopbackPortIsNotBundledServiceURL() {
        #expect(!BundledJournalEndpoint.isBundledServiceURL("http://127.0.0.1:54321"))
    }

    @Test func bundledLoopbackFormsAreBundledServiceURL() {
        #expect(BundledJournalEndpoint.isBundledServiceURL("http://localhost:5015"))
        #expect(BundledJournalEndpoint.isBundledServiceURL("http://127.0.0.1:5015"))
    }

    @Test func nilAndExternalURLsAreNotBundledServiceURL() {
        #expect(!BundledJournalEndpoint.isBundledServiceURL(nil))
        #expect(!BundledJournalEndpoint.isBundledServiceURL("https://journal.example"))
    }
}
