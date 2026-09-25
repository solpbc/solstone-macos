// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import SPLTunnel
import Testing
@testable import solstone

private let addressA = ConnectedVia.lanDirect(host: "192.168.1.20", port: 7657)
private let addressB = ConnectedVia.lanDirect(host: "fd00::1", port: 7657)
private let relayVia = ConnectedVia.relay(endpoint: URL(string: "wss://link.solstone.app/session/abc")!)
private let retrying = TunnelSupervisorAttemptState.unavailable(
    .retrying(failureClass: .unreachable, attempt: 1, retryAfter: .seconds(5))
)

private let secretInstanceID = "instance-SENTINEL-4242"
private let secretDeviceToken = "token-SENTINEL-9999"

private func addressPairing(
    localEndpoints: [LocalEndpoint] = [
        LocalEndpoint(host: "192.168.1.20", port: 7657, scope: "lan"),
        LocalEndpoint(host: "fd00::1", port: 7657, scope: "vpn")
    ]
) -> StoredPairing {
    pairing(
        instanceID: secretInstanceID,
        deviceToken: secretDeviceToken,
        relayEndpoint: "wss://link.solstone.app/relay/path?token=\(secretDeviceToken)",
        localEndpoints: localEndpoints
    )
}

// 0x04 direct: 192.168.1.42:7070.
private let singleCandidatePairLink = "https://go.solstone.app/p#0G0W1A0158DSW48H248H248H248H248H248H249248H248H248H248H248H248H2"
// 0x05 direct: 10.0.0.7:7070, then 100.64.3.9:7070.
private let twoCandidatePairLink = "https://go.solstone.app/p#0M0G46WY180001V4801GJ48H248H248H248H248H248H249248H248H248H248H248H248H2"

@Suite("Journal address visibility", .serialized)
@MainActor
struct JournalAddressVisibilityTests {
    @Test func captionNamesOneTwoOrManyAddressesWithIPv6Bracketed() {
        let v4 = JournalAddressText.format(host: "192.168.1.20", port: 7657)
        let v6 = JournalAddressText.format(host: "fd00::1", port: 7657)
        let zoned = JournalAddressText.format(host: "fe80::1%en0", port: 7657)
        let named = JournalAddressText.format(host: "journal.local", port: 7657)

        #expect(v4 == "192.168.1.20:7657")
        #expect(v6 == "[fd00::1]:7657")
        #expect(zoned == "[fe80::1%en0]:7657")
        #expect(JournalAddressText.format(host: "[fd00::1]", port: 7657) == "[fd00::1]:7657")

        #expect(UICopy.journalTriedAddresses([]) == nil)
        #expect(UICopy.journalTriedAddresses([v4]) == "tried 192.168.1.20:7657")
        #expect(UICopy.journalTriedAddresses([v4, v6]) == "tried 192.168.1.20:7657 and [fd00::1]:7657")
        #expect(UICopy.journalTriedAddresses([v4, v6, named]) == "tried 192.168.1.20:7657, [fd00::1]:7657 and journal.local:7657")
    }

