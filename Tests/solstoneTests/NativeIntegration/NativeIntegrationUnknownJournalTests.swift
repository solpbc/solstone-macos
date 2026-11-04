// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import JournalMarkKit
import Network
import SPLMark
import SPLTunnel
import SwiftUI
import Testing
@testable import solstone

/// The notice against real journals. Two native journals run in isolated homes. This Mac pairs
/// with the first at a saved address, then the second answers at that address: a real peer
/// presenting a real different CA to the real supervisor. When the first answers there again the
/// notice clears.
///
/// The pairing lives in memory and refusals in an ephemeral store, so nothing touches a keychain.
/// Set SOLSTONE_UNKNOWN_JOURNAL_RENDER_DIR to keep what the owner would see.
@Suite(
    "NativeIntegration unknown journal",
    .serialized,
    .enabled(
        if: NativeJournalFixture.isEnabled,
        "set SOLSTONE_NATIVE_INTEGRATION=1 (make integration-native) to run against a native journal runtime"
    )
)
@MainActor
struct NativeIntegrationUnknownJournalTests {
    @Test func aSecondJournalAtTheSavedAddressShowsAndClearsWhenTheFirstReturns() async throws {
        let first = try await NativeJournalFixture.start()
        var second: NativeJournalFixture?
        let forwarder = try LoopbackForwarder(target: first.ready.directDoorPort)
        do {
            let firstPairing = try await pair(with: first)
            let started = try await NativeJournalFixture.start()
            second = started
            let secondPairing = try await pair(with: started)
            try await exercise(
                firstPairing: firstPairing,
                secondPairing: secondPairing,
                firstDoor: first.ready.directDoorPort,
                secondDoor: started.ready.directDoorPort,
                forwarder: forwarder
            )
        } catch {
            forwarder.stop()
            _ = try? await first.stop()
            _ = try? await second?.stop()
            throw error
        }
        forwarder.stop()
        for fixture in [first, second].compactMap({ $0 }) {
            let stopped = try await fixture.stop()
            #expect(stopped.allAdmittedProcessesGone)
            #expect(stopped.fixtureTreeRemoved)
        }
    }

    private func pair(with fixture: NativeJournalFixture) async throws -> StoredPairing {
        let base = fixture.ready.conveyBaseURL
        _ = try await establishNativeJournalSession(client: JournalInitClient(baseURL: base))
        let port = fixture.ready.directDoorPort
        let bound = await NativeJournalFixture.waitUntil(timeout: .seconds(20)) {
            NativeJournalFixture.loopbackPortAccepts(port)
        }
        #expect(bound, "door did not bind on \(port)")
        let response: SameMachinePairStartResponse
        switch await SameMachinePairStartClient().start(baseURL: base, deviceLabel: "native-integration") {
        case .success(let started): response = started
        case .failure(let failure): throw DoorTestError.pairStart("\(failure.kind): \(failure.detail)")
        }
        return try await PairClient(clientInfo: SPLRuntime.clientInfo).pair(
            pairURL: try PairURL(string: response.pairLink),
            deviceLabel: "native-integration",
            relayEndpoint: try #require(URL(string: "https://127.0.0.1:1"))
        )
    }

