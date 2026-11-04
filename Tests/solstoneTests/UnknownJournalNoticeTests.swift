// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import SPLTunnel
import Testing
@testable import solstone

private final class DeriveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var calls: [String] { lock.withLock { ids } }
    func record(_ id: String) { lock.withLock { ids.append(id) } }
}

/// Holds a derivation open until the test lets it finish.
private actor DeriveGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private let hostA = ConnectedVia.lanDirect(host: "192.168.1.20", port: 7657)
private let hostB = ConnectedVia.lanDirect(host: "fd00::1", port: 7657)
private let relayVia = URL(string: "https://relay.example")!.relayConnectedVia
private let siteA = UnknownJournalSite.address("192.168.1.20:7657")
private let siteB = UnknownJournalSite.address("[fd00::1]:7657")
private let markOne = JournalMark.uiTestSample
private let markTwo = JournalMark(
    icon1: JournalMark.uiTestSample.icon2,
    icon2: JournalMark.uiTestSample.icon1,
    words: ["bramble", "quokka"]
)

@Suite("Unknown journal notices", .serialized)
@MainActor
struct UnknownJournalNoticesTests {
    private func makeNotices(
        counter: DeriveCounter = DeriveCounter(),
        claimed: @escaping @Sendable (String) -> JournalMark? = { _ in markOne },
        gate: DeriveGate? = nil
    ) -> UnknownJournalNotices {
        UnknownJournalNotices(
            deriveClaimedMark: { journalID in
                counter.record(journalID)
                await gate?.wait()
                return claimed(journalID)
            },
            derivePairedMark: { _ in markTwo }
        )
    }

    @Test func aSightingShowsAtOnceThenItsMarkAndKeepsNothingElseWaiting() async throws {
        let gate = DeriveGate()
        let notices = makeNotices(gate: gate)

        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: "jid-1"), pairing: pairing())

        #expect(notices.notices.map(\.site) == [siteA])
        #expect(notices.notices.first?.whatAnswered == .deriving)

        await gate.release()
        try await waitUntil(timeout: .seconds(2)) { @MainActor in
            notices.notices.first?.whatAnswered == .claimed(markOne)
        }
        try await waitUntil(timeout: .seconds(2)) { @MainActor in notices.yourJournal == .mark(markTwo) }
    }

    @Test func eachPlaceIsItsOwnRowInTheOrderSeen() {
        let notices = makeNotices()

        notices.record(UnknownJournalSighting(dialled: hostB, claimedJournalID: nil), pairing: pairing())
        notices.record(UnknownJournalSighting(dialled: relayVia, claimedJournalID: nil), pairing: pairing())
        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil), pairing: pairing())

        #expect(notices.notices.map(\.site) == [siteB, .relay, siteA])
    }

    @Test func noJIDIsTheNeutralSlotAndDerivesNothing() {
        let counter = DeriveCounter()
        let notices = makeNotices(counter: counter)

        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil), pairing: pairing())

        #expect(notices.notices.first?.whatAnswered == .notPresented)
        #expect(counter.calls.isEmpty)
    }

    @Test func theMarkIsWorkedOutOncePerAddressAndAgainOnlyWhenTheJIDChanges() async throws {
        let counter = DeriveCounter()
        let notices = makeNotices(counter: counter, claimed: { $0 == "jid-2" ? markTwo : markOne })

        for _ in 0..<5 {
            notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: "jid-1"), pairing: pairing())
        }
        try await waitUntil(timeout: .seconds(2)) { @MainActor in
            notices.notices.first?.whatAnswered == .claimed(markOne)
        }
        #expect(counter.calls == ["jid-1"])

        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: "jid-2"), pairing: pairing())
        #expect(notices.notices.first?.whatAnswered == .deriving)
        try await waitUntil(timeout: .seconds(2)) { @MainActor in
            notices.notices.first?.whatAnswered == .claimed(markTwo)
        }
        #expect(counter.calls == ["jid-1", "jid-2"])
        #expect(notices.notices.count == 1)

        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil), pairing: pairing())
        #expect(notices.notices.first?.whatAnswered == .notPresented)
    }

    @Test func aDerivationForAJIDNoLongerClaimedIsDropped() async throws {
        let gate = DeriveGate()
        let counter = DeriveCounter()
        let notices = makeNotices(counter: counter, claimed: { _ in markOne }, gate: gate)

        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: "jid-1"), pairing: pairing())
        try await waitUntil(timeout: .seconds(2)) { @MainActor in counter.calls == ["jid-1"] }
        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil), pairing: pairing())

        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(notices.notices.first?.whatAnswered == .notPresented)
    }

    @Test func aMarkThatCannotBeWorkedOutIsStillAClaim() async throws {
        let notices = makeNotices(claimed: { _ in nil })

        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: "jid-1"), pairing: pairing())
        try await waitUntil(timeout: .seconds(2)) { @MainActor in
            notices.notices.first?.whatAnswered == .claimedUnavailable
        }
        let caption = UnknownJournalNoticeCopy.caption(for: .claimedUnavailable)
        #expect(caption == UICopy.UNKNOWN_JOURNAL_CAPTION_CLAIMED)
    }

    @Test func eachSlotGetsItsCopyKey() {
        #expect(UnknownJournalNoticeCopy(site: siteA).row == UICopy.unknownJournalRow(address: "192.168.1.20:7657"))
        #expect(UnknownJournalNoticeCopy(site: siteA).body == UICopy.unknownJournalBody(address: "192.168.1.20:7657"))
        #expect(UnknownJournalNoticeCopy(site: .relay).row == UICopy.UNKNOWN_JOURNAL_ROW_RELAY)
        #expect(UnknownJournalNoticeCopy(site: .relay).body == UICopy.UNKNOWN_JOURNAL_BODY_RELAY)
        #expect(UnknownJournalNoticeCopy.caption(for: .claimed(markOne)) == UICopy.UNKNOWN_JOURNAL_CAPTION_CLAIMED)
        #expect(UnknownJournalNoticeCopy.caption(for: .notPresented) == UICopy.UNKNOWN_JOURNAL_CAPTION_NOT_PRESENTED)
    }

    @Test func aSuccessClearsOnlyItsOwnPlace() {
        let notices = makeNotices()
        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil), pairing: pairing())
        notices.record(UnknownJournalSighting(dialled: hostB, claimedJournalID: nil), pairing: pairing())
        notices.record(UnknownJournalSighting(dialled: relayVia, claimedJournalID: nil), pairing: pairing())

        notices.clear(at: .lanDirect(host: "192.168.1.99", port: 7657))
        #expect(notices.notices.map(\.site) == [siteA, siteB, .relay])

        notices.clear(at: hostB)
        #expect(notices.notices.map(\.site) == [siteA, .relay])

        notices.clear(at: relayVia)
        #expect(notices.notices.map(\.site) == [siteA])
    }

    @Test func aNewJournalEndsTheNoticesAndANewCertificateDoesNot() {
        let notices = makeNotices()
        let paired = pairing(instanceID: "instance-1", caChainPEM: testCACertPEM, fingerprint: "one")
        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil), pairing: paired)

        notices.pairingChanged(to: pairing(instanceID: "instance-1", caChainPEM: testCACertPEM, fingerprint: "two"))
        #expect(notices.notices.map(\.site) == [siteA])

        notices.pairingChanged(to: pairing(instanceID: "instance-2", caChainPEM: otherCACertPEM, fingerprint: "three"))
        #expect(notices.notices.isEmpty)
        #expect(notices.yourJournal == .deriving)
    }

    @Test func withNoPairingThereIsNothingToBeInsteadOf() {
        let notices = makeNotices()
        notices.record(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil), pairing: nil)
        #expect(notices.notices.isEmpty)
    }
}

