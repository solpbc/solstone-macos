// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SolstoneCore
import Testing
@testable import solstone

private func nativeHostVendorRoot(filePath: String = #filePath) -> URL {
    let sourceURL = URL(fileURLWithPath: filePath)
    return sourceURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vendor", isDirectory: true)
}

private func nativeHostProjection() throws -> BrowserContractProjection {
    try BrowserContractProjection(rootURL: nativeHostVendorRoot())
}

private final class MemoryByteSink: BrowserHostByteSink, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [Data] = []
    private var shouldFail = false

    func write(_ data: Data) async throws {
        try lock.withLock {
            if shouldFail {
                throw NSError(domain: "MemoryByteSink", code: -1)
            }
            written.append(data)
        }
    }

    var writtenData: [Data] {
        lock.withLock { written }
    }

    func setFailure(_ fail: Bool) {
        lock.withLock { shouldFail = fail }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.withLock { flag }
    }

    func set() {
        lock.withLock { flag = true }
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

@Suite("BrowserHostPureOutbound")
struct BrowserHostPureOutboundTests {
    @Test func outboundMailboxPrioritizationAndReplyBudget() async throws {
        let sink = MemoryByteSink()
        let outbound = BrowserHostOutbound(sink: sink)

        let state1 = Data("state-1".utf8)
        let state2 = Data("state-2".utf8)
        let boundary = Data("boundary-1".utf8)
        let reply1 = Data("reply-1".utf8)
        let reply2 = Data("reply-2".utf8)

        let budgetReleased1 = LockedFlag()
        let budgetReleased2 = LockedFlag()

        await outbound.enqueueState(state1)
        await outbound.enqueueState(state2)
        await outbound.enqueueBoundary(boundary)
        await outbound.enqueueReply(reply1) { budgetReleased1.set() }
        await outbound.enqueueReply(reply2) { budgetReleased2.set() }

        // Wait briefly for drain loop
        try await Task.sleep(for: .milliseconds(50))

        let written = sink.writtenData
        #expect(written.contains(state2))
        #expect(written.contains(boundary))
        #expect(written.contains(reply1))
        #expect(written.contains(reply2))
        #expect(budgetReleased1.value)
        #expect(budgetReleased2.value)

        let bye = Data("bye".utf8)
        await outbound.enqueueBye(bye)
        try await Task.sleep(for: .milliseconds(50))
        #expect(sink.writtenData.contains(bye))

        await outbound.close()
    }

    @Test func outboundCloseReleasesUnwrittenReplyBudgets() async throws {
        let sink = MemoryByteSink()
        sink.setFailure(true)
        let outbound = BrowserHostOutbound(sink: sink)

        let budgetReleased = LockedFlag()
        await outbound.enqueueReply(Data("blocked".utf8)) { budgetReleased.set() }
        await outbound.close()

        #expect(budgetReleased.value)
    }

    @Test func coalescedStateAndRenewal() async throws {
        let sink = MemoryByteSink()
        let outbound = BrowserHostOutbound(sink: sink)

        let stateA = Data("state-A".utf8)
        let stateB = Data("state-B".utf8)
        await outbound.enqueueState(stateA)
        await outbound.enqueueState(stateB)

        try await Task.sleep(for: .milliseconds(50))
        let initialWritten = sink.writtenData
        #expect(initialWritten.contains(stateB))

        // Simulate renewal sleeper firing and enqueueing renewed state via emitRenewalState
        let renewedState = Data("state-renewed".utf8)
        await BrowserHostListener.emitRenewalState(
            isCompatible: true,
            outbound: outbound,
            state: renewedState
        )
        try await Task.sleep(for: .milliseconds(50))

        let finalWritten = sink.writtenData
        #expect(finalWritten.contains(renewedState))

        await outbound.close()
    }
}

@Suite("BrowserHostPureAdmissionGate")
struct BrowserHostPureAdmissionGateTests {
    @Test func admissionGateGenerationAndCommitClose() {
        let gate = BrowserHostAdmissionGate()
        gate.install(listenerFD: -1, generation: 0)
        #expect(gate.isOpen())
        #expect(gate.isOpen(generation: 0))
        #expect(!gate.isOpen(generation: 1))

        // Commit close with wrong generation fails
        #expect(!gate.commitClose(reason: .ordinaryQuit, generation: 0))
        #expect(!gate.commitClose(reason: .ordinaryQuit, generation: 2))
        #expect(gate.isOpen())

        // Commit close with generation 1 succeeds
        let didCommit = gate.commitClose(reason: .ordinaryQuit, generation: 1)
        #expect(didCommit)
        #expect(!gate.isOpen())
        #expect(gate.committedClose(generation: 1)?.0 == .ordinaryQuit)

        // Reinstall at generation 2 ignores stale generation 1 close
        gate.install(listenerFD: -1, generation: 2)
        #expect(gate.isOpen(generation: 2))
        #expect(!gate.commitClose(reason: .ordinaryQuit, generation: 1))
        #expect(gate.isOpen(generation: 2))
        #expect(gate.commitClose(reason: .ordinaryQuit, generation: 3))
        #expect(!gate.isOpen(generation: 2))
    }

    @Test func lifecycleTransitions() {
        var lifecycle = BrowserHostLifecycle()
        lifecycle.install(generation: 0)
        #expect(lifecycle.admitsHello)
        let rejectedClose = lifecycle.beginClose(reason: .updaterInstall, generation: 0)
        #expect(!rejectedClose)
        let closed = lifecycle.beginClose(reason: .updaterInstall, generation: 1)
        #expect(closed)
        #expect(!lifecycle.admitsHello)
        #expect(lifecycle.quiescence)
        let rejectedQuiescence = lifecycle.finishQuiescence(generation: 0)
        #expect(!rejectedQuiescence)
        let finished = lifecycle.finishQuiescence(generation: 1)
        #expect(finished)
        #expect(!lifecycle.quiescence)
    }
}

@Suite("BrowserHostPureCommand")
struct BrowserHostPureCommandTests {
    @Test func commandParsingAndValidation() {
        #expect(BrowserHostCommand.command(arguments: ["solstone", "browser-host-check"]) != nil)
        #expect(BrowserHostCommand.command(arguments: ["solstone", "browser-host-repair", "--development"]) != nil)
        #expect(BrowserHostCommand.command(arguments: ["solstone", "browser-host-check", "--invalid"]) == nil)
        #expect(BrowserHostCommand.command(arguments: ["solstone", "browser-host-check", "--development", "extra"]) == nil)

        var outputText: [String] = []
        let status = BrowserHostCommand.run(arguments: ["solstone", "browser-host-check", "--unknown-flag"]) { outputText.append($0) }
        #expect(status == 2)
        #expect(outputText.contains("malformed"))
    }
}

@Suite("BrowserHostPureProfileTable")
struct BrowserHostPureProfileTableTests {
    @Test func profilesKeyedByBrandAndInst() {
        var table = BrowserHostProfileTable()
        let session1 = UUID()
        let session2 = UUID()
        let now = Date()

        let profileChrome1 = BrowserHostProfile(lastSeen: now, handshake: .compatible, byeReason: nil, leaseExpiry: now.addingTimeInterval(30))
        let profileChromeDuplicate = BrowserHostProfile(lastSeen: now.addingTimeInterval(1), handshake: .compatible, byeReason: nil, leaseExpiry: now.addingTimeInterval(31))
        let profileEdge1 = BrowserHostProfile(lastSeen: now, handshake: .compatible, byeReason: nil, leaseExpiry: now.addingTimeInterval(30))

        table.record(sessionID: session1, brand: .chrome, inst: "inst-1", profile: profileChrome1)
        // Recording chrome/inst-1 twice counts once
        table.record(sessionID: session1, brand: .chrome, inst: "inst-1", profile: profileChromeDuplicate)
        // Chrome and Edge with same inst both count
        table.record(sessionID: session2, brand: .edge, inst: "inst-1", profile: profileEdge1)

        #expect(table.count(.chrome) == 1)
        #expect(table.count(.edge) == 1)
        #expect(table.count(.firefox) == 0)

        table.disconnect(sessionID: session1)
        #expect(table.count(.chrome) == 0)
        #expect(table.count(.edge) == 1)
    }
}

@Suite("BrowserHostPureDispatch")
struct BrowserHostPureDispatchTests {
    @Test func decideFirstMessageHandling() async throws {
        let projection = try nativeHostProjection()
        let counter = AtomicCounter()
        let updateGate = BrowserHostUpdateGate(checkForUpdates: {
            counter.increment()
        })

        let contextChrome = BrowserHostConnectionContext(
            brandHint: .chromium,
            mode: .production
        )

        let helloJson = """
        {"type":"hello","protocol":\(projection.wireProtocol),"version":"1.0.0","brand":"chrome","inst":"inst-1"}
        """
        let helloData = Data(helloJson.utf8)

        // 1. Compatible hello
        let decision1 = await BrowserHostListener.decideFirstMessage(
            body: helloData,
            context: contextChrome,
            acceptingModes: [.production],
            isFresh: true,
            projection: projection,
            updateGate: updateGate
        )
        guard case .compatible(let brand, let inst, _) = decision1 else {
            Issue.record("Expected .compatible decision")
            return
        }
        #expect(brand == .chrome)
        #expect(inst == "inst-1")

        // 2. Non-fresh message returns .close
        let staleDecision = await BrowserHostListener.decideFirstMessage(
            body: helloData,
            context: contextChrome,
            acceptingModes: [.production],
            isFresh: false,
            projection: projection,
            updateGate: updateGate
        )
        #expect(staleDecision == .close)

        // 3. Wrong brand hint (firefox hint with chrome hello) returns .close
        let contextWrongHint = BrowserHostConnectionContext(
            brandHint: .firefox,
            mode: .production
        )
        let wrongHintDecision = await BrowserHostListener.decideFirstMessage(
            body: helloData,
            context: contextWrongHint,
            acceptingModes: [.production],
            isFresh: true,
            projection: projection,
            updateGate: updateGate
        )
        #expect(wrongHintDecision == .close)

        // 4. Non-matching mode returns .close
        let wrongModeDecision = await BrowserHostListener.decideFirstMessage(
            body: helloData,
            context: contextChrome,
            acceptingModes: [.development],
            isFresh: true,
            projection: projection,
            updateGate: updateGate
        )
        #expect(wrongModeDecision == .close)

        // 5. Malformed payload returns .close
        let malformedDecision = await BrowserHostListener.decideFirstMessage(
            body: Data("not json".utf8),
            context: contextChrome,
            acceptingModes: [.production],
            isFresh: true,
            projection: projection,
            updateGate: updateGate
        )
        #expect(malformedDecision == .close)

        // 6. App behind hello triggers updateGate
        let appBehindJson = """
        {"type":"hello","protocol":999,"version":"1.0.0","brand":"chrome","inst":"inst-1"}
        """
        let appBehindDecision = await BrowserHostListener.decideFirstMessage(
            body: Data(appBehindJson.utf8),
            context: contextChrome,
            acceptingModes: [.production],
            isFresh: true,
            projection: projection,
            updateGate: updateGate
        )
        guard case .unsupportedApp(let behindBrand, let behindInst) = appBehindDecision else {
            Issue.record("Expected .unsupportedApp decision")
            return
        }
        #expect(behindBrand == .chrome)
        #expect(behindInst == "inst-1")
        #expect(counter.value == 1)

        // Second app behind hello within rate limit interval does not trigger update callback again
        let appBehindDecision2 = await BrowserHostListener.decideFirstMessage(
            body: Data(appBehindJson.utf8),
            context: contextChrome,
            acceptingModes: [.production],
            isFresh: true,
            projection: projection,
            updateGate: updateGate
        )
        #expect(appBehindDecision2 == appBehindDecision)
        #expect(counter.value == 1)
    }
}

#endif