    private func exercise(
        firstPairing: StoredPairing,
        secondPairing: StoredPairing,
        firstDoor: Int,
        secondDoor: Int,
        forwarder: LoopbackForwarder
    ) async throws {
        let savedAddress = LocalEndpoint(host: "127.0.0.1", port: forwarder.port, scope: "local")
        let saved = StoredPairing(
            instanceID: firstPairing.instanceID,
            homeLabel: firstPairing.homeLabel,
            relayEndpoint: firstPairing.relayEndpoint,
            fingerprint: firstPairing.fingerprint,
            clientCertPEM: firstPairing.clientCertPEM,
            clientKeyPEM: firstPairing.clientKeyPEM,
            caChainPEM: firstPairing.caChainPEM,
            relayEnrollment: firstPairing.relayEnrollment,
            localEndpoints: [savedAddress],
            pairedAt: firstPairing.pairedAt
        )
        let store = InMemoryPairingStore(pairing: saved)
        let refusals = MemoryRefusalStore()
        let owner = TunnelLifecycleOwner(
            keychainStore: store,
            makeTransport: {
                SPLTunnelTransport(makeSession: { pairing, clientInfo, policy in
                    TunnelSupervisor(pairing: pairing, clientInfo: clientInfo, policy: policy, refusalStore: refusals)
                })
            }
        )
        let site = UnknownJournalSite.address(JournalAddressText.format(savedAddress))
        let secondJournalID = try CertChain.journalID(ofCAChainPEM: secondPairing.caChainPEM)
        #expect(secondJournalID != (try CertChain.journalID(ofCAChainPEM: saved.caChainPEM)))

        owner.start()
        defer { Task { await owner.stop() } }

        // Positive control: the first journal answers at the saved address, and there is no notice.
        let connectedFirst = await NativeJournalFixture.waitUntil(timeout: .seconds(60)) {
            if case .connected = owner.state { return true }
            return false
        }
        #expect(connectedFirst, "never connected to the paired journal: \(owner.state)")
        #expect(owner.connectedThrough == .address(JournalAddressText.format(savedAddress)))
        #expect(owner.unknownJournals.notices.isEmpty)

        // The second journal takes the address.
        forwarder.retarget(to: secondDoor)
        let sawNotice = await NativeJournalFixture.waitUntil(timeout: .seconds(120)) {
            owner.unknownJournals.notices.first?.site == site
        }
        #expect(sawNotice, "no notice: state \(owner.state), verdict \(owner.connectionVerdict)")
        let claimed = owner.unknownJournals.notices.first
        #expect(claimed?.claimedJournalID == secondJournalID)

        let marksDrawn = await NativeJournalFixture.waitUntil(timeout: .seconds(60)) {
            if case .claimed = owner.unknownJournals.notices.first?.whatAnswered,
               case .mark = owner.unknownJournals.yourJournal {
                return true
            }
            return false
        }
        #expect(marksDrawn)

        // Both marks are the ones this device works out from each journal's own CA.
        let secondMark = await JournalMarkDerivation.mark(forJournalID: secondJournalID)
        let firstMark = await JournalMarkDerivation.markKeepingNothing(forCAChainPEM: saved.caChainPEM)
        #expect(owner.unknownJournals.notices.first?.whatAnswered == secondMark.map(UnknownJournalWhatAnswered.claimed))
        #expect(owner.unknownJournals.yourJournal == firstMark.map(UnknownJournalYourMark.mark))
        #expect(firstMark != secondMark)

        // A notice, not a fault: the pairing is kept and the connection speaks for itself.
        #expect(try store.load() == saved)
        #expect(owner.isTunnelManaged)
        #expect(owner.connectionVerdict.axToken != PairingConnectionAXState.disconnected.axToken)
        try renderIfAsked(owner: owner, site: site)

        // The first journal answers there again.
        forwarder.retarget(to: firstDoor)
        let cleared = await NativeJournalFixture.waitUntil(timeout: .seconds(120)) {
            owner.unknownJournals.notices.isEmpty
        }
        #expect(cleared, "notice stayed: state \(owner.state), notices \(owner.unknownJournals.notices.count)")
        #expect(owner.connectedThrough == .address(JournalAddressText.format(savedAddress)))
    }

    private func renderIfAsked(owner: TunnelLifecycleOwner, site: UnknownJournalSite) throws {
        guard let path = ProcessInfo.processInfo.environment["SOLSTONE_UNKNOWN_JOURNAL_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        func list(expanded: Set<UnknownJournalSite>, height: CGFloat, name: String) throws {
            let view = UnknownJournalNoticeList(
                notices: owner.unknownJournals.notices,
                yourJournal: owner.unknownJournals.yourJournal,
                initiallyExpanded: expanded,
                onPairAgain: {}
            )
            .padding(16)
            .frame(width: 560, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: height)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name))
        }
        try list(expanded: [], height: 90, name: "live-unknown-journal-row.png")
        try list(expanded: [site], height: 470, name: "live-unknown-journal-detail.png")
    }
}

private final class MemoryRefusalStore: HandshakeRefusalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: HandshakeRefusalRecord] = [:]

    func loadRefusalRecord(credential: String) throws -> HandshakeRefusalRecord? {
        lock.withLock { records[credential] }
    }

    func saveRefusalRecord(_ record: HandshakeRefusalRecord, credential: String) throws {
        lock.withLock { records[credential] = record }
    }
}

/// A saved address another journal can take over: raw bytes between 127.0.0.1:port and whichever
/// journal's door it's pointed at. Moving it drops what's connected, the way a device taking over
/// an address does.
private final class LoopbackForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "unknown-journal-forwarder")
    private let listener: NWListener
    private var target: Int
    private var connections: [NWConnection] = []

    private(set) var port = 0

    init(target: Int) throws {
        self.target = target
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] inbound in
            self?.accept(inbound)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let bound = listener.port?.rawValue else {
            throw DoorTestError.socket("forwarder did not start")
        }
        port = Int(bound)
    }

    func retarget(to door: Int) {
        let dropped: [NWConnection] = lock.withLock {
            target = door
            defer { connections = [] }
            return connections
        }
        dropped.forEach { $0.forceCancel() }
    }

    func stop() {
        listener.cancel()
        retarget(to: lock.withLock { target })
    }

    private func accept(_ inbound: NWConnection) {
        let door = lock.withLock { target }
        let outbound = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: UInt16(door))!,
            using: .tcp
        )
        lock.withLock { connections += [inbound, outbound] }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound)
        pump(from: outbound, to: inbound)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                destination.forceCancel()
                source.forceCancel()
                return
            }
            self?.pump(from: source, to: destination)
        }
    }
}