/// Through the owner: published as soon as the transport reports it, and additive.
@Suite("Unknown journal notices: owner", .serialized)
@MainActor
struct UnknownJournalOwnerTests {
    private func makeOwner(
        store: PairingStore,
        factory: FakeTransportFactory
    ) -> TunnelLifecycleOwner {
        TunnelLifecycleOwner(
            keychainStore: store,
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(store.currentPairing ?? pairing())]).seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            sleep: { _ in try await Task.sleep(for: .seconds(10)) },
            unknownJournals: UnknownJournalNotices(
                deriveClaimedMark: { _ in markOne },
                derivePairedMark: { _ in markTwo }
            )
        )
    }

    @Test func aSightingNeverChangesTheConnection() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let store = PairingStore(pairing: pairing())
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        let stateBefore = owner.state
        let verdictBefore = owner.connectionVerdict

        transport.emitSighting(UnknownJournalSighting(dialled: hostA, claimedJournalID: "jid-1"))

        try await waitUntil(timeout: .seconds(2)) { @MainActor in owner.unknownJournals.notices.map(\.site) == [siteA] }
        #expect(owner.state == stateBefore)
        #expect(owner.connectionVerdict == verdictBefore)
        #expect(store.currentPairing != nil)
        await owner.stop()
    }

    @Test func aSightingWhileStillDialingShowsBeforeAnythingConnects() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        transport.armConnectGate()
        let owner = makeOwner(store: PairingStore(pairing: pairing()), factory: FakeTransportFactory([transport]))
        owner.start()
        try await waitUntil { transport.pendingConnectCount == 1 }

        transport.emitSighting(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil))

        try await waitUntil(timeout: .seconds(2)) { @MainActor in owner.unknownJournals.notices.map(\.site) == [siteA] }
        #expect(owner.state == .connecting)
        transport.releasePendingConnect()
        await owner.stop()
    }

    @Test func aLaterConnectionAtThatAddressClearsItAndAnotherAddressDoesNot() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let owner = makeOwner(store: PairingStore(pairing: pairing()), factory: FakeTransportFactory([transport]))
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        transport.emitSighting(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil))
        transport.emitSighting(UnknownJournalSighting(dialled: hostB, claimedJournalID: nil))
        try await waitUntil(timeout: .seconds(2)) { @MainActor in owner.unknownJournals.notices.count == 2 }

        transport.emit(.connected(via: relayVia))
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.unknownJournals.notices.map(\.site) == [siteA, siteB])

        transport.emit(.connected(via: hostA))
        try await waitUntil(timeout: .seconds(2)) { @MainActor in owner.unknownJournals.notices.map(\.site) == [siteB] }
        await owner.stop()
    }

    @Test func aReevaluationKeepsNoticesAndAPairingForAnotherJournalEndsThem() async throws {
        let first = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let second = FakeTunnelTransport(connection: .init(localPort: 24681, via: .relay))
        let third = FakeTunnelTransport(connection: .init(localPort: 24682, via: .relay))
        let store = PairingStore(pairing: pairing(instanceID: "instance-1", caChainPEM: testCACertPEM))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([first, second, third]))
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        first.emitSighting(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil))
        try await waitUntil(timeout: .seconds(2)) { @MainActor in owner.unknownJournals.notices.count == 1 }

        await owner.reevaluatePairing()
        #expect(owner.unknownJournals.notices.map(\.site) == [siteA])

        try store.save(pairing(instanceID: "instance-2", caChainPEM: otherCACertPEM))
        await owner.reevaluatePairing()
        #expect(owner.unknownJournals.notices.isEmpty)
        await owner.stop()
    }

    @Test func aRevocationThatDeletesTheCredentialEndsTheNotices() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let store = PairingStore(pairing: pairing())
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        transport.emitSighting(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil))
        try await waitUntil(timeout: .seconds(2)) { @MainActor in owner.unknownJournals.notices.count == 1 }

        transport.emit(.failed(.revoked))

        try await waitUntil(timeout: .seconds(2)) { @MainActor in store.currentPairing == nil }
        try await waitUntil(timeout: .seconds(2)) { @MainActor in owner.unknownJournals.notices.isEmpty }
        await owner.stop()
    }

    @Test func stoppingEndsTheNotices() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 24680, via: .relay))
        let owner = makeOwner(store: PairingStore(pairing: pairing()), factory: FakeTransportFactory([transport]))
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 24680, via: .relay) }
        transport.emitSighting(UnknownJournalSighting(dialled: hostA, claimedJournalID: nil))
        try await waitUntil(timeout: .seconds(2)) { @MainActor in owner.unknownJournals.notices.count == 1 }

        await owner.stop()

        #expect(owner.unknownJournals.notices.isEmpty)
    }
}

