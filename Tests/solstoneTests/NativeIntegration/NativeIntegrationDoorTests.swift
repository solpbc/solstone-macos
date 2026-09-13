// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalMarkKit
import JournalRuntimeTestSupport
import SPLTunnel
import Testing
@testable import JournalRuntime
@testable import solstone

/// The proxy meets the real door. Against the staged native runtime: establish the journal
/// session the way the Journal app does (mark lock, finalize), pair the way the sol app does
/// (same-machine pair-start, the SPL ceremony over the real door), connect the real
/// `SPLTunnelTransport`, and then drive raw TCP through the real `LoopbackProxy`:
///
/// - eight idle preconnections must not starve a ninth connection's request (the September
///   2026 idle-preconnection window failure, now against the real door rather than a capped
///   fake);
/// - five held streams must still leave room for one more request. That floor is what a
///   browser window needs, and it is the binding between the door's stream limit and the
///   app: if the native door's `MAX_CONCURRENT_STREAMS` drops below what the window needs,
///   this reds. The over-cap control below is the other direction: holding more streams than
///   the limit must starve the next request, so a raised limit is noticed too, and the
///   `spl-swift` unit fake's limit gets updated with it.
///
/// Relay enrollment is pointed at an unreachable loopback endpoint on purpose: the pair
/// client degrades it to unavailable, and nothing here reaches the production relay.
@Suite(
    "NativeIntegration door",
    .serialized,
    .enabled(
        if: NativeRuntimeFixture.isEnabled,
        "set SOLSTONE_NATIVE_INTEGRATION=1 (make integration-native) to run against the staged native journal runtime"
    )
)
@MainActor
struct NativeIntegrationDoorTests {
    /// The native door's concurrent-stream limit as shipped. Both controls below pin it: the
    /// floor proves the app's browser need fits under it, the over-cap control proves the
    /// instrument sees the limit at all.
    private static let doorStreamLimit = 8
    private static let browserNeed = 6
    private static let assetPath = "/static/shell_gate.js"

