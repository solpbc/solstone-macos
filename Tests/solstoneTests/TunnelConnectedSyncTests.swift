// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel
import SolstoneCore
import Testing
@testable import solstone

@Suite("Tunnel-connected sync")
@MainActor
struct TunnelConnectedSyncTests {
    @Test func unpairedLegacyTunnelConnectKeepsCaptureRunningWithoutRegistration() {
        var syncCount = 0
        let config = AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "legacy-key",
            serviceMode: .external
        )
        let state = AppState.forSnapshot(config: config, triggerTunnelConnectedSync: { _ in
            syncCount += 1
        })
        state.isRecording = true

        state.handleTunnelLifecycleState(.disconnected)
        state.handleTunnelLifecycleState(.connected(localPort: 49152, via: .relay))

        #expect(syncCount == 1)
        #expect(state.isRecording)
        #expect(!state.isPairedHome)
        #expect(!state.sameMachineHomeMigrationComplete)
        #expect(state.config.serverURL == config.serverURL)
        #expect(state.config.serverKey == config.serverKey)
        #expect(state.config.observerName == config.observerName)
        #expect(state.config.serviceMode == config.serviceMode)
    }

    @Test func heldTunnelBaseStillTriggersSyncAndKeepsCaptureRunning() {
        var syncCount = 0
        let state = AppState.forSnapshot(triggerTunnelConnectedSync: { _ in
            syncCount += 1
        })
        state.isRecording = true

        state.handleTunnelLifecycleState(.disconnected)
        state.handleTunnelLifecycleState(.connected(localPort: 49152, via: .relay))

        #expect(syncCount == 1)
        #expect(state.isRecording)
        #expect(state.config.serverURL == nil)
        #expect(!state.sameMachineHomeMigrationComplete)
    }

    @Test func rapidConnectedEdgesTriggerSyncOncePerEdge() {
        var syncCount = 0
        let state = AppState.forSnapshot(triggerTunnelConnectedSync: { _ in
            syncCount += 1
        })

        state.handleTunnelLifecycleState(.disconnected)
        state.handleTunnelLifecycleState(.connected(localPort: 49152, via: .relay))
        state.handleTunnelLifecycleState(.connected(localPort: 49152, via: .relay))
        state.handleTunnelLifecycleState(.disconnected)
        state.handleTunnelLifecycleState(.connected(localPort: 49153, via: .relay))

        #expect(syncCount == 2)
    }
}
