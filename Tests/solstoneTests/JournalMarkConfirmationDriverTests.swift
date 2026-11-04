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
            driver.startIfNeeded(for: state, deriveMark: neverDerive())
            #expect(!driver.isPresented)
            driver.cancel()
        }

        let paired = makeDriver()
        paired.startIfNeeded(for: .paired, deriveMark: neverDerive())
        #expect(paired.isPresented)
        paired.cancel()

        // A switch asks before it lands, so landing asks nothing.
        let switched = makeDriver()
        switched.startIfNeeded(for: .switched, deriveMark: neverDerive())
        #expect(!switched.isPresented)
    }

    @Test func resetAndCancelWhileConnectingHideWithoutEnteringUnverified() async {
        let driver = makeDriver()
        driver.startIfNeeded(for: .paired, deriveMark: neverDerive())
        #expect(driver.isPresented)
        #expect(driver.phase == .deriving)

        driver.cancel()
        #expect(!driver.isPresented)
        #expect(driver.phase == .deriving)

        driver.resetForNewPairAttempt()
        driver.startIfNeeded(for: .paired, deriveMark: neverDerive())
        #expect(driver.isPresented)
        #expect(driver.phase == .deriving)

        driver.resetForNewPairAttempt()
        #expect(!driver.isPresented)
        #expect(driver.phase == .deriving)
    }

    @Test func theHeldRowReasksACancelledQuestion() {
        let driver = makeDriver()

        driver.startIfNeeded(for: "unconfirmed:J", deriveMark: neverDerive())
        #expect(driver.isPresented)

        driver.cancel()
        #expect(!driver.isPresented)

        driver.startIfNeeded(for: "unconfirmed:J", deriveMark: neverDerive())
        #expect(!driver.isPresented)

        driver.reaskUnconfirmed(journal: "J", deriveMark: neverDerive())
        #expect(driver.isPresented)
        #expect(driver.phase == .deriving)

        driver.cancel()
        driver.startIfNeeded(for: "unconfirmed:J", deriveMark: neverDerive())
        #expect(!driver.isPresented)
    }

    @Test func continueAnywayPreservesPairingAndDismissesIdempotently() async throws {
        let driver = makeDriver()
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
            deriveMark: { nil }
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
        #expect(driver.phase == .deriving)
        #expect(confirmedMark == nil)
        #expect(!store.deleted)
        #expect(store.currentPairing != nil)
        #expect(owner.isTunnelManaged)
        #expect(owner.state == .connected(localPort: 24680, via: .relay))
        #expect(await resolver.resolve() == .url("http://127.0.0.1:24680"))

        // Idempotent second call is a no-op
        driver.continueAnyway()
        #expect(!driver.isPresented)
        #expect(driver.phase == .deriving)
        #expect(!store.deleted)
        #expect(owner.isTunnelManaged)

        await owner.stop()
    }

    @Test func cancelPairingClearsMarkUnpairsAndNeverCallsMismatch() async throws {
        let driver = makeDriver()
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
            deriveMark: { nil }
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
        #expect(driver.phase == .deriving)
    }

    @Test func cancelPairingKeepsConfirmationWhenDurableInvalidationFails() async throws {
        let driver = makeDriver()
        let store = PairingStore(
            pairing: pairing(),
            carriedRecordSaveError: PairingCredentialStoreError.staleGeneration
        )
        let coordinator = makeCoordinator(store: store)
        driver.startIfNeeded(for: .paired, deriveMark: { nil })
        try await waitUntil(timeout: .seconds(1)) {
            await MainActor.run {
                if case .unverified = driver.phase { return true }
                return false
            }
        }
        var cleared = false

        let completed = await driver.cancelPairing(
            clearConfirmedMark: { cleared = true },
            unpair: { await coordinator.unpair() }
        )

        #expect(!completed)
        #expect(!cleared)
        #expect(driver.isPresented)
        #expect(store.currentPairing != nil)
        #expect(!store.deleted)
        driver.cancel()
    }

    @Test func aDerivedMarkIsAskedAbout() async throws {
        let driver = makeDriver()
        driver.startIfNeeded(for: .paired, deriveMark: { .uiTestSample })
        #expect(driver.isPresented)
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run { driver.phase == .valid(.uiTestSample) }
        }
        driver.cancel()
    }

    @Test func aDerivationThatFailsIsUnavailable() async throws {
        let driver = makeDriver()
        driver.startIfNeeded(for: .paired, deriveMark: { nil })
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run { driver.phase == .unverified }
        }
        #expect(driver.isPresented)
        driver.cancel()
    }

    @Test func aRepeatedSuccessStartsOneDerivation() async throws {
        let driver = makeDriver()
        let calls = LockedCounter()
        let derive: JournalMarkConfirmationDriver.MarkDeriver = {
            calls.increment()
            return .uiTestSample
        }
        driver.startIfNeeded(for: .paired, deriveMark: derive)
        driver.startIfNeeded(for: .paired, deriveMark: derive)
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run { driver.phase == .valid(.uiTestSample) }
        }
        #expect(calls.count == 1)
        driver.cancel()
    }

    @Test func theHeldRowLeavesAnOpenQuestionAlone() async throws {
        let driver = makeDriver()
        driver.startIfNeeded(for: "unconfirmed:J", deriveMark: { .uiTestSample })
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run { driver.phase == .valid(.uiTestSample) }
        }
        driver.reaskUnconfirmed(journal: "J", deriveMark: { nil })
        #expect(driver.isPresented)
        #expect(driver.phase == .valid(.uiTestSample))
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

    @Test func rejectKeepsConfirmationAndSkipsMismatchWhenDurableInvalidationFails() async throws {
        let driver = try await validDriver()
        let store = PairingStore(
            pairing: pairing(),
            carriedRecordSaveError: PairingCredentialStoreError.staleGeneration
        )
        let coordinator = makeCoordinator(store: store)
        var cleared = false
        var mismatch = false

        let completed = await driver.reject(
            clearConfirmedMark: { cleared = true },
            unpair: { await coordinator.unpair() },
            onMismatch: { mismatch = true }
        )

        #expect(!completed)
        #expect(!cleared)
        #expect(!mismatch)
        #expect(driver.isPresented)
        #expect(store.currentPairing != nil)
        #expect(!store.deleted)
        driver.cancel()
    }

    private func validDriver() async throws -> JournalMarkConfirmationDriver {
        let driver = makeDriver()

        driver.startIfNeeded(
            for: .paired,
            deriveMark: { .uiTestSample }
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

    private func makeDriver() -> JournalMarkConfirmationDriver {
        JournalMarkConfirmationDriver()
    }

    private func neverDerive() -> JournalMarkConfirmationDriver.MarkDeriver {
        {
            try? await Task.sleep(for: .seconds(60))
            return nil
        }
    }

    private func makeCoordinator(
        store: PairingStore = PairingStore(pairing: pairing()),
        owner: TunnelLifecycleOwner? = nil
    ) -> PairingCoordinator {
        let actualOwner = owner ?? makeOwner(store: store)
        return PairingCoordinator(
            pair: { _, _, _ in pairing() },
            keychainStore: store,
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
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
            keychainStore: store,
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
            .switchConfirmPending,
            .switchMarkPending,
            .switchDeclined,
            .switched,
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

private actor ResolverEntryCounter {
    private var entries = 0

    func recordEntry() {
        entries += 1
    }

    func entryCount() -> Int {
        entries
    }
}
