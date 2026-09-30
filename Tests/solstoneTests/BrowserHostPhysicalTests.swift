// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
import Darwin
import Foundation
import SolstoneCore
import Testing
@testable import solstone

private func physicalRoot() throws -> URL {
    let root = URL(fileURLWithPath: "/private/var/tmp/bh-" + UUID().uuidString.prefix(12), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    return root
}

private func physicalPair() throws -> [Int32] {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
    for fd in pair {
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
    return pair
}

private func physicalRead(_ fd: Int32, limits: BrowserHostLimits = .helperFallback,
                          timeout: UInt64 = 2_000) async throws -> Data? {
    try await BrowserHostIO.perform {
        try NativeHostFrameIO.readFrame(from: fd, direction: .hostToExtension, limits: limits,
                                       firstByteTimeoutMs: timeout)?.body
    }
}

private func physicalWrite(_ body: Data, to fd: Int32) async throws {
    try await BrowserHostIO.perform {
        try NativeHostFrameIO.writeFrame(body, to: fd, direction: .extensionToHost, timeoutMs: 2_000)
    }
}

private func physicalObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func physicalEOF(_ fd: Int32, timeout: UInt64 = 2_000) async throws -> Bool {
    let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor")
    let projection = try BrowserContractProjection(rootURL: vendor)
    let deadline = DispatchTime.now().uptimeNanoseconds + timeout * 1_000_000
    for _ in 0..<8 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            Issue.record("Socket EOF was not observed before the absolute deadline")
            return false
        }
        let remaining = max(1, (deadline - now) / 1_000_000)
        let limits = BrowserHostLimits(extensionToHost: 33_554_432, hostToExtension: 65_536,
                                      control: 65_536, partialFrameMs: remaining)
        do {
            let data = try await BrowserHostIO.perform {
                try NativeHostFrameIO.readFrame(from: fd, direction: .hostToExtension, limits: limits,
                    firstByteTimeoutMs: remaining,
                    shouldCancel: { DispatchTime.now().uptimeNanoseconds >= deadline })?.body
            }
            guard let data else { return true }
            let object = try physicalObject(data)
            let type = object["type"] as? String
            guard type == "state" || type == "boundary" else {
                Issue.record("Socket EOF observation received an unexpected control: \(type ?? "missing type")")
                return false
            }
            // Status publication may have queued a valid period boundary before closure.
            _ = try BrowserPayloadDecoder.validatedHostMessage(object, projection: projection)
        } catch NativeHostFrameError.timedOut {
            Issue.record("Socket EOF was not observed before the IO deadline")
            return false
        }
    }
    Issue.record("Socket EOF observation exhausted its bounded control-message count")
    return false
}

private func physicalMessage(_ type: String, from fd: Int32, timeout: UInt64 = 2_000) async throws -> [String: Any] {
    for _ in 0..<8 {
        let object = try physicalObject(try #require(await physicalRead(fd, timeout: timeout)))
        if object["type"] as? String == type { return object }
    }
    throw POSIXError(.EBADMSG)
}

private func physicalBatch(generation: String, inst: String, id: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "batch", "destination_generation": generation, "inst": inst, "batch_id": id,
        "queued_at_ms": UInt64(Date().timeIntervalSince1970 * 1_000),
        "records": [["t": "segment_start", "ts": 1, "ctx": inst + "-context", "inst": inst,
                     "blocks": [["id": "b", "text": "synthetic authority witness"]]]]
    ], options: [.sortedKeys])
}

private func physicalHello(_ fd: Int32, inst: String, brand: String = "chrome") async throws -> [String: Any] {
    try await physicalWrite(Data("{\"type\":\"local_hello\",\"brand\":\"chromium\",\"mode\":\"production\"}".utf8), to: fd)
    try await physicalWrite(Data("{\"type\":\"hello\",\"protocol\":1,\"version\":\"1.1.0\",\"brand\":\"\(brand)\",\"inst\":\"\(inst)\"}".utf8), to: fd)
    return try await physicalMessage("hello_ack", from: fd)
}

private func physicalWasReplaced(_ fd: Int32) async throws -> Bool {
    for _ in 0..<8 {
        do {
            guard let data = try await physicalRead(fd, timeout: 2_000) else { return true }
            let object = try physicalObject(data)
            if object["type"] as? String == "bye" {
                #expect(object["reason"] as? String == "replaced")
                return true
            }
        } catch NativeHostFrameError.timedOut { return false }
    }
    throw POSIXError(.EBADMSG)
}

private func physicalHelloGeneration(_ fd: Int32, inst: String) async throws -> String {
    let hello = try await physicalHello(fd, inst: inst)
    return try #require(hello["destination_generation"] as? String)
}

