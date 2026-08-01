// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore
import Testing
@testable import solstone

@Suite("Setup topology classifier")
struct SetupTopologyClassifierTests {
    @Test func bundledModeIsLocal() {
        #expect(classifySetupTopology(
            serviceMode: .bundled,
            serverURL: nil,
            isTunnelManaged: false,
            isPairedHome: false
        ) == .local)
    }

    @Test func tunnelManagedWinsOverBundledMode() {
        #expect(classifySetupTopology(
            serviceMode: .bundled,
            serverURL: ServiceMode.bundledServiceURL,
            isTunnelManaged: true,
            isPairedHome: false
        ) == .remote)
    }

    @Test func tunnelManagedIsRemoteEvenWhenRuntimeURLIsLoopback() {
        #expect(classifySetupTopology(
            serviceMode: .external,
            serverURL: "http://127.0.0.1:61234",
            isTunnelManaged: true,
            isPairedHome: false
        ) == .remote)
    }

    @Test func pairedHomeIsLocalEvenWhenTunnelManaged() {
        #expect(classifySetupTopology(
            serviceMode: .external,
            serverURL: "http://127.0.0.1:61234",
            isTunnelManaged: true,
            isPairedHome: true
        ) == .local)
    }

    @Test func directExternalLoopbackURLIsLocal() {
        #expect(classifySetupTopology(
            serviceMode: .external,
            serverURL: "http://localhost:5015",
            isTunnelManaged: false,
            isPairedHome: false
        ) == .local)
        #expect(classifySetupTopology(
            serviceMode: .external,
            serverURL: "http://127.77.0.9:5015",
            isTunnelManaged: false,
            isPairedHome: false
        ) == .local)
        #expect(classifySetupTopology(
            serviceMode: .external,
            serverURL: "http://[::1]:5015",
            isTunnelManaged: false,
            isPairedHome: false
        ) == .local)
    }

    @Test func directExternalNonLoopbackURLIsRemote() {
        #expect(classifySetupTopology(
            serviceMode: .external,
            serverURL: "https://journal.example",
            isTunnelManaged: false,
            isPairedHome: false
        ) == .remote)
    }

    @Test func unconfiguredExternalIsUndecided() {
        #expect(classifySetupTopology(
            serviceMode: .external,
            serverURL: nil,
            isTunnelManaged: false,
            isPairedHome: false
        ) == .undecided)
    }

    @Test func loopbackHostCheckIsHostBasedNotSubstringBased() {
        #expect(LoopbackHost.isLoopbackHost("localhost"))
        #expect(LoopbackHost.isLoopbackHost("127.0.0.2"))
        #expect(LoopbackHost.isLoopbackHost("::1"))
        #expect(!LoopbackHost.isLoopbackHost("localhost.example"))
        #expect(!LoopbackHost.isLoopbackHost("2127.0.0.1"))
    }
}