    @Test func proxyServesThroughRealDoorUnderIdlePreconnectionsAndHeldStreams() async throws {
        let fixture = try NativeRuntimeFixture(label: "door")
        defer { fixture.clear() }
        let setup = try await NativeIntegrationHelpers.runAppSetup(fixture)
        try #require(setup.succeeded, "\(setup.stderr)")

        let directPort = try NativeRuntimeFixture.reserveLoopbackPort()
        let conveyPort = try NativeRuntimeFixture.reserveLoopbackPort()
        try NativeIntegrationHelpers.configureDirectDoorPort(fixture, port: directPort)
        try await JournalRequiredModelsReconciler().reconcile(runtime: fixture.runtime, journalRoot: fixture.journalRoot)

        let runner = SupervisedJournalRunner(
            statusSink: { _ in },
            gate: MockSingleSupervisorGate(result: .success),
            requiredModels: JournalRequiredModelsReconciler()
        )
        let reader = LiveJournalProcessContainmentEvidenceReader()
        let admitted = AdmittedProcesses()
        defer { NativeIntegrationHelpers.killSurvivors(admitted.all()) }

        try await runner.start(
            runtime: fixture.runtime,
            journalRoot: fixture.journalRoot,
            port: conveyPort,
            receiptContext: NativeIntegrationHelpers.silentReceiptContext()
        )
        let identity = try #require(await runner.currentIdentity())
        admitted.record([identity.pid])
        let readiness = await JournalReadinessGate().waitUntilReady(
            journalRoot: fixture.journalRoot,
            runtime: fixture.runtime,
            timeout: .seconds(120),
            terminalCheck: { await runner.terminalReason() },
            identityProvider: { await runner.currentIdentity() },
            readinessAcceptance: { await runner.markReady(identity: $0) }
        )
        try #require(readiness == .ready, "\(readiness)")
        if let evidence = reader.containmentEvidence(for: identity.pid),
           let group = reader.processIDs(inProcessGroup: evidence.processGroupID) {
            admitted.record(group)
        }

        // The door is withheld until the session is established. Establish it the way the
        // Journal app's first run does, over the same HTTP client.
        let conveyBase = "http://127.0.0.1:\(conveyPort)"
        let withheld = try #require(NativeIntegrationHelpers.readDirectDoorRecord(fixture))
        #expect(withheld.state == "withheld", "fresh journal should withhold the door, saw \(withheld.state)")
        let initClient = JournalInitClient(baseURL: conveyBase)
        _ = try await initClient.getMark()
        let locked = try await initClient.lockMark()
        #expect(locked.locked)
        let finalized = try await initClient.finalize()
        #expect(finalized.success)
        let doorBound = await NativeIntegrationHelpers.waitUntil(timeout: .seconds(20)) {
            NativeIntegrationHelpers.loopbackPortAccepts(directPort)
        }
        #expect(doorBound, "door did not bind on 127.0.0.1:\(directPort) after finalize")
        // The native opens the door after finalize but does not republish its
        // `health/direct-door.json` record until the next supervisor boot, so the record
        // still reads withheld while the listener is live. When the native republishes it,
        // this known issue reports an unexpected pass and the block can be removed.
        withKnownIssue("direct-door.json stays 'withheld' after first-run finalize while the door is bound") {
            #expect(NativeIntegrationHelpers.readDirectDoorRecord(fixture)?.state == "bound")
        }

        // Pair the way the sol app does: same-machine pair-start, then the SPL ceremony over
        // the real door. The pairing stays in memory; nothing touches a keychain.
        let started = await SameMachinePairStartClient().start(baseURL: conveyBase, deviceLabel: "native-integration")
        let pairStart: SameMachinePairStartResponse
        switch started {
        case .success(let response): pairStart = response
        case .failure(let failure): throw DoorTestError.pairStart("\(failure.kind): \(failure.detail)")
        }
        let pairURL = try PairURL(string: pairStart.pairLink)
        if case .failure(let rejection) = verifySameMachinePairLink(kind: pairURL.kind, candidates: pairURL.candidates) {
            throw DoorTestError.pairLink("\(rejection)")
        }
        #expect(pairURL.candidates.first?.port == UInt16(directPort))
        let unreachableRelay = try #require(URL(string: "https://127.0.0.1:1"))
        let pairing = try await PairClient(clientInfo: SPLRuntime.clientInfo).pair(
            pairURL: pairURL,
            deviceLabel: "native-integration",
            relayEndpoint: unreachableRelay
        )
        #expect(pairing.localEndpoints.contains { $0.port == directPort }, "\(pairing.localEndpoints)")
        if case .enrolled = pairing.relayEnrollment {
            Issue.record("pairing reports relay enrollment against an unreachable relay endpoint")
        }

        // The real transport: supervisor dial over the door, then the loopback proxy.
        let transport = SPLTunnelTransport()
        let connection = try await transport.connect(
            pairing: pairing,
            candidates: TransportEndpoint.candidates(for: pairing)
        )
        #expect(connection.via == .lan, "\(connection.via)")
        let proxyPort = connection.localPort

        var sockets: [Int32] = []
        defer { for descriptor in sockets { close(descriptor) } }

        // Positive control before any pressure: one plain request serves the asset.
        let plain = try LoopbackHTTP.request(port: proxyPort, path: Self.assetPath)
        #expect(plain.hasPrefix("HTTP/1.1 200"), "plain request: \(plain.prefix(120))")

        // Eight idle preconnections, then a ninth connection's request must still be served.
        for _ in 0..<Self.doorStreamLimit {
            sockets.append(try LoopbackHTTP.connect(port: proxyPort))
        }
        let underIdle = try LoopbackHTTP.request(port: proxyPort, path: Self.assetPath)
        #expect(underIdle.hasPrefix("HTTP/1.1 200"), "request under idle preconnections: \(underIdle.prefix(120))")
        for descriptor in sockets { close(descriptor) }
        sockets.removeAll()

        // Browser floor: hold (need - 1) streams open with partial requests, then one more
        // full request must be served.
        for _ in 0..<(Self.browserNeed - 1) {
            sockets.append(try LoopbackHTTP.connectAndHold(port: proxyPort, path: Self.assetPath))
        }
        let underHeld = try LoopbackHTTP.request(port: proxyPort, path: Self.assetPath)
        #expect(
            underHeld.hasPrefix("HTTP/1.1 200"),
            "door left no room for a \(Self.browserNeed)th stream; the window needs \(Self.browserNeed): \(underHeld.prefix(120))"
        )
        for descriptor in sockets { close(descriptor) }
        sockets.removeAll()
        try await Task.sleep(for: .milliseconds(300))