@Suite("BrowserHostFramedTransport")
struct BrowserHostFramedTransportTests {
    @Test func eofObserverDrainsAValidatedBoundaryBeforeClosure() async throws {
        let pair = try physicalPair()
        defer { for fd in pair { Darwin.close(fd) } }
        let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor")
        let projection = try BrowserContractProjection(rootURL: vendor)
        let message = try BrowserPayloadDecoder.validatedHostMessage([
            "type": "boundary", "destination_generation": "observer-epoch", "period_id": "observer-period"
        ], projection: projection)
        let body = BrowserPayloadDecoder.encodeHostToExtension(message)
        try await BrowserHostIO.perform {
            try NativeHostFrameIO.writeFrame(body, to: pair[0], direction: .hostToExtension, timeoutMs: 2_000)
        }
        #expect(shutdown(pair[0], SHUT_WR) == 0)
        #expect(try await physicalEOF(pair[1]))
    }

    @Test func backpressureDoesNotInterleaveFrames() async throws {
        let pair = try physicalPair()
        defer { for fd in pair { Darwin.close(fd) } }
        var sendBuffer: Int32 = 4_096
        #expect(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer,
                          socklen_t(MemoryLayout<Int32>.size)) == 0)
        let limits = BrowserHostLimits(extensionToHost: 1_048_576, hostToExtension: 1_048_576,
                                      control: 65_536, partialFrameMs: 2_000)
        let outbound = BrowserHostOutbound(sink: FDByteSink(fd: pair[0], limits: limits))
        let first = Data(repeating: 65, count: 524_288)
        let second = Data(repeating: 66, count: 16_384)
        await outbound.enqueueReply(first, budgetRelease: {})
        await outbound.enqueueReply(second, budgetRelease: {})
        // A socket with a small send buffer forces the first serialized write to stall.
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await physicalRead(pair[1], limits: limits) == first)
        #expect(try await physicalRead(pair[1], limits: limits) == second)
        await outbound.finish()
    }

    @Test func cancellationUnblocksPendingWrite() async throws {
        let pair = try physicalPair()
        defer { for fd in pair { Darwin.close(fd) } }
        var sendBuffer: Int32 = 4_096
        #expect(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer,
                          socklen_t(MemoryLayout<Int32>.size)) == 0)
        let limits = BrowserHostLimits(extensionToHost: 1_048_576, hostToExtension: 1_048_576,
                                      control: 65_536, partialFrameMs: 2_000)
        let outbound = BrowserHostOutbound(sink: FDByteSink(fd: pair[0], limits: limits))
        await outbound.enqueueReply(Data(repeating: 65, count: 1_048_576), budgetRelease: {})
        // Confirm bytes reached the peer while it intentionally does not drain them.
        let ready = try await BrowserHostIO.perform { () -> Bool in
            var probe = pollfd(fd: pair[1], events: Int16(POLLIN), revents: 0)
            return poll(&probe, 1, 1_000) > 0
        }
        #expect(ready)
        let started = ProcessInfo.processInfo.systemUptime
        await outbound.close()
        await outbound.flush()
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
    }

    @Test func closedOriginalDescriptorCannotRedirectOwnedWriter() async throws {
        let pair = try physicalPair()
        let original = pair[0]
        let sink = FDByteSink(fd: original, limits: .helperFallback)
        Darwin.close(original)
        let replacement = try physicalPair()
        defer { Darwin.close(pair[1]); for fd in replacement { Darwin.close(fd) } }
        // The replacement may reuse the original integer; sink's duplicate still owns the old socket.
        let data = Data("{\"type\":\"bye\",\"reason\":\"shutdown\"}".utf8)
        try await sink.write(data)
        #expect(try await physicalRead(pair[1]) == data)
        var probe = pollfd(fd: replacement[1], events: Int16(POLLIN), revents: 0)
        #expect(poll(&probe, 1, 0) == 0)
        sink.cancel()
    }
}

@Suite("BrowserHostFenceFiles")
struct BrowserHostFenceFilesTests {
    @Test func normalDarwinBindAndConnectUseFilesystemIdentity() throws {
        let root = try physicalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fence = BrowserHostEndpointFence(rootURL: root)
        defer { fence.release() }
        #expect(fence.inspectEndpoint() == .absent)
        _ = try fence.bindListener()
        #expect(fence.inspectEndpoint() == .live)
        let connection = NativeHostEndpoint.connect(path: root.appendingPathComponent("host.sock").path)
        let peer = try #require(connection.descriptor)
        Darwin.close(peer)
        fence.closeListener()
        #expect(fence.inspectEndpoint() == .stale)
        fence.release()
        #expect(fence.inspectEndpoint() == .absent)
    }

