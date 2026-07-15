// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import solstone

@Suite("Tunnel observer registration", .serialized)
@MainActor
struct TunnelObserverRegistrationTests {
    @Test func firstTunnelRegistrationPersistsMintedKeyAndDescriptor() async throws {
        let baseURL = "http://127.0.0.1:49152"
        let registrar = FakeObserverRegistrar(result: .success(ObserverRegistration(
            key: "tunnel-key",
            streamName: "desktop-stream"
        )))
        let state = AppState.forSnapshot()

        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: true,
            resolveBase: { .url(baseURL) },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )

        #expect(registrar.invocationCount == 1)
        #expect(registrar.lastBaseURL == baseURL)
        #expect(state.config.serverURL == baseURL)
        #expect(state.config.serverKey == "tunnel-key")
        #expect(state.config.observerName == "desktop-stream")
        #expect(state.config.serviceMode == .external)
        #expect(state.config.isUploadConfigured)

        let descriptor = try #require(registrar.lastDescriptor)
        #expect(descriptor.platform == "darwin")
        #expect(descriptor.hostname == expectedHostname())
        #expect(descriptor.streamType == "desktop")
        #expect(descriptor.version == expectedVersion())
    }

    @Test func nonTunnelRegistrationDoesNotResolveRegisterOrPersist() async {
        let registrar = FakeObserverRegistrar()
        let state = AppState.forSnapshot()

        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: false,
            resolveBase: {
                Issue.record("resolveBase should not be called for non-tunnel registration")
                return .held
            },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )

        #expect(registrar.invocationCount == 0)
        #expect(state.config.serverURL == nil)
        #expect(state.config.serverKey == nil)
        #expect(state.config.observerName == nil)
        #expect(state.config.serviceMode == nil)
    }

    @Test func sameKeyRegistrationDoesNotRewriteDynamicPort() async {
        let firstBaseURL = "http://127.0.0.1:49152"
        let secondBaseURL = "http://127.0.0.1:49153"
        let registrar = FakeObserverRegistrar(results: [
            .success(ObserverRegistration(key: "stable-key", streamName: "first-stream")),
            .success(ObserverRegistration(key: "stable-key", streamName: "second-stream"))
        ])
        let state = AppState.forSnapshot()

        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: true,
            resolveBase: { .url(firstBaseURL) },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )
        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: true,
            resolveBase: { .url(secondBaseURL) },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )

        #expect(registrar.invocationCount == 2)
        #expect(registrar.baseURLs == [firstBaseURL, secondBaseURL])
        #expect(state.config.serverURL == firstBaseURL)
        #expect(state.config.serverKey == "stable-key")
        #expect(state.config.observerName == "first-stream")
        #expect(state.config.serviceMode == .external)
        #expect(state.config.isUploadConfigured)
    }

    @Test func differentKeyRegistrationRekeysAndPersistsCurrentBaseURL() async {
        let firstBaseURL = "http://127.0.0.1:49152"
        let secondBaseURL = "http://127.0.0.1:49153"
        let registrar = FakeObserverRegistrar(results: [
            .success(ObserverRegistration(key: "old-key", streamName: "old-stream")),
            .success(ObserverRegistration(key: "new-key", streamName: "new-stream"))
        ])
        let state = AppState.forSnapshot()

        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: true,
            resolveBase: { .url(firstBaseURL) },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )
        await performTunnelObserverRegistration(
            appState: state,
            isTunnelManaged: true,
            resolveBase: { .url(secondBaseURL) },
            register: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            }
        )

        #expect(registrar.invocationCount == 2)
        #expect(state.config.serverURL == secondBaseURL)
        #expect(state.config.serverKey == "new-key")
        #expect(state.config.observerName == "new-stream")
        #expect(state.config.serviceMode == .external)
        #expect(state.config.isUploadConfigured)
    }

    @Test func heldTunnelRegistrationDoesNotPersistAndStillTriggersSync() async {
        let registrar = FakeObserverRegistrar()
        let triggerSpy = TriggerSyncSpy()
        let state = AppState.forSnapshot(
            config: AppConfig(),
            initialTunnelPairing: pairing(),
            observerRegister: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            },
            triggerTunnelConnectedSync: { appState in
                triggerSpy.trigger(appState)
            }
        )

        #expect(state.serviceNeedsAttention)
        state.handleTunnelLifecycleState(.connected(localPort: 49152, via: .relay))
        await triggerSpy.waitForCount(1)

        #expect(triggerSpy.count == 1)
        #expect(registrar.invocationCount == 0)
        #expect(state.config.serverURL == nil)
        #expect(state.config.serverKey == nil)
        #expect(state.config.observerName == nil)
        #expect(state.serviceNeedsAttention)
    }

    @Test func failedTunnelRegistrationDoesNotPersistAndStillTriggersSync() async {
        let baseURL = "http://127.0.0.1:49152"
        let registrar = FakeObserverRegistrar(result: .failure(ObserverRegistrationFailure(
            kind: .transport,
            detail: "offline"
        )))
        let triggerSpy = TriggerSyncSpy()
        let state = AppState.forSnapshot(
            config: AppConfig(serverURL: baseURL),
            initialTunnelPairing: pairing(),
            observerRegister: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            },
            triggerTunnelConnectedSync: { appState in
                triggerSpy.trigger(appState)
            }
        )

        #expect(state.serviceNeedsAttention)
        state.handleTunnelLifecycleState(.connected(localPort: 49152, via: .relay))
        await triggerSpy.waitForCount(1)

        #expect(triggerSpy.count == 1)
        #expect(registrar.invocationCount == 1)
        #expect(registrar.lastBaseURL == baseURL)
        #expect(state.config.serverURL == baseURL)
        #expect(state.config.serverKey == nil)
        #expect(state.config.observerName == nil)
        #expect(state.serviceNeedsAttention)
    }

    @Test func rapidConnectedEdgesCoalesceRegistrationAndTriggerEachEdge() async {
        let baseURL = "http://127.0.0.1:49152"
        let registrar = FakeObserverRegistrar(
            result: .success(ObserverRegistration(key: "coalesced-key", streamName: "coalesced-stream")),
            delay: .milliseconds(100)
        )
        let triggerSpy = TriggerSyncSpy()
        let state = AppState.forSnapshot(
            config: AppConfig(serverURL: baseURL),
            initialTunnelPairing: pairing(),
            observerRegister: { baseURL, descriptor in
                await registrar.register(baseURL: baseURL, descriptor: descriptor)
            },
            triggerTunnelConnectedSync: { appState in
                triggerSpy.trigger(appState)
            }
        )

        state.handleTunnelLifecycleState(.connected(localPort: 49152, via: .relay))
        state.handleTunnelLifecycleState(.disconnected)
        state.handleTunnelLifecycleState(.connected(localPort: 49153, via: .relay))
        await triggerSpy.waitForCount(2)

        #expect(triggerSpy.count == 2)
        #expect(registrar.invocationCount == 1)
        #expect(registrar.lastBaseURL == baseURL)
        #expect(state.config.serverURL == baseURL)
        #expect(state.config.serverKey == "coalesced-key")
        #expect(state.config.observerName == "coalesced-stream")
        #expect(state.config.serviceMode == .external)
        #expect(state.config.isUploadConfigured)
    }
}

private func expectedHostname() -> String {
    let trimmed = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "unknown" : trimmed
}

private func expectedVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
}

@MainActor
private final class TriggerSyncSpy: @unchecked Sendable {
    private(set) var count = 0

    func trigger(_: AppState) {
        count += 1
    }

    func waitForCount(_ expected: Int) async {
        for _ in 0..<200 {
            if count >= expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