        // Over-cap control: hold the whole limit, and the next request must be starved. If
        // this passes with a 200, the native door's limit rose; update `doorStreamLimit` here
        // and the `spl-swift` LoopbackProxy test fake with it.
        for _ in 0..<Self.doorStreamLimit {
            sockets.append(try LoopbackHTTP.connectAndHold(port: proxyPort, path: Self.assetPath))
        }
        let overCap = try LoopbackHTTP.request(port: proxyPort, path: Self.assetPath, readTimeoutSeconds: 8)
        #expect(
            !overCap.hasPrefix("HTTP/1.1 200"),
            "a request was served with \(Self.doorStreamLimit) streams held: the door's stream limit changed"
        )
        for descriptor in sockets { close(descriptor) }
        sockets.removeAll()
        try await Task.sleep(for: .milliseconds(300))

        // Releasing the held streams restores service.
        let afterRelease = try LoopbackHTTP.request(port: proxyPort, path: Self.assetPath)
        #expect(afterRelease.hasPrefix("HTTP/1.1 200"), "after release: \(afterRelease.prefix(120))")

        await transport.disconnect()
        await runner.stopForTermination()
        let gone = await NativeIntegrationHelpers.waitUntil(timeout: .seconds(20)) {
            admitted.all().allSatisfy { !NativeIntegrationHelpers.processExists($0) }
        }
        #expect(gone, "survivors after termination: \(admitted.all().filter(NativeIntegrationHelpers.processExists))")
        #expect(fixture.forbiddenHomeArtifacts().isEmpty, "\(fixture.forbiddenHomeArtifacts())")
    }
}

private enum DoorTestError: Error, CustomStringConvertible {
    case pairStart(String)
    case pairLink(String)
    case socket(String)

    var description: String {
        switch self {
        case .pairStart(let detail): return "same-machine pair-start failed: \(detail)"
        case .pairLink(let detail): return "same-machine pair link rejected: \(detail)"
        case .socket(let detail): return "loopback socket: \(detail)"
        }
    }
}

/// Raw blocking TCP against the loopback proxy, so the test controls exactly which bytes are
/// on the wire and when. Every descriptor is returned to the caller for closing.
private enum LoopbackHTTP {
    static func connect(port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DoorTestError.socket("socket() errno \(errno)") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw DoorTestError.socket("connect(127.0.0.1:\(port)) errno \(errno)")
        }
        return descriptor
    }

    /// Open a connection and send an incomplete request: headers without the terminating blank
    /// line, so the proxy allocates a stream and the door keeps it open waiting for the rest.
    static func connectAndHold(port: Int, path: String) throws -> Int32 {
        let descriptor = try connect(port: port)
        try sendAll(descriptor, "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n")
        return descriptor
    }

    /// One complete request; returns whatever the peer sent before closing or the read timeout.
    static func request(port: Int, path: String, readTimeoutSeconds: Int = 15) throws -> String {
        let descriptor = try connect(port: port)
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try sendAll(descriptor, "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                received.append(buffer, count: count)
                if received.count > 1_000_000 { break }
            } else {
                break
            }
        }
        return String(decoding: received, as: UTF8.self)
    }

    private static func sendAll(_ descriptor: Int32, _ text: String) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBufferPointer { pointer in
                send(descriptor, pointer.baseAddress! + offset, bytes.count - offset, 0)
            }
            guard sent > 0 else { throw DoorTestError.socket("send errno \(errno)") }
            offset += sent
        }
    }
}
