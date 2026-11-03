// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import MacTestSupport
import SPLTunnel
import Testing
@testable import solstone

/// Settings' link to the journal on this Mac verifies over the tunnel and doesn't ask. Everything
/// else, including a link somebody pasted that happens to name a loopback address, still asks.
@Suite("Settings same-computer link", .serialized)
@MainActor
struct SettingsSameComputerLinkTests {
    @MainActor
    private struct World {
        let state: AppState
        let store: PairingStore
        let driver = JournalMarkConfirmationDriver()
        let pairStarts: PairStartRecorder
        let landed: StoredPairing
        let session: URLSession

        func run(localInstanceID: String? = nil) async -> SameMachineLinkOutcome {
            await runSettingsSameComputerLink(
                appState: state,
                journalMarkDriver: driver,
                startPairing: { [pairStarts] baseURL, deviceLabel in
                    await pairStarts.start(baseURL: baseURL, deviceLabel: deviceLabel)
                },
                localIdentity: { [landed] _ in
                    .mark(.uiTestSample, instanceID: localInstanceID ?? landed.instanceID)
                },
                retryAttempts: 200,
                retryInterval: .milliseconds(20)
            )
        }

        /// What the settings window does whenever a pairing lands or the tunnel changes.
        func settingsReacts() {
            driver.startIfNeeded(for: state.pairingCoordinator.state, appState: state)
            driver.startIfUnconfirmed(appState: state)
        }
    }

    /// Not the sample a journal would serve, so a test can tell which of the two was kept.
    private static let derivedMark = JournalMark(
        icon1: JournalMark.uiTestSample.icon2,
        icon2: JournalMark.uiTestSample.icon1,
        words: ["derived", "here"]
    )

