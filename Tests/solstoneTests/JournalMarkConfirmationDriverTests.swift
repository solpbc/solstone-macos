// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import SolstoneCore
@testable import SPLTunnel
import Testing
@testable import solstone

@Suite("JournalMarkConfirmationDriver", .serialized)
@MainActor
struct JournalMarkConfirmationDriverTests {
    @Test func presentsOnlyForFreshPairingSuccessStates() {
        for state in skippedStates {
            let driver = makeDriver()
            driver.startIfNeeded(for: state, resolveHomeBase: heldResolver(), fetchMark: neverFetch())
            #expect(!driver.isPresented)
            driver.cancel()
        }

        let paired = makeDriver()
        paired.startIfNeeded(for: .paired, resolveHomeBase: heldResolver(), fetchMark: neverFetch())
        #expect(paired.isPresented)
        paired.cancel()

        let switched = makeDriver()
        switched.startIfNeeded(for: .switched, resolveHomeBase: heldResolver(), fetchMark: neverFetch())
        #expect(switched.isPresented)
        switched.cancel()
    }

    @Test func retriesNilFetchUntilValidWithinDeadline() async throws {
        let baseURL = "http://127.0.0.1:7071"
        let fetcher = MarkFetchScript([nil, .uiTestSample])
        let driver = makeDriver(deadlineSeconds: 1)

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: { JournalMarkConfirmationDriver.HomeBaseResolution.url(baseURL) },
            fetchMark: { baseURL in
                await fetcher.fetch(baseURL: baseURL)
            }
        )

        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run {
                if case .valid = driver.phase {
                    return true
                }
                return false
            }
        }
        #expect(await fetcher.requestedBaseURLs == [baseURL, baseURL])
        driver.cancel()
    }

    @Test func heldTimeoutEntersUnverifiedAndStaysPresented() async throws {
        let driver = makeDriver(deadlineSeconds: 0.05)
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: heldResolver(),
            fetchMark: neverFetch()
        )

        try await waitUntil(timeout: .seconds(1)) {
            await MainActor.run {
                if case .unverified(.heldTimeout) = driver.phase {
                    return true
                }
                return false
            }
        }
        #expect(driver.isPresented)
        #expect(driver.phase == .unverified(.heldTimeout))
        #expect(owner.isTunnelManaged)
        #expect(!store.deleted)
        await owner.stop()
        driver.cancel()
    }

    @Test func identityUnavailableEntersUnverifiedAndStaysPresented() async throws {
        let driver = makeDriver(deadlineSeconds: 0.05)
        let baseURL = "http://127.0.0.1:7071"

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: { JournalMarkConfirmationDriver.HomeBaseResolution.url(baseURL) },
            fetchMark: neverFetch()
        )

        try await waitUntil(timeout: .seconds(1)) {
            await MainActor.run {
                if case .unverified(.identityUnavailable) = driver.phase {
                    return true
                }
                return false
            }
        }
        #expect(driver.isPresented)
        #expect(driver.phase == .unverified(.identityUnavailable))
        driver.cancel()
    }

    @Test func resetAndCancelWhileConnectingHideWithoutEnteringUnverified() async {
        let driver = makeDriver(deadlineSeconds: 1)
        driver.startIfNeeded(for: .paired, resolveHomeBase: heldResolver(), fetchMark: neverFetch())
        #expect(driver.isPresented)
        #expect(driver.phase == .connecting)

        driver.cancel()
        #expect(!driver.isPresented)
        #expect(driver.phase == .connecting)

        driver.startIfNeeded(for: .switched, resolveHomeBase: heldResolver(), fetchMark: neverFetch())
        #expect(driver.isPresented)
        #expect(driver.phase == .connecting)

        driver.resetForNewPairAttempt()
        #expect(!driver.isPresented)
        #expect(driver.phase == .connecting)
    }

    @Test func duplicateSuccessEmissionOnlyStartsOneAttemptAndEntersUnverified() async throws {
        let driver = makeDriver(deadlineSeconds: 0.05)

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: heldResolver(),
            fetchMark: neverFetch()
        )
        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: heldResolver(),
            fetchMark: neverFetch()
        )

        try await waitUntil(timeout: .seconds(1)) {
            await MainActor.run {
                if case .unverified(.heldTimeout) = driver.phase {
                    return true
                }
                return false
            }
        }
        #expect(driver.isPresented)
        #expect(driver.phase == .unverified(.heldTimeout))
        driver.cancel()
    }

    @Test func continueAnywayPreservesPairingAndDismissesIdempotently() async throws {
        let driver = makeDriver(deadlineSeconds: 0.05)
        let config = AppConfig(
            serverURL: "https://journal.example",
            serverKey: "secret",
            serviceMode: .external
        )
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))
        let resolver = makeResolver(owner: owner, config: config)
        _ = makeCoordinator(store: store, owner: owner)
        let confirmedMark: JournalMark? = nil

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        #expect(await resolver.resolve() == .url("http://127.0.0.1:24680"))

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: heldResolver(),
            fetchMark: neverFetch()
        )

        try await waitUntil(timeout: .seconds(1)) {
            await MainActor.run {
                if case .unverified = driver.phase { return true }
                return false
            }
        }

        // Before continue: pairing still present
        #expect(!store.deleted)
        #expect(owner.isTunnelManaged)
        #expect(confirmedMark == nil)

        driver.continueAnyway()

        #expect(!driver.isPresented)
        #expect(driver.phase == .connecting)
        #expect(confirmedMark == nil)
        #expect(!store.deleted)
        #expect(store.currentPairing != nil)
        #expect(owner.isTunnelManaged)
        #expect(owner.state == .connected(localPort: 24680, via: .relay))
        #expect(await resolver.resolve() == .url("http://127.0.0.1:24680"))

        // Idempotent second call is a no-op
        driver.continueAnyway()
        #expect(!driver.isPresented)
        #expect(driver.phase == .connecting)
        #expect(!store.deleted)
        #expect(owner.isTunnelManaged)

        await owner.stop()
    }

    @Test func cancelPairingClearsMarkUnpairsAndNeverCallsMismatch() async throws {
        let driver = makeDriver(deadlineSeconds: 0.05)
        let config = AppConfig(
            serverURL: "https://journal.example",
            serverKey: "secret",
            serviceMode: .external
        )
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))
        let resolver = makeResolver(owner: owner, config: config)
        let coordinator = makeCoordinator(store: store, owner: owner)
        var confirmedMark: JournalMark? = .uiTestSample

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        #expect(await resolver.resolve() == .url("http://127.0.0.1:24680"))

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: heldResolver(),
            fetchMark: neverFetch()
        )

        try await waitUntil(timeout: .seconds(1)) {
            await MainActor.run {
                if case .unverified = driver.phase { return true }
                return false
            }
        }

        // Entering .unverified must NOT have cleared mark or disconnected pairing
        #expect(confirmedMark != nil)
        #expect(owner.isTunnelManaged)
        #expect(!store.deleted)

        await driver.cancelPairing(
            clearConfirmedMark: {
                confirmedMark = nil
            },
            unpair: {
                await coordinator.unpair()
            }
        )

        try await waitUntil { owner.state == .disconnected }
        #expect(await resolver.resolve() == .url("https://journal.example"))
        await owner.stop()

        #expect(confirmedMark == nil)
        #expect(coordinator.state == .idle)
        #expect(transport.disconnectCount >= 1)
        #expect(!owner.isTunnelManaged)
        #expect(store.deleted)
        #expect(store.currentPairing == nil)
        #expect(!driver.isPresented)
        #expect(driver.phase == .connecting)
    }

    @Test func lateMarkAfterUnverifiedDoesNotAutoAdvance() async throws {
        let driver = makeDriver(deadlineSeconds: 0.05)
        let baseURL = "http://127.0.0.1:7071"

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: { JournalMarkConfirmationDriver.HomeBaseResolution.url(baseURL) },
            fetchMark: { _ in
                try? await Task.sleep(for: .milliseconds(100))
                return .uiTestSample
            }
        )

        try await waitUntil(timeout: .seconds(1)) {
            await MainActor.run {
                if case .unverified = driver.phase { return true }
                return false
            }
        }

        #expect(driver.phase == .unverified(.identityUnavailable))
        #expect(driver.isPresented)

        // Wait past late fetch completion
        try? await Task.sleep(for: .milliseconds(150))
        #expect(driver.phase == .unverified(.identityUnavailable))
        #expect(driver.isPresented)

        // Confirm while unverified is a no-op
        var confirmedMark: JournalMark?
        driver.confirm { mark in
            confirmedMark = mark
        }
        #expect(confirmedMark == nil)

        // Same success key does not re-drive or flip to valid
        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: { JournalMarkConfirmationDriver.HomeBaseResolution.url(baseURL) },
            fetchMark: { _ in .uiTestSample }
        )
        #expect(driver.phase == .unverified(.identityUnavailable))
        #expect(driver.isPresented)

        driver.cancel()
    }

    @Test func confirmCommitsConfirmedMarkAndDismisses() async throws {
        let driver = try await validDriver()
        var confirmedMark: JournalMark?

        driver.confirm { mark in
            confirmedMark = mark
        }

        #expect(confirmedMark?.words == ["afoot", "unfixed"])
        #expect(!driver.isPresented)
    }

    @Test func rejectClearsMarkUnpairsAndDismissesWithMismatch() async throws {
        let driver = try await validDriver()
        let config = AppConfig(
            serverURL: "https://journal.example",
            serverKey: "secret",
            serviceMode: .external
        )
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))
        let resolver = makeResolver(owner: owner, config: config)
        let coordinator = makeCoordinator(store: store, owner: owner)
        var confirmedMark: JournalMark? = .uiTestSample
        var mismatch = false

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        #expect(await resolver.resolve() == .url("http://127.0.0.1:24680"))

        let initialPhase = driver.phase
        #expect(initialPhase == .valid(.uiTestSample))

        await driver.reject(
            clearConfirmedMark: {
                confirmedMark = nil
            },
            unpair: {
                await coordinator.unpair()
            },
            onMismatch: {
                mismatch = true
            }
        )

        try await waitUntil { owner.state == .disconnected }
        #expect(await resolver.resolve() == .url("https://journal.example"))
        await owner.stop()

        #expect(confirmedMark == nil)
        #expect(coordinator.state == .idle)
        #expect(transport.disconnectCount >= 1)
        #expect(!owner.isTunnelManaged)
        #expect(store.deleted)
        #expect(store.currentPairing == nil)
        #expect(mismatch)
        #expect(!driver.isPresented)
    }

    private func validDriver() async throws -> JournalMarkConfirmationDriver {
        let driver = makeDriver(deadlineSeconds: 1)

        driver.startIfNeeded(
            for: .paired,
            resolveHomeBase: { JournalMarkConfirmationDriver.HomeBaseResolution.url("http://127.0.0.1:7071") },
            fetchMark: { _ in .uiTestSample }
        )
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run {
                if case .valid = driver.phase {
                    return true
                }
                return false
            }
        }
        return driver
    }

    private func makeDriver(deadlineSeconds: TimeInterval = 0.2) -> JournalMarkConfirmationDriver {
        JournalMarkConfirmationDriver(
            deadlineSeconds: deadlineSeconds,
            heldPollInterval: .milliseconds(1),
            fetchRetryInterval: .milliseconds(1)
        )
    }

    private func heldResolver() -> JournalMarkConfirmationDriver.HomeBaseResolver {
        { .held }
    }

    private func neverFetch() -> JournalMarkConfirmationDriver.MarkFetcher {
        { _ in nil }
    }

    private func makeCoordinator(
        store: PairingStore = PairingStore(pairing: pairing()),
        owner: TunnelLifecycleOwner? = nil
    ) -> PairingCoordinator {
        let actualOwner = owner ?? makeOwner(store: store)
        return PairingCoordinator(
            pair: { _, _, _ in pairing() },
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            reactivate: { [actualOwner] in
                await actualOwner.reevaluatePairing()
            },
            ownerState: { [actualOwner] in
                actualOwner.state
            }
        )
    }

    private func makeOwner(
        store: PairingStore = PairingStore(pairing: pairing()),
        factory: FakeTransportFactory = FakeTransportFactory([FakeTunnelTransport()])
    ) -> TunnelLifecycleOwner {
        TunnelLifecycleOwner(
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(store.currentPairing ?? pairing())]).seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            sleep: { _ in try await Task.sleep(for: .seconds(10)) }
        )
    }

    private func makeResolver(owner: TunnelLifecycleOwner, config: AppConfig) -> HomeBaseURLResolver {
        HomeBaseURLResolver { [owner, config] in
            await MainActor.run {
                if owner.isTunnelManaged {
                    guard let localPort = owner.localPort else {
                        return .held
                    }
                    return .url("http://127.0.0.1:\(localPort)")
                }
                guard let serverURL = config.serverURL else {
                    return .held
                }
                return .url(serverURL)
            }
        }
    }

    private var skippedStates: [PairingFlowState] {
        [
            .idle,
            .pairing,
            .switchConfirmPending(newInstanceID: "new"),
            .alreadyConnected,
            .saveFailed,
            .failed(.network),
        ]
    }

    private actor MarkFetchScript {
        private var responses: [JournalMark?]
        private(set) var requestedBaseURLs: [String] = []

        init(_ responses: [JournalMark?]) {
            self.responses = responses
        }

        func fetch(baseURL: String) -> JournalMark? {
            requestedBaseURLs.append(baseURL)
            guard !responses.isEmpty else { return nil }
            return responses.removeFirst()
        }
    }
}