    // A journal that can't be reached never gets installed, so the dial record
    // has to come from the candidate that is still trying.
    @Test func unreachableCaptionNamesOnlyWhatWasDialedBeforeAnyConnection() async throws {
        let supervisors = ActualSupervisorRecorder(armGate: true)
        let store = PairingStore(pairing: addressPairing())
        let owner = TunnelLifecycleOwner(
            credentialStore: PairingCredentialStore(store: store),
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) })
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            sleep: { _ in try await Task.sleep(for: .seconds(10)) }
        )

        owner.start()
        try await waitUntil { supervisors.children.count >= 1 }
        let child = supervisors.children[0]
        try await waitUntil { await child.pendingConnectCount == 1 }

        // The plan lists A twice (pinned and unpinned) and the relay. A plan is not a dial.
        child.emitState(.connecting(candidates: [addressA, addressA, relayVia]))
        child.emitAttemptState(retrying)
        try await waitUntil { owner.connectionVerdict.axToken == PairingConnectionAXState.unreachable.axToken }
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.connectionVerdict.caption == nil)
        #expect(owner.triedAddresses.isEmpty)

        child.emitAttemptState(.attempting)
        try await waitUntil { owner.connectionVerdict.axToken == PairingConnectionAXState.connecting.axToken }
        child.emitState(.connecting(candidates: [addressA, addressA, relayVia]))
        child.emitState(.tlsHandshaking(via: addressA))
        child.emitState(.tlsHandshaking(via: addressA))
        child.emitState(.tlsHandshaking(via: relayVia))
        child.emitState(.awaitingBroker(via: relayVia))
        child.emitAttemptState(retrying)

        try await waitUntil { owner.connectionVerdict.caption == "tried 192.168.1.20:7657" }
        #expect(owner.triedAddresses == ["192.168.1.20:7657"])
        #expect(owner.connectionVerdict.message == "can't reach your journal right now")
        #expect(owner.connectionVerdict.failureCause == .unreachable(nil))
        await owner.stop()
    }

    @Test func handleRecordsDialsAfterLossAndConnectedThroughOnlyWhileConnected() async throws {
        let transport = FakeTunnelTransport(connectionMode: .plDirect, connection: .init(localPort: 8080, via: .lan))
        let owner = makeOwner(factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.connectedThrough == .address("127.0.0.1:8080") }
        #expect(owner.triedAddresses.isEmpty)

        transport.emit(.connecting(candidates: [addressA, addressA, relayVia]))
        transport.emit(.tlsHandshaking(via: addressA))
        transport.emit(.tlsHandshaking(via: addressB))
        transport.emit(.tlsHandshaking(via: addressA))
        transport.emit(.tlsHandshaking(via: relayVia))
        transport.emitAttemptState(retrying)

        try await waitUntil { owner.connectionVerdict.caption == "tried 192.168.1.20:7657 and [fd00::1]:7657" }
        #expect(owner.connectedThrough == nil)

        transport.emit(.connected(via: relayVia))
        transport.emitAttemptState(.connected)
        try await waitUntil { owner.connectedThrough == .relay }
        #expect(owner.triedAddresses.isEmpty)
        #expect(owner.connectedThrough?.text == "the relay")
        await owner.stop()
    }

    @Test func rePairClearsTheDialRecordBeforeAnyCaptionRenders() async throws {
        do {
            let transport = FakeTunnelTransport(connectionMode: .plDirect, connection: .init(localPort: 8080, via: .lan))
            let successor = FakeTunnelTransport()
            successor.armConnectGate()
            let owner = makeOwner(factory: FakeTransportFactory([transport, successor]))

            owner.start()
            try await waitUntil { owner.connectedThrough != nil }
            await owner.reevaluatePairing()
            #expect(owner.connectedThrough == nil)
            await owner.stop()
        }

        do {
            let transport = FakeTunnelTransport()
            let successor = FakeTunnelTransport()
            successor.armConnectGate()
            let owner = makeOwner(factory: FakeTransportFactory([transport, successor]))

            owner.start()
            try await waitUntil { owner.connectedThrough != nil }
            transport.emit(.connecting(candidates: [addressA]))
            transport.emit(.tlsHandshaking(via: addressA))
            transport.emitAttemptState(retrying)
            try await waitUntil { owner.connectionVerdict.caption == "tried 192.168.1.20:7657" }

            await owner.reevaluatePairing()
            #expect(owner.triedAddresses.isEmpty)
            #expect(owner.connectionVerdict.caption == nil)
            await owner.stop()
        }
    }

    @Test func unmanagedVerdictKeepsItsCaptionEvenWithAStaleDialRecord() {
        let stale = ["192.168.1.20:7657"]
        let unmanaged = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .connecting,
            hasPersistedPairing: true,
            isTunnelManaged: false,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false,
            triedAddresses: stale
        )
        #expect(unmanaged.caption == "waiting for a direct network route or relay connection")
        #expect(unmanaged.failureCause == .noRoute)

        let managed = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .connecting,
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false,
            triedAddresses: stale
        )
        #expect(managed.caption == "tried 192.168.1.20:7657")
        #expect(managed.failureCause == .unreachable(nil))
    }

    @Test func pairedStatusCardNamesThePairedAddressNotTheRelayAndStaysEncrypted() {
        let owner = TunnelLifecycleOwner.dormantForSnapshot(loadPairing: { addressPairing() })
        #expect(owner.dialableRelayHost == "link.solstone.app")
        let address = statusCardPairedJournalAddress(
            pairedAddresses: owner.pairedAddresses,
            isPairedHome: owner.isPairedHome
        )
        #expect(address == "192.168.1.20:7657")

        let summary = StatusHealthSummary.make(
            serviceMode: .external,
            isRecording: true,
            isPaused: false,
            uploadStatus: .synced,
            pendingCount: 0,
            lastDeliveryOutcome: .delivered(Date(timeIntervalSince1970: 900)),
            serverURL: nil,
            pairedJournalAddress: address,
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(summary.title == "all good · on, synced to 192.168.1.20:7657")
        #expect(!summary.title.contains("link.solstone.app"))

        let footer = externalStatusFooterText(serverURL: nil, pairedJournalAddress: address, permissionsGranted: true)
        #expect(footer.contains("your journal lives on 192.168.1.20:7657, encrypted"))
        #expect(!footer.contains("link.solstone.app"))

        let home = TunnelLifecycleOwner.dormantForSnapshot(loadPairing: {
            pairing(localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 7657, scope: "local")])
        })
        #expect(statusCardPairedJournalAddress(pairedAddresses: home.pairedAddresses, isPairedHome: home.isPairedHome) == nil)
    }

    @Test func agentInstructionsNameThePairedAddressAndNeverTheInstance() {
        let owner = TunnelLifecycleOwner.dormantForSnapshot(loadPairing: { addressPairing() })
        let journal = agentInstructionsJournalValue(pairedAddresses: owner.pairedAddresses, serverURL: nil)

        #expect(journal == "192.168.1.20:7657")
        #expect(!journal.contains(secretInstanceID))
        #expect(agentInstructionsJournalValue(pairedAddresses: [], serverURL: nil) == "not configured")
        #expect(agentInstructionsJournalValue(pairedAddresses: [], serverURL: "https://x.example") == "https://x.example")
    }

    @Test func diagnosticsReportAddressesRelayHostAndDialsButNoSecrets() {
        let owner = TunnelLifecycleOwner.dormantForSnapshot(loadPairing: { addressPairing() })
        let now = Date(timeIntervalSince1970: 1_000)
        func report(tried: [String], through: JournalConnectedThrough?) -> DiagnosticReport {
            buildDiagnosticReport(DiagnosticReportInput(
                appVersion: "1.2.3",
                screenRecording: .granted,
                microphone: .granted,
                isRecording: true,
                isPaused: false,
                hasError: false,
                lastDelivery: .delivered(now.addingTimeInterval(-120)),
                lastJournalContact: .synced(now.addingTimeInterval(-30)),
                evidence: .available(DiagnosticEvidenceEnvelope(
                    schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
                    entries: []
                )),
                ingestReason: nil,
                ingestRoute: nil,
                now: now,
                connection: DiagnosticConnectionInput(
                    isPaired: owner.cachedPairingIdentity != nil,
                    pairedAddresses: owner.pairedAddresses,
                    dialableRelayHost: owner.dialableRelayHost,
                    triedAddresses: tried,
                    connectedThrough: through
                )
            ))
        }

        let failing = report(tried: ["192.168.1.20:7657", "[fd00::1]:7657"], through: nil)
        #expect(failing.rows.map(\.id) == [
            .appVersion, .screenRecording, .microphone, .screenAndAudio, .lastDelivery,
            .lastJournalConnection, .ingestReason, .ingestRoute, .journalLink,
            .journalAddresses, .relay, .addressesTried, .recentStateCodes
        ])
        #expect(failing.text.contains("""
        journal link: nothing turned away or ended early
        addresses: 192.168.1.20:7657
                   [fd00::1]:7657
        relay: on · link.solstone.app
        addresses tried: 192.168.1.20:7657
                         [fd00::1]:7657
        recent state codes: no recent state codes
        """))

        let connected = report(tried: [], through: .address("192.168.1.20:7657"))
        #expect(connected.rows.first { $0.id == .connectedThrough }?.value == "192.168.1.20:7657")
        #expect(connected.rows.first { $0.id == .addressesTried } == nil)
        #expect(report(tried: [], through: .relay).rows.first { $0.id == .connectedThrough }?.value == "the relay")

        for report in [failing, connected] {
            for secret in [secretInstanceID, secretDeviceToken, "/relay/path", "BEGIN CERTIFICATE", "MIIBdTCC", "fingerprint"] {
                #expect(!report.text.contains(secret))
            }
        }

        let unpaired = buildDiagnosticReport(DiagnosticReportInput(
            appVersion: "1.2.3",
            screenRecording: .granted,
            microphone: .granted,
            isRecording: true,
            isPaused: false,
            hasError: false,
            lastDelivery: .notLinked,
            lastJournalContact: .notLinked,
            evidence: .unavailable,
            ingestReason: nil,
            ingestRoute: nil,
            now: now
        ))
        #expect(!unpaired.rows.contains { [.journalAddresses, .relay, .addressesTried, .connectedThrough].contains($0.id) })

        let relayOff = journalRelayValue(dialableRelayHost: nil)
        #expect(relayOff == "off")
    }

    @Test func pairingFailureNamesTheOneAddressItDialed() async throws {
        let single = makeFailingCoordinator()
        await single.submitPairingLink(singleCandidatePairLink)
        #expect(single.state == .failed(.homeUnreachable))
        #expect(single.failedAddress == "192.168.1.42:7070")
        #expect(PairingFailure.homeUnreachable.message(address: single.failedAddress)
            == "couldn't reach your journal at 192.168.1.42:7070. make sure it's running, then try again.")

        let multiple = makeFailingCoordinator()
        await multiple.submitPairingLink(twoCandidatePairLink)
        #expect(multiple.state == .failed(.homeUnreachable))
        #expect(multiple.failedAddress == nil)
        #expect(PairingFailure.homeUnreachable.message(address: multiple.failedAddress)
            == "couldn't reach your journal. make sure it's running, then try again.")
    }

    private func makeFailingCoordinator() -> PairingCoordinator {
        PairingCoordinator(
            pair: { _, _, _ in throw DialError.connectTimeout },
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {},
            relayEndpoint: { URL(string: "https://relay.test")! },
            deviceLabel: { "test mac" }
        )
    }

    private func makeOwner(factory: FakeTransportFactory) -> TunnelLifecycleOwner {
        let store = PairingStore(pairing: addressPairing())
        return TunnelLifecycleOwner(
            credentialStore: PairingCredentialStore(store: store),
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(addressPairing())]).seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            sleep: { _ in try await Task.sleep(for: .seconds(10)) }
        )
    }
}