    private func makeWorld(pairLink: String? = nil) throws -> World {
        let certificate = try #require(CertChain.certificates(fromPEM: testCACertPEM).first)
        let fingerprint = CertChain.sha256Fingerprint(of: certificate)
        let landed = pairing(
            instanceID: try CertChain.journalID(ofCAChainPEM: testCACertPEM),
            fingerprint: fingerprint
        )
        let link = pairLink ?? Self.loopbackLink(fingerprint: fingerprint)
        let pairStarts = PairStartRecorder(responses: [
            .success(SameMachinePairStartResponse(
                nonce: "nonce",
                pairLink: link,
                expiresIn: 300,
                deviceLabel: "test mac",
                caFingerprint: fingerprint
            )),
        ])
        let store = PairingStore(pairing: nil)
        let transport = FakeTunnelTransport(connection: .init(localPort: 18321, via: .lan))
        let factory = FakeTransportFactory([transport])
        let protocolStore = ObserverURLProtocolStore()
        protocolStore.registerRoute(matching: { _ in true }, statusCode: 503)
        let session = URLSession(configuration: observerURLProtocolConfiguration(store: protocolStore))
        let owner = TunnelLifecycleOwner(
            keychainStore: store,
            loadPairing: { try store.load() },
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            loopbackSession: session,
            unlockNotificationCenter: NotificationCenter()
        )
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false, serverURL: ServiceMode.bundledServiceURL),
            tunnelLifecycleOwner: owner,
            supportingIdentityResolver: { [landed] _, instance in
                #expect(instance == landed.instanceID)
                return .mark(.uiTestSample, instanceID: landed.instanceID)
            },
            triggerTunnelConnectedSync: { _ in },
            journalMarkConfirmationStore: InMemoryJournalMarkConfirmationStore(settled: true),
            pairingStoring: store,
            pairingOperation: { [landed] _, _, _ in landed },
            pairingLoad: { try store.load() },
            pairingSave: { try store.save($0) }
        )
        state.journalMarkDeriver = { _ in Self.derivedMark }
        state.startTunnelLifecycleOwner()
        return World(state: state, store: store, pairStarts: pairStarts, landed: landed, session: session)
    }

    private static func loopbackLink(fingerprint: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[0] = 0x04
        bytes[1] = 0x01
        bytes.replaceSubrange(2..<6, with: [127, 0, 0, 1])
        bytes[6] = 0x13
        bytes[7] = 0x97
        for index in 8..<24 { bytes[index] = UInt8(index) }
        bytes.replaceSubrange(24..<40, with: decodeHexPrefix16(fingerprint) ?? [])
        return "https://go.solstone.app/p#\(crockford32(bytes))"
    }

    private static func crockford32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var accumulator: UInt64 = 0
        var bitCount = 0
        var output = ""
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                output.append(alphabet[Int((accumulator >> UInt64(bitCount)) & 0x1f)])
                accumulator &= (1 << UInt64(bitCount)) - 1
            }
        }
        if bitCount > 0 {
            output.append(alphabet[Int((accumulator << UInt64(5 - bitCount)) & 0x1f)])
        }
        return output
    }

    @Test func aSameComputerLinkVerifiesOverTheTunnelAndNeverAsks() async throws {
        let world = try makeWorld()
        defer { world.session.invalidateAndCancel() }

        let outcome = await world.run()
        world.settingsReacts()

        #expect(outcome.tone == .notice)
        #expect(outcome.message == nil)
        #expect(!world.driver.isPresented)
        #expect(world.state.isJournalMarkConfirmed)
        #expect(world.state.pendingSameComputerLink == nil)
        #expect(world.state.confirmedMark == Self.derivedMark)
    }

    @Test func aLinkPastedForALoopbackAddressStillAsks() async throws {
        let world = try makeWorld()
        defer { world.session.invalidateAndCancel() }
        let link = Self.loopbackLink(fingerprint: CertChain.sha256Fingerprint(
            of: try #require(CertChain.certificates(fromPEM: testCACertPEM).first)
        ))

        await world.state.pairingCoordinator.submitPairingLink(link)
        #expect(world.state.pairingCoordinator.state == .paired)
        world.settingsReacts()

        #expect(world.driver.isPresented)
        #expect(!world.state.isJournalMarkConfirmed)
        world.driver.cancel()
    }

    @Test func aLinkNamingAnotherComputerPairsNothing() async throws {
        let world = try makeWorld(pairLink: lanDirectPairLink)
        defer { world.session.invalidateAndCancel() }

        let outcome = await world.run()

        #expect(outcome.tone == .error)
        #expect(outcome.offersPairingLink)
        #expect(try world.store.load() == nil)
        #expect(!world.state.isJournalMarkConfirmed)
        #expect(world.state.pendingSameComputerLink == nil)
    }

    @Test func aPendingLinkSaysNothingOnceThePairingIsGoneOrAnother() async throws {
        let world = try makeWorld()
        defer { world.session.invalidateAndCancel() }
        world.state.pendingSameComputerLink = PendingSameComputerLink(
            instanceID: world.landed.instanceID,
            caFingerprint: "fingerprint"
        )

        // Disconnected: nothing for it to finish, so opening settings doesn't link again.
        #expect(!world.state.sameComputerLinkAwaitsVerification)

        try world.store.save(world.landed)
        #expect(world.state.sameComputerLinkAwaitsVerification)

        // Another journal in its place asks like any other pairing.
        world.state.pendingSameComputerLink = PendingSameComputerLink(
            instanceID: "another-journal",
            caFingerprint: "fingerprint"
        )
        #expect(!world.state.sameComputerLinkAwaitsVerification)
    }

    @Test func aPairingThatIsntTheJournalOnThisMacIsHeldAndAsks() async throws {
        let world = try makeWorld()
        defer { world.session.invalidateAndCancel() }

        let outcome = await world.run(localInstanceID: "some-other-journal")

        #expect(outcome.tone == .error)
        #expect(!world.state.isJournalMarkConfirmed)
        #expect(world.state.pendingSameComputerLink == nil)
        try await waitUntil { world.state.needsJournalMarkConfirmation }
        world.driver.startIfUnconfirmed(appState: world.state)
        #expect(world.driver.isPresented)
        world.driver.cancel()
    }
}