    @Test func unknownOrReplacedFenceRefusesUnlink() throws {
        let root = try physicalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BrowserHostEndpointFence(rootURL: root)
        defer { owner.release() }
        _ = try owner.bindListener()
        owner.closeListener()
        let socket = root.appendingPathComponent("host.sock")
        let provenance = root.appendingPathComponent("host.fence")
        try FileManager.default.removeItem(at: provenance)
        try Data("unknown\n".utf8).write(to: provenance)
        #expect(chmod(provenance.path, 0o600) == 0)
        let repair = BrowserHostEndpointFence(rootURL: root)
        #expect(try repair.repairStaleEndpoint() == .refused)
        #expect(FileManager.default.fileExists(atPath: socket.path))
        #expect(repair.inspectEndpoint() == .refused)
        owner.release()
        #expect(FileManager.default.fileExists(atPath: socket.path))
    }

    @Test func cleanupDoesNotDeleteReplacementSocket() throws {
        let root = try physicalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BrowserHostEndpointFence(rootURL: root)
        _ = try owner.bindListener()
        let endpoint = root.appendingPathComponent("host.sock")
        try FileManager.default.removeItem(at: endpoint)
        let replacement = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(replacement) }
        var address = try #require(NativeHostEndpoint.address(endpoint.path))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(replacement, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(result == 0)
        #expect(chmod(endpoint.path, 0o600) == 0)
        owner.release()
        #expect(FileManager.default.fileExists(atPath: endpoint.path))
    }

    @Test func helperConnectRejectsSymlinkAndUnsafeOwnerMode() throws {
        let root = try physicalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fence = BrowserHostEndpointFence(rootURL: root)
        defer { fence.release() }
        _ = try fence.bindListener()
        let socket = root.appendingPathComponent("host.sock")
        let link = root.appendingPathComponent("link.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: socket)
        #expect(NativeHostEndpoint.connect(path: link.path).descriptor == nil)
        #expect(chmod(socket.path, 0o666) == 0)
        #expect(NativeHostEndpoint.connect(path: socket.path).descriptor == nil)
        #expect(chmod(socket.path, 0o600) == 0)
        let good = NativeHostEndpoint.connect(path: socket.path)
        Darwin.close(try #require(good.descriptor))
    }

    @Test func readOnlyCheckCreatesNoFiles() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp/bh-" + UUID().uuidString.prefix(12), isDirectory: true)
        #expect(BrowserHostEndpointFence(rootURL: root).inspectEndpoint() == .absent)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func overlongPathRefusesBeforeMutation() throws {
        let root = try physicalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(String(repeating: "x", count: 110), isDirectory: true)
        #expect(NativeHostEndpoint.connect(path: path.appendingPathComponent("host.sock").path).descriptor == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}

private final class PhysicalUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private struct PhysicalTransport: BrowserUploadTransport {
    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay { throw POSIXError(.ENETDOWN) }
    func prepareUpload(serverURL: String, day: String, segment: String, mediaFiles: [URL], metadata: [String: IngestJSONValue]?, source: String?, boundary: String, bodyURL: URL, ioInjector: BrowserIntakeIOInjector) throws -> PreparedIngestV3Upload { throw POSIXError(.ENETDOWN) }
    func uploadStaged(prepared: PreparedIngestV3Upload, lease: BrowserUploadLease) async -> UploadResult { .failure(POSIXError(.ENETDOWN)) }
}

private final class PhysicalListenerFixture {
    let root: URL
    let owner: BrowserIntakeOwner
    let projection: BrowserContractProjection
    let snapshot: BrowserHostSnapshot
    let listener: BrowserHostListener
    var generation = 0

    init(sleeper: @escaping BrowserHostListener.Sleeper = { try? await Task.sleep(for: $0) },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         publicationWillEnqueue: @escaping @Sendable () async -> Void = {},
         beforeBatchAdmission: @escaping @Sendable () async -> Void = {}) async throws {
        root = try physicalRoot()
        let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor")
        projection = try BrowserContractProjection(rootURL: vendor)
        owner = try BrowserIntakeOwner.start(spoolRoot: root.appendingPathComponent("spool"), projection: projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "physical-test-identity"),
            transport: PhysicalTransport(), routeResolver: HomeBaseURLResolver { .url("http://127.0.0.1:1") }, syncPaused: { true })
        snapshot = await MainActor.run { BrowserHostSnapshot() }
        listener = BrowserHostListener(limits: BrowserHostLimits(projection: projection), snapshot: snapshot,
            updateGate: BrowserHostUpdateGate(checkForUpdates: {}), sleeper: sleeper, uptime: uptime,
            publicationWillEnqueue: publicationWillEnqueue, beforeBatchAdmission: beforeBatchAdmission)
        await owner.start()
    }

    func start() async {
        await listener.start(rootURL: root.appendingPathComponent("endpoint"), owner: owner, projection: projection,
                             registration: BrowserHostRegistrationReport(outcomes: [:], changedAny: false), generation: generation)
    }

    func openConnection() throws -> Int32 {
        let connection = NativeHostEndpoint.connect(path: root.appendingPathComponent("endpoint/host.sock").path)
        return try #require(connection.descriptor)
    }

    func connect(inst: String = "physical-instance", brand: String = "chrome") async throws -> Int32 {
        let fd = try openConnection()
        do {
            let hello = try await physicalHello(fd, inst: inst, brand: brand)
            #expect(hello["capture"] as? String == "permitted")
            _ = try await physicalMessage("state", from: fd)
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    func cleanup() async {
        await listener.close(reason: .ordinaryQuit, generation: generation + 1)
        await owner.stopAndDrain()
        try? FileManager.default.removeItem(at: root)
    }
}

private func withPhysicalListener(
    sleeper: @escaping BrowserHostListener.Sleeper = { try? await Task.sleep(for: $0) },
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    publicationWillEnqueue: @escaping @Sendable () async -> Void = {},
    beforeBatchAdmission: @escaping @Sendable () async -> Void = {},
    _ operation: (PhysicalListenerFixture) async throws -> Void
) async throws {
    let fixture = try await PhysicalListenerFixture(sleeper: sleeper, uptime: uptime,
                                                   publicationWillEnqueue: publicationWillEnqueue,
                                                   beforeBatchAdmission: beforeBatchAdmission)
    do { try await operation(fixture); await fixture.cleanup() }
    catch { await fixture.cleanup(); throw error }
}

private actor PhysicalPublicationSuspension {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arm() { armed = true }
    func suspendOnce() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
    func waitUntilSuspended() async {
        if continuation != nil || !armed { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() {
        armed = false
        continuation?.resume(); continuation = nil
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor PhysicalAdmissionBarrier {
    private var holders: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func hold() async {
        if released { return }
        await withCheckedContinuation { continuation in
            holders.append(continuation)
            if holders.count == 2 {
                for observer in observers { observer.resume() }
                observers.removeAll()
            }
        }
    }
    func waitForBoth() async {
        if released || holders.count >= 2 { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        for holder in holders { holder.resume() }
        holders.removeAll()
        for observer in observers { observer.resume() }
        observers.removeAll()
    }
}

@Suite("BrowserHostListenerRestart")
struct BrowserHostListenerRestartTests {
    @Test func firstQuitClosesStartupGenerationListener() async throws {
        try await withPhysicalListener { fixture in
            await fixture.start()
            #expect(await fixture.listener.holdsEndpointFence)
            let fd = try await fixture.connect()
            defer { Darwin.close(fd) }
            // Leave native input fragmented while real shutdown runs.
            var partial: [UInt8] = [32, 0]
            #expect(Darwin.write(fd, &partial, partial.count) == partial.count)
            let listener = fixture.listener
            let coordinator = await MainActor.run {
                AppQuitCoordinator(dependencies: .init(writeMarker: { _ in true },
                    closeBrowserHost: { reason, generation in listener.commitClose(reason: reason, generation: generation) },
                    prepareForQuit: { await listener.finishCommittedClose(generation: 1) }))
            }
            await coordinator.requestAppOwnedQuit()
            let bye = try await physicalMessage("bye", from: fd)
            #expect(bye["reason"] as? String == "shutdown")
            await fixture.listener.finishCommittedClose(generation: 1)
            #expect(await !fixture.listener.holdsEndpointFence)
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("endpoint/host.sock").path))
        }
    }

    @Test func quitBeforeStartupCannotReopenAdmission() async throws {
        try await withPhysicalListener { fixture in
            fixture.listener.commitClose(reason: .ordinaryQuit, generation: 1)
            await fixture.start()
            await fixture.listener.finishCommittedClose(generation: 1)
            #expect(await !fixture.listener.holdsEndpointFence)
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("endpoint/host.sock").path))
        }
    }

    @Test func failedUpdateRecoveryStartsSingleListener() async throws {
        try await withPhysicalListener { fixture in
            await fixture.start()
            let original = try await fixture.connect()
            defer { Darwin.close(original) }
            let epoch = fixture.owner.store.getActiveGeneration()
            let listener = fixture.listener, owner = fixture.owner
            let coordinator = await MainActor.run {
                AppQuitCoordinator(dependencies: .init(writeMarker: { _ in true },
                    closeBrowserHost: { reason, generation in listener.commitClose(reason: reason, generation: generation) },
                    invalidateMarker: {}, prepareForUpdate: {
                        await listener.finishCommittedClose(generation: 1)
                        await owner.stopAndDrain()
                    }))
            }
            await coordinator.prepareForUpdaterInstall()
            #expect(try await physicalMessage("bye", from: original)["reason"] as? String == "update")
            await coordinator.resetAfterFailedUpdaterInstall()
            await owner.resumeAfterFailedUpdate(
                credentialSnapshot: BrowserCredentialSnapshot(identityToken: "physical-test-identity"), paused: false)
            fixture.generation = 2
            await fixture.listener.resumeAfterFailedUpdaterInstall(generation: 2)
            await fixture.listener.resumeAfterFailedUpdaterInstall(generation: 2)
            #expect(await fixture.listener.holdsEndpointFence)
            let replacement = try await fixture.connect(inst: "recovered-instance")
            defer { Darwin.close(replacement) }
            #expect(fixture.owner.store.getActiveGeneration() == epoch)
            let colliding = BrowserHostEndpointFence(rootURL: fixture.root.appendingPathComponent("endpoint"))
            #expect(throws: BrowserHostListenerError.endpointCollision) { _ = try colliding.bindListener() }
        }
    }

    @Test func staleCallbackDoesNotAffectActiveListener() async throws {
        try await withPhysicalListener { fixture in
            await fixture.start()
            await fixture.listener.close(reason: .updaterInstall, generation: 1)
            fixture.generation = 2
            await fixture.listener.resumeAfterFailedUpdaterInstall(generation: 2)
            fixture.listener.commitClose(reason: .ordinaryQuit, generation: 1)
            await fixture.listener.finishCommittedClose(generation: 1)
            #expect(await fixture.listener.holdsEndpointFence)
            let active = try await fixture.connect()
            defer { Darwin.close(active) }
        }
    }

    @Test func reconnectSupersedesOldSessionWithoutDoubleCounting() async throws {
        try await withPhysicalListener { fixture in
            await fixture.start()
            let old = try await fixture.connect()
            defer { Darwin.close(old) }
            let replacement = try await fixture.connect()
            defer { Darwin.close(replacement) }
            #expect(try await physicalMessage("bye", from: old)["reason"] as? String == "replaced")
            await fixture.listener.refreshSnapshot()
            let snapshot = fixture.snapshot
            let counts = await MainActor.run { snapshot.value.profiles.chrome.filter { $0.leaseExpiry != nil }.count }
            #expect(counts == 1)
        }
    }

    @Test func concurrentReplacementRejectsAlreadyDecodedOldBatch() async throws {
        let suspension = PhysicalPublicationSuspension()
        try await withPhysicalListener(beforeBatchAdmission: { await suspension.suspendOnce() }) { fixture in
            await fixture.start()
            let old = try await fixture.connect()
            defer { Darwin.close(old) }
            let generation = try #require(fixture.owner.store.getActiveGeneration())
            let oldID = "cccccccccccccccccccccccccccccccc"
            let oldBatch = try physicalBatch(generation: generation, inst: "physical-instance", id: oldID)
            await suspension.arm()
            do {
                try await physicalWrite(oldBatch, to: old)
                try await withTimeout(seconds: 10) { await suspension.waitUntilSuspended() }
                let first = try fixture.openConnection()
                defer { Darwin.close(first) }
                let second = try fixture.openConnection()
                defer { Darwin.close(second) }
                async let firstHello = physicalHelloGeneration(first, inst: "physical-instance")
                async let secondHello = physicalHelloGeneration(second, inst: "physical-instance")
                let hellos = try await (firstHello, secondHello)
                #expect(hellos.0 == generation)
                #expect(hellos.1 == generation)
                async let firstLost = physicalWasReplaced(first)
                async let secondLost = physicalWasReplaced(second)
                let lost = try await (firstLost, secondLost)
                try #require(lost.0 != lost.1)
                #expect(try await physicalMessage("bye", from: old)["reason"] as? String == "replaced")
                await suspension.resume()
                await fixture.listener.flushOutput()
                #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: "physical-instance", batchId: oldID) == nil)
                let surviving = lost.0 ? second : first
                let newID = "dddddddddddddddddddddddddddddddd"
                try await physicalWrite(physicalBatch(generation: generation, inst: "physical-instance", id: newID), to: surviving)
                #expect(try await physicalMessage("accepted", from: surviving)["result"] as? String == "accepted")
                #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: "physical-instance", batchId: newID)?.result == "accepted")
                await fixture.listener.refreshSnapshot()
                let snapshot = fixture.snapshot
                #expect(await MainActor.run { snapshot.value.profiles.chrome.filter { $0.leaseExpiry != nil }.count } == 1)
                await fixture.listener.close(reason: .ordinaryQuit, generation: fixture.generation + 1)
                #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: "physical-instance", batchId: oldID) == nil)
            } catch { await suspension.resume(); throw error }
        }
    }

    @Test(arguments: [false, true])
    func sessionInstanceMismatchClosesBeforeAdmissionWithMatchedTwin(unicode: Bool) async throws {
        let bound = unicode ? "\u{00E9}" : "bound-instance"
        let other = unicode ? "e\u{0301}" : "other-instance"
        #expect(!BrowserOpaqueString.equals(bound, other))
        try await withPhysicalListener { fixture in
            await fixture.start()
            let fd = try await fixture.connect(inst: bound)
            defer { Darwin.close(fd) }
            let generation = try #require(fixture.owner.store.getActiveGeneration())
            let id = "cccccccccccccccccccccccccccccccc"
            let batch = try physicalBatch(generation: generation, inst: other, id: id)
            guard case .accept(.batch) = BrowserPayloadDecoder.decode(bytes: batch, direction: "extension_to_host", projection: fixture.projection) else {
                Issue.record("Mismatch witness must first pass batch decoding")
                return
            }
            let period = fixture.owner.store.getOpenPeriodId()
            try await physicalWrite(batch, to: fd)
            #expect(try await physicalEOF(fd))
            #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: other, batchId: id) == nil)
            #expect(fixture.owner.store.getOpenPeriodId() == period)
            let matched = try await fixture.connect(inst: bound)
            defer { Darwin.close(matched) }
            try await physicalWrite(physicalBatch(generation: generation, inst: bound, id: id), to: matched)
            #expect(try await physicalMessage("accepted", from: matched)["result"] as? String == "accepted")
            #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: bound, batchId: id)?.result == "accepted")
        }
    }

    @Test func canonicallyEquivalentInstancesStayDistinctAndExactReconnectReplacesOnlyOne() async throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        #expect(composed == decomposed)
        #expect(!BrowserOpaqueString.equals(composed, decomposed))
        try await withPhysicalListener { fixture in
            await fixture.start()
            let first = try await fixture.connect(inst: composed)
            defer { Darwin.close(first) }
            let second = try await fixture.connect(inst: decomposed)
            defer { Darwin.close(second) }
            let generation = try #require(fixture.owner.store.getActiveGeneration())
            for (fd, inst, id) in [(first, composed, "cccccccccccccccccccccccccccccccc"),
                                   (second, decomposed, "dddddddddddddddddddddddddddddddd")] {
                try await physicalWrite(physicalBatch(generation: generation, inst: inst, id: id), to: fd)
                #expect(try await physicalMessage("accepted", from: fd)["result"] as? String == "accepted")
                let receipt = try #require(try fixture.owner.store.lookupReceipt(generation: generation, inst: inst, batchId: id))
                #expect(BrowserOpaqueString.equals(receipt.inst, inst))
            }
            let replacement = try await fixture.connect(inst: composed)
            defer { Darwin.close(replacement) }
            #expect(try await physicalMessage("bye", from: first)["reason"] as? String == "replaced")
            for (fd, inst, id) in [(replacement, composed, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
                                   (second, decomposed, "ffffffffffffffffffffffffffffffff")] {
                try await physicalWrite(physicalBatch(generation: generation, inst: inst, id: id), to: fd)
                #expect(try await physicalMessage("accepted", from: fd)["result"] as? String == "accepted")
                #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: inst, batchId: id)?.result == "accepted")
            }
            await fixture.listener.refreshSnapshot()
            let snapshot = fixture.snapshot
            #expect(await MainActor.run { snapshot.value.profiles.chrome.filter { $0.leaseExpiry != nil }.count } == 2)
        }
    }

    @Test func newSessionAnswersRetiredAcceptedReplayBeforeStaleGeneration() async throws {
        try await withPhysicalListener { fixture in
            await fixture.start()
            let old = try await fixture.connect()
            defer { Darwin.close(old) }
            let generationA = try #require(fixture.owner.store.getActiveGeneration())
            let acceptedID = "cccccccccccccccccccccccccccccccc"
            let neverID = "dddddddddddddddddddddddddddddddd"
            let acceptedBytes = try physicalBatch(generation: generationA, inst: "physical-instance", id: acceptedID)
            try await physicalWrite(acceptedBytes, to: old)
            let accepted = try await physicalMessage("accepted", from: old)
            #expect(accepted["result"] as? String == "accepted")
            let periodID = try #require(accepted["period_id"] as? String)
            let receipt = try fixture.owner.store.lookupReceipt(generation: generationA, inst: "physical-instance", batchId: acceptedID)
            try fixture.owner.credentialWillChange(identityToken: "replacement-physical-identity")
            try fixture.owner.credentialDidChange(identityToken: "replacement-physical-identity")
            let generationB = try #require(fixture.owner.store.getActiveGeneration())
            #expect(generationA != generationB)
            await fixture.listener.refreshSnapshot()
            let payload = try Data(contentsOf: fixture.owner.store.periodFileURL(for: periodID))
            let directory = fixture.root.appendingPathComponent("spool/periods")
            let inventory = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            let new = try fixture.openConnection()
            defer { Darwin.close(new) }
            let hello = try await physicalHello(new, inst: "physical-instance")
            #expect(hello["destination_generation"] as? String == generationB)
            _ = try await physicalMessage("state", from: new)
            try await physicalWrite(acceptedBytes, to: new)
            let replay = try await physicalMessage("accepted", from: new)
            #expect(replay["result"] as? String == "duplicate")
            #expect(replay["period_id"] as? String == periodID)
            try await physicalWrite(physicalBatch(generation: generationA, inst: "physical-instance", id: neverID), to: new)
            let never = try await physicalMessage("accepted", from: new)
            #expect(never["result"] as? String == "rejected")
            #expect(never["reason"] as? String == "stale_generation")
            #expect(never["class"] as? String == "permanent")
            #expect(fixture.owner.store.getActiveGeneration() == generationB)
            #expect(try fixture.owner.store.lookupReceipt(generation: generationA, inst: "physical-instance", batchId: acceptedID) == receipt)
            #expect(try fixture.owner.store.lookupReceipt(generation: generationA, inst: "physical-instance", batchId: neverID) == nil)
            #expect(try Data(contentsOf: fixture.owner.store.periodFileURL(for: periodID)) == payload)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == inventory)
        }
    }

    @Test func realScheduledRenewalKeepsIdleSessionLive() async throws {
        try await withPhysicalListener { fixture in
            await fixture.start()
            let fd = try await fixture.connect()
            defer { Darwin.close(fd) }
            // Status notifications may also emit states. Measure actual monotonic time,
            // rather than inferring timer firings from the number of frames.
            let connectedAt = ContinuousClock.now
            while connectedAt.duration(to: .now) < .seconds(16) {
                let renewal = try await physicalMessage("state", from: fd, timeout: 7_000)
                #expect(renewal["capture"] as? String == "permitted")
            }
            #expect(connectedAt.duration(to: .now) > .seconds(15))
            let generation = try #require(fixture.owner.store.getActiveGeneration())
            let batchID = "dddddddddddddddddddddddddddddddd"
            let batch = Data("{\"type\":\"batch\",\"destination_generation\":\"\(generation)\",\"inst\":\"physical-instance\",\"batch_id\":\"\(batchID)\",\"queued_at_ms\":\(UInt64(Date().timeIntervalSince1970 * 1_000)),\"records\":[{\"t\":\"segment_start\",\"ts\":1,\"ctx\":\"renewal-context\",\"inst\":\"physical-instance\",\"blocks\":[{\"id\":\"block\",\"text\":\"synthetic renewal witness\"}]}]}".utf8)
            try await physicalWrite(batch, to: fd)
            let receipt = try await physicalMessage("accepted", from: fd)
            #expect(receipt["batch_id"] as? String == batchID)
            #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: "physical-instance", batchId: batchID)?.result == "accepted")
            #expect(await fixture.listener.holdsEndpointFence)
        }
    }

    @Test func supersededPublicationCannotRestorePermittedAfterIntakeOff() async throws {
        let suspension = PhysicalPublicationSuspension()
        try await withPhysicalListener(publicationWillEnqueue: { await suspension.suspendOnce() }) { fixture in
            await fixture.start()
            let fd = try await fixture.connect()
            defer { Darwin.close(fd) }
            await suspension.arm()
            let listener = fixture.listener
            let oldPass = Task { await listener.refreshSnapshot() }
            await suspension.waitUntilSuspended()
            await fixture.owner.setIntakeEnabled(false)
            await fixture.listener.refreshSnapshot()
            await suspension.resume()
            await oldPass.value
            await fixture.listener.flushOutput()
            var states: [String] = []
            for _ in 0..<8 {
                do {
                    guard let data = try await physicalRead(fd, timeout: 150) else {
                        Issue.record("Intake-off publication unexpectedly closed the peer")
                        break
                    }
                    let message = try physicalObject(data)
                    if message["type"] as? String == "state", let capture = message["capture"] as? String {
                        states.append(capture)
                    }
                } catch NativeHostFrameError.timedOut { break }
            }
            #expect(!states.isEmpty)
            #expect(states.allSatisfy { $0 == "intake_off" })
            let snapshot = fixture.snapshot
            let value = await MainActor.run { snapshot.value }
            #expect(!value.intakeEnabled)
        }
    }

    @Test func decodedSessionsShareTheActualAggregateInputBudget() async throws {
        let barrier = PhysicalAdmissionBarrier()
        try await withPhysicalListener(beforeBatchAdmission: { await barrier.hold() }) { fixture in
            await fixture.start()
            let firstFD = try await fixture.connect(inst: "large-first")
            defer { Darwin.close(firstFD) }
            let secondFD = try await fixture.connect(inst: "large-second")
            defer { Darwin.close(secondFD) }
            let thirdFD = try await fixture.connect(inst: "large-third")
            defer { Darwin.close(thirdFD) }
            let generation = try #require(fixture.owner.store.getActiveGeneration())
            func body(inst: String, id: String) -> Data {
                var data = Data("{\"type\":\"batch\",\"destination_generation\":\"\(generation)\",\"inst\":\"\(inst)\",\"batch_id\":\"\(id)\",\"queued_at_ms\":\(UInt64(Date().timeIntervalSince1970 * 1_000)),\"records\":[{\"t\":\"segment_start\",\"ts\":1,\"ctx\":\"\(inst)-context\",\"inst\":\"\(inst)\",\"blocks\":[{\"id\":\"b\",\"text\":\"synthetic aggregate input\"}],\"padding\":\"".utf8)
                let suffix = Data("\"}]}".utf8)
                data.append(Data(repeating: 120, count: 20 * 1_024 * 1_024 - data.count - suffix.count))
                data.append(suffix)
                return data
            }
            let firstID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            let secondID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            let first = body(inst: "large-first", id: firstID)
            let second = body(inst: "large-second", id: secondID)
            do {
                async let firstWrite: Void = physicalWrite(first, to: firstFD)
                async let secondWrite: Void = physicalWrite(second, to: secondFD)
                try await (firstWrite, secondWrite)
                try await withTimeout(seconds: 30) { await barrier.waitForBoth() }
                // Each decoded batch holds 20 MiB raw plus at least 40 MiB working.
                // A third legitimate 20 MiB length exceeds the production 128 MiB budget.
                // The guard must close before waiting for that body's bytes.
                var size = UInt32(first.count).littleEndian
                #expect(Darwin.write(thirdFD, &size, MemoryLayout<UInt32>.size) == MemoryLayout<UInt32>.size)
                #expect(try await physicalEOF(thirdFD, timeout: 2_000))
                await barrier.release()
                #expect(try await physicalMessage("accepted", from: firstFD, timeout: 10_000)["batch_id"] as? String == firstID)
                #expect(try await physicalMessage("accepted", from: secondFD, timeout: 10_000)["batch_id"] as? String == secondID)
                #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: "large-first", batchId: firstID)?.result == "accepted")
                #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: "large-second", batchId: secondID)?.result == "accepted")
            } catch {
                await barrier.release()
                throw error
            }
        }
    }

    @Test func expiredLeaseCannotAdmitNewBatch() async throws {
        let uptime = PhysicalUptime()
        try await withPhysicalListener(sleeper: { _ in try? await Task.sleep(for: .seconds(3_600)) }, uptime: { uptime.now() }) { fixture in
            await fixture.start()
            let fd = try await fixture.connect()
            defer { Darwin.close(fd) }
            uptime.advance(16)
            let generation = try #require(fixture.owner.store.getActiveGeneration())
            let batch = Data("{\"type\":\"batch\",\"destination_generation\":\"\(generation)\",\"inst\":\"physical-instance\",\"batch_id\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"queued_at_ms\":\(UInt64(Date().timeIntervalSince1970 * 1_000)),\"records\":[{\"t\":\"segment_start\",\"ts\":1,\"ctx\":\"physical-context\",\"inst\":\"physical-instance\",\"blocks\":[{\"id\":\"block\",\"text\":\"synthetic expiry witness\"}]}]}".utf8)
            try? await physicalWrite(batch, to: fd)
            #expect(try await physicalRead(fd) == nil)
            #expect(try fixture.owner.store.lookupReceipt(generation: generation, inst: "physical-instance",
                batchId: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee") == nil)
            await fixture.listener.refreshSnapshot()
            let snapshot = fixture.snapshot
            let profiles = await MainActor.run { snapshot.value.profiles.chrome }
            #expect(profiles.allSatisfy { $0.leaseExpiry == nil })
        }
    }
}
#endif