/// The menu carries the row as a sibling, and nothing about the icon or the status row moves.
@Suite("Unknown journal notices: menu", .serialized)
@MainActor
struct UnknownJournalMenuTests {
    @Test func aNoticeLeavesTheMenuBarPresentationAlone() {
        let state = AppState.forSnapshot(initialTunnelPairing: pairing())
        let before = state.menubarPresentation(durableUpdateStatus: .idle)

        state.tunnelLifecycleOwner.unknownJournals.record(
            UnknownJournalSighting(dialled: hostA, claimedJournalID: nil),
            pairing: pairing()
        )

        #expect(state.tunnelLifecycleOwner.unknownJournals.notices.count == 1)
        let after = state.menubarPresentation(durableUpdateStatus: .idle)
        #expect(after.observation == before.observation)
        #expect(after.attention == before.attention)
        #expect(after.observation.iconState == before.observation.iconState)
    }
}

/// The real transport forwards what its session reports, for its own generation only.
@Suite("Unknown journal notices: transport", .serialized)
@MainActor
struct UnknownJournalTransportTests {
    @Test func aSessionsSightingsReachTheSubscriberUntilDisconnect() async throws {
        let session = FakeTunnelReconnectingSession()
        let transport = SPLTunnelTransport(makeSession: { _, _, _ in session })
        var iterator = transport.unknownJournalSightings.makeAsyncIterator()

        let connect = Task { @MainActor in
            try await transport.connect(pairing: pairing(), candidates: [])
        }
        let sighting = UnknownJournalSighting(dialled: hostA, claimedJournalID: "jid-1")
        // The session exists once connect has begun; a sighting before that has nowhere to go.
        try await waitUntil(timeout: .seconds(2)) { @MainActor in
            await session.connectCallCount == 1
        }
        session.emitSighting(sighting)
        #expect(await iterator.next() == sighting)

        _ = try? await connect.value
        await transport.disconnect()
        #expect(await iterator.next() == nil)
    }
}
