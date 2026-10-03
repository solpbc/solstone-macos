// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import AppKit
import Foundation
import SolstoneCore
import SPLTunnel
import SQLite3
import Testing
@testable import solstone

private enum LifecycleInjectedFailure: Error {
    case injected
    case unexpectedRefusal(String)
}

private actor LifecycleDiscardResultBarrier {
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held }
    func suspend() async {
        await withCheckedContinuation { continuation in
            held = true
            self.continuation = continuation
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class LifecycleFailurePublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private var released = false
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    func check(_ point: BrowserIntakeIOPoint) throws {
        if point == .step, lock.withLock({ () -> Bool in
            guard armed else { return false }; armed = false; return true
        }) { throw LifecycleInjectedFailure.injected }
        if point == .ownerFailurePublication, !lock.withLock({ released }) {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
        }
    }
    func waitUntilHeld() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + 3) == .success)
            }
        }
    }
    func resume() { lock.withLock { released = true }; release.signal() }
    func rearmFailure() { lock.withLock { armed = true } }
}

private final class LifecycleClock: BrowserIntakeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var elapsed: Duration = .zero
    private var bootID = "fixture-boot"
    private var zone: TimeZone
    private var sleepRegistrationCount = 0
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, Error>)] = [:]
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

    init(date: Date = Date(timeIntervalSince1970: 1_700_000_100), zone: TimeZone = .current) {
        self.date = date
        self.zone = zone
    }

    func wallNow() -> Date { lock.withLock { date } }
    func timeZone() -> TimeZone { lock.withLock { zone } }
    func now() -> Duration { lock.withLock { elapsed } }
    func ageStamp() -> BrowserAgeStamp? {
        lock.withLock {
            let parts = elapsed.components
            return BrowserAgeStamp(bootID: bootID, elapsedMs: UInt64(max(0, parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)))
        }
    }
    func reboot() { lock.withLock { bootID = "fixture-next-boot"; elapsed = .zero } }
    func sleep(for duration: Duration) async { await Task.yield() }

    func sleepUntil(_ target: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (immediate, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if Task.isCancelled { return (true, []) }
                    if target <= date { return (true, []) }
                    sleepers[id] = (target, continuation)
                    sleepRegistrationCount += 1
                    let ready = sleepWaiters
                    sleepWaiters.removeAll()
                    return (false, ready)
                }
                if immediate { continuation.resume() }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.sleepers.removeValue(forKey: id)?.1 }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func waitUntilSleeping() async {
        let sleeping = lock.withLock { !sleepers.isEmpty }
        if sleeping { return }
        await withCheckedContinuation { continuation in
            let alreadySleeping = lock.withLock { () -> Bool in
                guard sleepers.isEmpty else { return true }
                sleepWaiters.append(continuation)
                return false
            }
            if alreadySleeping { continuation.resume() }
        }
    }

    func sleepCount() -> Int { lock.withLock { sleepRegistrationCount } }

    func waitForSleepCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while sleepCount() < count && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sleepCount() >= count
    }

    func advance(seconds: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            date = date.addingTimeInterval(seconds)
            elapsed += .milliseconds(Int64(seconds * 1000))
            let ids = sleepers.filter { $0.value.0 <= date }.map(\.key)
            return ids.compactMap { sleepers.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.resume() }
    }

    func setWallDate(_ value: Date) { lock.withLock { date = value } }
    func setTimeZone(_ value: TimeZone) { lock.withLock { zone = value } }
}

private final class LifecycleTransport: BrowserUploadTransport, @unchecked Sendable {
    private enum Outcome: Equatable { case fail, succeed, segmentRemoved }

    private let lock = NSLock()
    private var attemptCount = 0
    private var activeUploads = 0
    private var maxConcurrentUploads = 0
    private var countedBytes = 0
    private var recordedSources: [String?] = []
    private var recordedServers: [String] = []
    var servers: [String] { lock.withLock { recordedServers } }
    var completedAttempts: Int { lock.withLock { attemptCount - activeUploads } }
    private var stagedHashes: [String] = []
    private var dayListing = IngestProtocolV3.SegmentsDay(total: 0, items: [])
    private var storedSegmentKey: String?
    private var beforeResult: (@Sendable () -> Void)?
    private var outcome: Outcome = .fail
    private var queuedOutcomes: [Outcome] = []
    private var holdFirstChunk = false
    private var suspended = false
    private var uploadContinuation: CheckedContinuation<Void, Never>?

    var attempts: Int { lock.withLock { attemptCount } }
    var maxConcurrent: Int { lock.withLock { maxConcurrentUploads } }
    var bytesSent: Int { lock.withLock { countedBytes } }
    var sources: [String?] { lock.withLock { recordedSources } }
    var hashes: [String] { lock.withLock { stagedHashes } }
    var dayReads: Int { lock.withLock { dayReadCount } }
    private var dayReadCount = 0

    func setOutcomeSuccess(_ value: Bool) {
        lock.withLock {
            outcome = value ? .succeed : .fail
            queuedOutcomes.removeAll()
        }
    }

    func setOutcomeSegmentRemoved() { lock.withLock { outcome = .segmentRemoved; queuedOutcomes.removeAll() } }

    func setFirstOutcomeSegmentRemovedThenFail() {
        lock.withLock {
            outcome = .fail
            queuedOutcomes = [.segmentRemoved, .fail]
        }
    }

    func setStoredSegmentKey(_ key: String?) { lock.withLock { storedSegmentKey = key } }

    func setDayListing(_ listing: IngestProtocolV3.SegmentsDay) { lock.withLock { dayListing = listing } }

    func setBeforeResult(_ action: (@Sendable () -> Void)?) { lock.withLock { beforeResult = action } }

    func suspendAfterFirstChunk() { lock.withLock { holdFirstChunk = true } }

    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay {
        lock.withLock {
            dayReadCount += 1
            return dayListing
        }
    }

    func prepareUpload(
        serverURL: String,
        day: String,
        segment: String,
        mediaFiles: [URL],
        metadata: [String: IngestJSONValue]?,
        source: String?,
        boundary: String,
        bodyURL: URL,
        ioInjector: BrowserIntakeIOInjector
    ) throws -> PreparedIngestV3Upload {
        lock.withLock { recordedSources.append(source); recordedServers.append(serverURL) }
        return try IngestV3UploadRequestBuilder.build(
            baseURL: serverURL,
            day: day,
            segment: segment,
            selectedFiles: mediaFiles,
            meta: metadata,
            source: source,
            boundary: boundary,
            bodyURL: bodyURL,
            ioHooks: .browser(using: ioInjector)
        )
    }

    func uploadStaged(prepared: PreparedIngestV3Upload, lease: BrowserUploadLease) async -> UploadResult {
        lock.withLock {
            attemptCount += 1
            activeUploads += 1
            maxConcurrentUploads = max(maxConcurrentUploads, activeUploads)
            if let hash = prepared.stagedParts.first?.sha256 { stagedHashes.append(hash) }
        }
        defer { lock.withLock { activeUploads -= 1 } }
        guard lease.isValid(), let stream = try? FileHandle(forReadingFrom: prepared.bodyURL) else {
            return .failure(URLError(.cancelled))
        }
        defer { try? stream.close() }

        var firstChunk = true
        while true {
            guard lease.isValid() else { return .failure(URLError(.cancelled)) }
            let chunk = stream.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            lock.withLock { countedBytes += chunk.count }
            if firstChunk && lock.withLock({ holdFirstChunk }) {
                await pauseAtFirstChunk()
                guard lease.isValid() else { return .failure(URLError(.cancelled)) }
            }
            firstChunk = false
        }
        guard lease.isValid() else { return .failure(URLError(.cancelled)) }
        let finalOutcome = lock.withLock { queuedOutcomes.isEmpty ? outcome : queuedOutcomes.removeFirst() }
        if finalOutcome == .segmentRemoved {
            let callback = lock.withLock { beforeResult }
            callback?()
            return .failure(UploadError.serverError(IngestServerError(statusCode: 409, reasonCode: "segment_removed")))
        }
        guard finalOutcome == .succeed else { return .failure(URLError(.networkConnectionLost)) }

        guard let part = prepared.stagedParts.first else { return .failure(UploadError.invalidRequest) }
        let descriptor = IngestProtocolV3.UploadFileDescriptor(
            submitted: part.submitted,
            written: part.submitted,
            size: part.size,
            sha256: part.sha256,
            disposition: .written
        )
        let canonicalKey = lock.withLock { storedSegmentKey }
        let response = IngestProtocolV3.UploadResponse(
            status: canonicalKey == nil ? .ok : .collision,
            storedSegmentKey: canonicalKey ?? prepared.submittedSegment,
            segmentOriginal: canonicalKey == nil ? nil : prepared.submittedSegment,
            fileDescriptors: [descriptor],
            meta: prepared.metadata ?? [:]
        )
        return .success(UploadSuccessInfo(response: response))
    }

    func waitForAttempts(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while lock.withLock({ attemptCount < count }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { attemptCount >= count }
    }

    func waitUntilSuspended(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !lock.withLock({ suspended }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return lock.withLock { suspended }
    }

    func resumeStream() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holdFirstChunk = false
            let continuation = uploadContinuation
            uploadContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func pauseAtFirstChunk() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                suspended = true
                uploadContinuation = continuation
            }
        }
    }
}

private final class LifecyclePause: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    var value: Bool { lock.withLock { paused } }
    func set(_ paused: Bool) { lock.withLock { self.paused = paused } }
}

private struct LifecycleFixture {
    let root: URL
    let projection: BrowserContractProjection
    let clock: LifecycleClock
    let route: BrowserIntakeRouteState
    let injector: BrowserIntakeIOInjector
    let transport: LifecycleTransport
    let pause: LifecyclePause
    let owner: BrowserIntakeOwner
}

private extension LifecycleFixture {
    func updateRoute(_ resolved: ResolvedHomeBase) async {
        if case .url(let url) = resolved, let digest = owner.store.getActiveIdentityToken() {
            route.update(BrowserIntakeRouteCapability(serverURL: url, identityDigest: digest,
                pairingGeneration: 1, transportIncarnation: 1, credentialIsCurrent: { true }))
        } else {
            route.update(nil)
        }
    }
}

@Suite("BrowserSpoolLifecycle", .serialized)
struct BrowserSpoolLifecycleTests {
    @Test func staleAcceptErrorCannotFailAPublishedAndAcceptedSuccessor() async throws {
        let fixture = try fixture(syncPaused: { true })
        defer { fixture.owner.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let a = try #require(fixture.owner.store.getActiveGeneration())
        _ = try reply(await fixture.owner.accept(bytes: batch(a, id: "81818181818181818181818181818181",
            queuedAtMs: 1_700_000_100_000), direction: "extension_to_host"))
        let barrier = LifecycleFailurePublicationGate()
        fixture.injector.setFailure { try barrier.check($0) }
        let stale = Task { await fixture.owner.accept(bytes: batch(a, id: "82828282828282828282828282828282",
            queuedAtMs: 1_700_000_100_000), direction: "extension_to_host") }
        defer { barrier.resume() }
        try #require(await barrier.waitUntilHeld())
        #expect(!fixture.owner.store.storeIsFailed())
        try fixture.owner.credentialWillChange(identityToken: "accept-error-b", browserWarningWasPresented: true)
        try fixture.owner.credentialDidChange(identityToken: "accept-error-b")
        let b = try #require(fixture.owner.store.getActiveGeneration())
        let acceptedB = try fixture.owner.authority.accept(bytes: batch(b, id: "83838383838383838383838383838383",
            queuedAtMs: 1_700_000_100_000), direction: "extension_to_host")
        try #require(acceptedB["result"] as? String == "accepted")
        let periodB = try #require(acceptedB["period_id"] as? String)
        let bytesB = try Data(contentsOf: fixture.owner.store.periodFileURL(for: periodB))
        barrier.resume()
        let oldReply = await stale.value
        guard case .refusal(let refusal) = oldReply else { Issue.record("Expected a local I/O refusal"); return }
        #expect(refusal.code == "local_io")
        #expect(!fixture.owner.store.storeIsFailed())
        #expect(fixture.owner.authority.status()["failure"] == nil)
        #expect(fixture.owner.store.getActiveGeneration() == b)
        #expect(try Data(contentsOf: fixture.owner.store.periodFileURL(for: periodB)) == bytesB)
        barrier.rearmFailure()
        _ = await fixture.owner.accept(bytes: batch(b, id: "84848484848484848484848484848484",
            queuedAtMs: 1_700_000_100_000), direction: "extension_to_host")
        #expect(fixture.owner.store.storeIsFailed())
        #expect(fixture.owner.authority.status()["capture"] as? String == "unavailable")
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    @Test @MainActor func retiredDiscardBindingWaitsForFreshFactsAfterADelayedResult() async throws {
        let state = AppState.forSnapshot(config: AppConfig(syncPaused: true))
        let paired = pairing(instanceID: "retired-binding-journal")
        let credentials = PairingCredentialStore(store: PairingStore(pairing: paired))
        _ = try credentials.load()
        let fixture = try fixture(token: PairingCredentialStore.identityToken(for: paired), syncPaused: { true })
        defer { fixture.owner.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        state.configureBrowserIntake(owner: fixture.owner, credentialStore: credentials)
        state.browserRetiredCustody.openSettings()
        await fixture.owner.start()
        func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }
        let a = try #require(fixture.owner.store.getActiveGeneration())
        let acceptedA = try reply(await fixture.owner.accept(bytes: batch(a, id: "85858585858585858585858585858585",
            queuedAtMs: 1_700_000_100_000), direction: "extension_to_host"))
        let periodA = try #require(acceptedA["period_id"] as? String)
        state.refreshBrowserRetiredCustody()
        try #require(await waitFor { state.pairingCoordinator.pendingBrowserMaterial() == true })
        try await Task.detached { try credentials.save(pairing(instanceID: "retired-binding-journal-b"), browserWarningWasPresented: true) }.value
        state.refreshBrowserRetiredCustody()
        try #require(await waitFor { state.browserRetiredCustody.canRequestDiscard })
        let retainedA = fixture.root.appendingPathComponent("retired/periods/\(periodA)/browser_pages.jsonl")
        state.browserRetiredCustody.requestDiscard()
        state.browserRetiredCustody.cancelDiscard()
        #expect(!state.browserRetiredCustody.isDiscarding)
        #expect(FileManager.default.fileExists(atPath: retainedA.path))
        let resultBarrier = LifecycleDiscardResultBarrier()
        state.browserRetiredDiscardResultBarrier = { await resultBarrier.suspend() }
        state.browserRetiredCustody.requestDiscard()
        state.confirmBrowserRetiredDiscard()
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await resultBarrier.isHeld) && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        try #require(await resultBarrier.isHeld)
        #expect(state.browserRetiredCustody.isDiscarding)
        let b = try #require(fixture.owner.store.getActiveGeneration())
        let acceptedB = try reply(await fixture.owner.accept(bytes: batch(b, id: "86868686868686868686868686868686",
            queuedAtMs: 1_700_000_100_000), direction: "extension_to_host"))
        let periodB = try #require(acceptedB["period_id"] as? String)
        try await Task.detached { try credentials.save(paired, browserWarningWasPresented: true) }.value
        state.refreshBrowserRetiredCustody()
        try #require(await waitFor {
            if case .present(let scope) = state.browserRetiredCustody.inventory { return scope.identities.map(\.periodId) == [periodB] }
            return false
        })
        await resultBarrier.release()
        try #require(await waitFor { !state.browserRetiredCustody.isDiscarding })
        #expect(!state.browserRetiredCustody.showsDiscarded)
        #expect(state.browserRetiredCustody.showsNotice)
        #expect(state.pairingCoordinator.pendingBrowserMaterial() == false)
        if case .present(let scope) = state.browserRetiredCustody.inventory { #expect(scope.identities.map(\.periodId) == [periodB]) }
        else { Issue.record("The delayed A result must preserve newly retired B") }
        state.browserRetiredDiscardResultBarrier = {}
        state.browserRetiredCustody.requestDiscard()
        state.confirmBrowserRetiredDiscard()
        try #require(await waitFor { !state.browserRetiredCustody.isDiscarding })
        #expect(state.browserRetiredCustody.showsDiscarded)
        #expect(!state.browserRetiredCustody.showsFailure)
        #expect(state.browserRetiredCustody.inventory == .empty)
        state.browserRetiredCustody.closeSettings()
        state.browserRetiredCustody.openSettings()
        #expect(!state.browserRetiredCustody.showsDiscarded)
    }
#endif

    private func projection() throws -> BrowserContractProjection {
        let testFile = URL(fileURLWithPath: #filePath)
        let repository = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try BrowserContractProjection(rootURL: repository.appendingPathComponent("vendor"))
    }

    private func fixture(
        date: Date = Date(timeIntervalSince1970: 1_700_000_100),
        token: String = "lifecycle-pairing",
        transport: LifecycleTransport = LifecycleTransport(),
        syncPaused: @escaping @Sendable () async -> Bool = { false }
    ) throws -> LifecycleFixture {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("browser-spool-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projection = try projection()
        let clock = LifecycleClock(date: date, zone: TimeZone(secondsFromGMT: 0)!)
        let route = BrowserIntakeRouteState()
        _ = route.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1:49321",
            identityDigest: BrowserIntakeStore.identityDigest(of: token), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let injector = BrowserIntakeIOInjector()
        let pause = LifecyclePause()
        let isPaused = syncPaused
        let owner = try BrowserIntakeOwner.start(
            spoolRoot: root,
            projection: projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: token),
            clock: clock,
            transport: transport,
            routeResolver: HomeBaseURLResolver { .url("http://127.0.0.1:49321") },
            syncPaused: { await isPaused() || pause.value },
            ioInjector: injector,
            routeState: route
        )
        return LifecycleFixture(root: root, projection: projection, clock: clock, route: route, injector: injector, transport: transport, pause: pause, owner: owner)
    }

    private func batch(_ generation: String, id: String, queuedAtMs: UInt64, text: String = "page") -> Data {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"instance-one","batch_id":"\(id)","queued_at_ms":\(queuedAtMs),"records":[{"t":"segment_start","ts":\(queuedAtMs),"ctx":"context-one","blocks":[{"id":"block-one","text":"\(escaped)"}]}]}
        """.utf8)
    }

    private func multiBlockBatch(_ generation: String, id: String, queuedAtMs: UInt64) -> Data {
        let text = String(repeating: "x", count: 2_000)
        return Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"instance-one","batch_id":"\(id)","queued_at_ms":\(queuedAtMs),"records":[{"t":"segment_start","ts":\(queuedAtMs),"ctx":"context-one","blocks":[{"id":"block-one","text":"\(text)"},{"id":"block-two","text":"\(text)"},{"id":"block-three","text":"\(text)"}]}]}
        """.utf8)
    }

    private func reply(_ result: BrowserIntakeAcceptResult) throws -> [String: Any] {
        guard case .message(let bytes) = result else {
            if case .refusal(let refusal) = result { throw LifecycleInjectedFailure.unexpectedRefusal(refusal.code) }
            throw LifecycleInjectedFailure.injected
        }
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func waitForPeriodState(_ fixture: LifecycleFixture, periodId: String, state: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if fixture.owner.store.getPeriod(periodId: periodId)?.state == state { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return fixture.owner.store.getPeriod(periodId: periodId)?.state == state
    }

    private func waitForDurableAck(_ fixture: LifecycleFixture, periodId: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if fixture.owner.store.getPeriod(periodId: periodId)?.ackDurable == true { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return fixture.owner.store.getPeriod(periodId: periodId)?.ackDurable == true
    }

    private func matchingListing(_ binding: BrowserIngestAck, key: String? = nil) -> IngestProtocolV3.SegmentsDay {
        let file = IngestProtocolV3.ReadFile(
            name: binding.filename,
            size: binding.size,
            sha256: binding.sha256,
            status: .present
        )
        let item = IngestProtocolV3.SegmentsItem(key: key ?? binding.canonicalKey ?? "", files: [file])
        return IngestProtocolV3.SegmentsDay(total: 1, items: [item])
    }

    private func decodedState(_ status: [String: Any], projection: BrowserContractProjection) throws -> BrowserDecodedState {
        let message = try BrowserPayloadDecoder.validatedHostMessage(status, projection: projection)
        let bytes = BrowserPayloadDecoder.encodeHostToExtension(message)
        guard case .accept(.state(let state)) = BrowserPayloadDecoder.decode(
            bytes: bytes,
            direction: "host_to_extension",
            projection: projection
        ) else {
            throw LifecycleInjectedFailure.injected
        }
        return state
    }

    private func waitForDeliveryState(_ fixture: LifecycleFixture, state: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if fixture.owner.authority.status()["delivery"] as? String == state { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return fixture.owner.authority.status()["delivery"] as? String == state
    }

    private func verifyFailedSecondBatch(_ point: BrowserIntakeIOPoint, index: Int) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let firstId = String(format: "%032x", index * 2 + 1)
        let secondId = String(format: "%032x", index * 2 + 2)
        let first = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: firstId, queuedAtMs: 1_700_000_100_000, text: "A"),
            direction: "extension_to_host"
        ))
        #expect(first["result"] as? String == "accepted")
        let periodId = try #require(first["period_id"] as? String)
        let fileURL = fixture.owner.store.periodFileURL(for: periodId)
        let firstBytes = try Data(contentsOf: fileURL)
        let calls = Counter()
        fixture.injector.setFailure { candidate in
            if candidate == point && calls.increment() == 1 { throw LifecycleInjectedFailure.injected }
        }
        let second = await fixture.owner.accept(
            bytes: batch(generation, id: secondId, queuedAtMs: 1_700_000_100_001, text: "B"),
            direction: "extension_to_host"
        )
        fixture.injector.setFailure(nil)
        #expect(calls.current >= 1)
        if case .message(let bytes) = second {
            let response = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(response["result"] as? String != "accepted")
        } else if case .refusal(let refusal) = second {
            #expect(refusal.code == "local_io")
        }
        #expect(try Data(contentsOf: fileURL) == firstBytes)

        fixture.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "finalized"))
        #expect(try Data(contentsOf: fileURL) == firstBytes)
        #expect(fixture.owner.store.getPeriod(periodId: periodId)?.committedLength == firstBytes.count)
        #expect(fixture.owner.store.getAllFinalizedPeriods().map(\.periodId) == [periodId])
        fixture.owner.stop()
    }

    private func verifyInvalidLegacyBinding(_ variant: Int) async throws {
        let transport = LifecycleTransport()
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: String(format: "%032x", 0x300 + variant), queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "finalized"))
        let period = try #require(fixture.owner.store.getPeriod(periodId: periodId))
        var ack = BrowserIngestAck(
            generation: period.generation,
            source: "browser",
            periodId: period.periodId,
            filename: "browser_pages.jsonl",
            sha256: try #require(period.fileSha256),
            size: UInt64(period.committedLength),
            metadata: nil,
            requestedDay: try #require(period.requestedDay),
            requestedSegment: try #require(period.requestedSegment),
            canonicalKey: period.requestedSegment ?? "",
            status: .ok
        )
        switch variant {
        case 0:
            ack = BrowserIngestAck(generation: "wrong-generation", source: ack.source, periodId: ack.periodId, filename: ack.filename, sha256: ack.sha256, size: ack.size, metadata: ack.metadata, requestedDay: ack.requestedDay, requestedSegment: ack.requestedSegment, canonicalKey: ack.canonicalKey, status: ack.status)
        case 1:
            ack = BrowserIngestAck(generation: ack.generation, source: "media", periodId: ack.periodId, filename: ack.filename, sha256: ack.sha256, size: ack.size, metadata: ack.metadata, requestedDay: ack.requestedDay, requestedSegment: ack.requestedSegment, canonicalKey: ack.canonicalKey, status: ack.status)
        case 2:
            ack = BrowserIngestAck(generation: ack.generation, source: ack.source, periodId: "missing-period", filename: ack.filename, sha256: ack.sha256, size: ack.size, metadata: ack.metadata, requestedDay: ack.requestedDay, requestedSegment: ack.requestedSegment, canonicalKey: ack.canonicalKey, status: ack.status)
        case 3:
            ack = BrowserIngestAck(generation: ack.generation, source: ack.source, periodId: ack.periodId, filename: ack.filename, sha256: ack.sha256, size: ack.size, metadata: ack.metadata, requestedDay: "2000-01-01", requestedSegment: ack.requestedSegment, canonicalKey: ack.canonicalKey, status: ack.status)
        case 4:
            ack = BrowserIngestAck(generation: ack.generation, source: ack.source, periodId: ack.periodId, filename: "other.jsonl", sha256: ack.sha256, size: ack.size, metadata: ack.metadata, requestedDay: ack.requestedDay, requestedSegment: ack.requestedSegment, canonicalKey: ack.canonicalKey, status: ack.status)
        case 5:
            ack = BrowserIngestAck(generation: ack.generation, source: ack.source, periodId: ack.periodId, filename: ack.filename, sha256: ack.sha256, size: ack.size + 1, metadata: ack.metadata, requestedDay: ack.requestedDay, requestedSegment: ack.requestedSegment, canonicalKey: ack.canonicalKey, status: ack.status)
        default:
            ack = BrowserIngestAck(generation: ack.generation, source: ack.source, periodId: ack.periodId, filename: ack.filename, sha256: String(repeating: "0", count: 64), size: ack.size, metadata: ack.metadata, requestedDay: ack.requestedDay, requestedSegment: ack.requestedSegment, canonicalKey: ack.canonicalKey, status: ack.status)
        }
        let fileURL = fixture.owner.store.periodFileURL(for: periodId)
        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: fileURL.deletingLastPathComponent())
        try BrowserIngestAckStore.write(ack, to: ackURL, ioInjector: fixture.injector)
        fixture.pause.set(false)
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.transport.attempts == 0)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        fixture.owner.stop()
    }

    @Test func ownerOwnsBoundaryWakePauseAndStop() async throws {
        let transport = LifecycleTransport()
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let sleepCount = fixture.clock.sleepCount()
        await fixture.owner.start()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.clock.sleepCount() == sleepCount)

        let generation = try #require(fixture.owner.store.getActiveGeneration())
        fixture.owner.authority.setPaused(true)
        let accepted = try await reply(fixture.owner.accept(
            bytes: batch(generation, id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        #expect(accepted["result"] as? String == "accepted")
        fixture.owner.authority.setPaused(false)

        fixture.clock.advance(seconds: 301)
        #expect(await transport.waitForAttempts(1))
        #expect(transport.sources.first == "browser")
        #expect(fixture.owner.store.getAllFinalizedPeriods().count == 1)
        #expect(fixture.owner.store.storeIsFailed() == false)

        fixture.pause.set(true)
        await fixture.owner.scheduleDelivery()
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.attempts == 1)
        await MainActor.run {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.attempts == 1)
        await fixture.updateRoute(.held)
        let generationAfterDisconnect = fixture.owner.store.getActiveGeneration()
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.attempts == 1)
        fixture.pause.set(false)
        await MainActor.run {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        #expect(await transport.waitForAttempts(2))
        #expect(generationAfterDisconnect == generation)
        #expect(transport.maxConcurrent == 1)

        fixture.owner.stop()
        let stopped = await fixture.owner.accept(
            bytes: batch(generation, id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", queuedAtMs: 1_700_000_401_000),
            direction: "extension_to_host"
        )
        guard case .refusal(let refusal) = stopped else { Issue.record("stopped owner accepted a batch"); return }
        #expect(refusal.code == "intake_off")
        await fixture.owner.start()
        #expect(fixture.owner.store.storeIsFailed() == false)
    }

    @Test @MainActor func identityEpochAndLeaseRejectLateOldGenerationProof() async throws {
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        transport.suspendAfterFirstChunk()
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()

        let oldGeneration = try #require(fixture.owner.store.getActiveGeneration())
        try fixture.owner.credentialReloaded(identityToken: "lifecycle-pairing")
        #expect(fixture.owner.store.getActiveGeneration() == oldGeneration)
        let accepted = try await reply(fixture.owner.accept(
            bytes: multiBlockBatch(oldGeneration, id: "cccccccccccccccccccccccccccccccc", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        let activePayload = fixture.owner.store.periodFileURL(for: periodId)
        let originalPayload = try Data(contentsOf: activePayload)
        fixture.clock.advance(seconds: 301)
        #expect(await transport.waitUntilSuspended())
        let sentBeforeReplacement = transport.bytesSent

        let delayedResume = Task.detached {
            try? await Task.sleep(for: .milliseconds(250))
            transport.resumeStream()
        }
        let replacementStart = ContinuousClock.now
        try fixture.owner.credentialWillChange(identityToken: "replacement-pairing", browserWarningWasPresented: true)
        #expect(ContinuousClock.now - replacementStart < .milliseconds(200))
        #expect(fixture.owner.authority.isAdmissionOpen() == false)
        transport.resumeStream()
        await delayedResume.value
        try await Task.sleep(for: .milliseconds(80))
        #expect(transport.bytesSent == sentBeforeReplacement)
        let ackURL = BrowserIngestAckStore.ackURL(
            periodDirectory: activePayload.deletingLastPathComponent()
        )
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        let retiredPayload = fixture.root.appendingPathComponent("retired/periods/\(periodId)/browser_pages.jsonl")
        let retiredAckURL = BrowserIngestAckStore.ackURL(periodDirectory: retiredPayload.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: retiredAckURL.path) == false)
        #expect(!FileManager.default.fileExists(atPath: activePayload.path))
        #expect(try Data(contentsOf: retiredPayload) == originalPayload)

        try fixture.owner.credentialDidChange(identityToken: "replacement-pairing")
        #expect(fixture.owner.store.getActiveGeneration() != oldGeneration)
        fixture.owner.stop()
    }

    @Test func timezoneNotificationFinalizesWithChangedCivilDay() async throws {
        let transport = LifecycleTransport()
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        #expect(await fixture.clock.waitForSleepCount(1))
        fixture.clock.setTimeZone(TimeZone(secondsFromGMT: 14 * 60 * 60)!)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(await fixture.clock.waitForSleepCount(2))

        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try await reply(fixture.owner.accept(
            bytes: batch(generation, id: "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        #expect(accepted["result"] as? String == "accepted")
        fixture.clock.advance(seconds: 301)
        #expect(await transport.waitForAttempts(1))
        #expect(fixture.owner.store.getAllFinalizedPeriods().first?.requestedDay == "20231115")
        fixture.owner.stop()
    }

    @Test func civilMidnightBoundaryKeysThePeriodByTheDayItStarted() async throws {
        let transport = LifecycleTransport()
        let fixture = try fixture(date: Date(timeIntervalSince1970: 1_700_006_200), transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        #expect(await fixture.clock.waitForSleepCount(1))
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "abababababababababababababababab", queuedAtMs: 1_700_006_200_000),
            direction: "extension_to_host"
        ))
        #expect(accepted["result"] as? String == "accepted")
        fixture.clock.advance(seconds: 201)
        #expect(await transport.waitForAttempts(1))
        // Opened at 23:56:40 and rotated at midnight: the key is the period's
        // own start on the old day, and it ends at the window's close.
        let sealed = fixture.owner.store.getAllFinalizedPeriods().first
        #expect(sealed?.requestedDay == "20231114")
        let parts = try #require(sealed?.requestedSegment).split(separator: "_")
        #expect(parts.first == "235640")
        #expect((parts.last.flatMap { Int($0) } ?? .max) <= 200)
        #expect(fixture.owner.store.storeIsFailed() == false)
        fixture.owner.stop()
    }

    @Test func staleResolvedRouteSendsNoBytes() async throws {
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        #expect(await fixture.clock.waitForSleepCount(1))
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "abababababababababababababababac", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        await fixture.updateRoute(.url("http://127.0.0.1:49999"))
        fixture.clock.advance(seconds: 301)
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.attempts == 0)
        #expect(transport.bytesSent == 0)
        #expect(transport.sources.isEmpty)

        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await transport.waitForAttempts(1))
        #expect(fixture.owner.store.getActiveGeneration() == generation)
        #expect(accepted["result"] as? String == "accepted")
        fixture.owner.stop()
    }

    @Test @MainActor func stoppedOwnerRejectsLateUploadCompletion() async throws {
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        transport.suspendAfterFirstChunk()
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try await reply(fixture.owner.accept(
            bytes: batch(generation, id: "dededededededededededededededede", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.clock.advance(seconds: 301)
        #expect(await transport.waitUntilSuspended())
        let bytesBeforeStop = transport.bytesSent
        #expect(fixture.owner.store.getOpenPeriodId() != nil)
        let stopStartedAt = ContinuousClock.now
        fixture.owner.stop()
        #expect(ContinuousClock.now - stopStartedAt < .seconds(1))
        #expect(fixture.owner.store.getOpenPeriodId() == nil)
        transport.resumeStream()
        try await Task.sleep(for: .milliseconds(80))
        #expect(transport.bytesSent == bytesBeforeStop)
        let ackURL = BrowserIngestAckStore.ackURL(
            periodDirectory: fixture.owner.store.periodFileURL(for: periodId).deletingLastPathComponent()
        )
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.owner.store.periodFileURL(for: periodId).path))
    }

    @Test @MainActor func synchronousStopFinalizesTheOpenPeriodBeforeReturning() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "26262626262626262626262626262626", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        let payload = fixture.owner.store.periodFileURL(for: periodId)
        #expect(fixture.owner.store.getOpenPeriodId() == periodId)

        fixture.owner.stop()
        let stored = try #require(fixture.owner.store.getPeriod(periodId: periodId))
        #expect(stored.state == "finalized")
        #expect(fixture.owner.store.getOpenPeriodId() == nil)
        #expect(stored.requestedDay != nil)
        #expect(stored.requestedSegment != nil)
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test @MainActor func failedUpdateDrainsLateReaderBeforeResumingTheSameOwner() async throws {
        let paired = pairing(instanceID: "browser-update-test")
        let credentials = PairingCredentialStore(store: PairingStore(pairing: paired))
        _ = try credentials.load()
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        transport.suspendAfterFirstChunk()
        let fixture = try fixture(token: PairingCredentialStore.identityToken(for: paired), transport: transport)
        defer { fixture.owner.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        let state = AppState.forSnapshot()
        state.configureBrowserIntake(owner: fixture.owner, credentialStore: credentials)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(bytes: batch(generation,
            id: "41414141414141414141414141414141", queuedAtMs: 1_700_000_100_000), direction: "extension_to_host"))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.clock.advance(seconds: 301)
        #expect(await transport.waitUntilSuspended())
        fixture.owner.stop()
        let stoppedBytes = transport.bytesSent
        let resumedZone = TimeZone(secondsFromGMT: -6 * 3600)!
        fixture.clock.setTimeZone(resumedZone)
        let recovery = Task { await state.recoverAfterFailedUpdaterInstall() }
        await Task.yield()
        #expect(!fixture.owner.authority.isAdmissionOpen())
        #expect(fixture.owner.store.getPeriod(periodId: periodId)?.state == "finalized")
        transport.resumeStream()
        await recovery.value
        #expect(state.browserIntakeStore === fixture.owner.store)
        #expect(fixture.owner.store.getActiveGeneration() == generation)
        #expect(fixture.owner.authority.isAdmissionOpen())
        #expect(await waitForDurableAck(fixture, periodId: periodId))
        #expect(transport.maxConcurrent == 1)
        #expect(transport.bytesSent > stoppedBytes)
        let next = try reply(await fixture.owner.accept(bytes: batch(generation,
            id: "44444444444444444444444444444444", queuedAtMs: 1_700_000_401_000), direction: "extension_to_host"))
        let nextPeriod = try #require(next["period_id"] as? String)
        fixture.owner.stop()
        #expect(fixture.owner.store.getPeriod(periodId: nextPeriod)?.finalizeTimeZone == resumedZone.identifier)
    }

    @Test @MainActor func settingsSyncResumeDeliversHeldBrowserDataWithoutANewBatch() async throws {
        let state = AppState.forSnapshot(config: AppConfig(syncPaused: true))
        state.configSaver = { _ in }
        let paired = pairing(instanceID: "browser-settings-test")
        let credentials = PairingCredentialStore(store: PairingStore(pairing: paired))
        _ = try credentials.load()
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        let fixture = try fixture(token: PairingCredentialStore.identityToken(for: paired), transport: transport,
            syncPaused: { await MainActor.run { state.config.syncPaused } })
        defer { fixture.owner.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        state.configureBrowserIntake(owner: fixture.owner, credentialStore: credentials)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(bytes: batch(generation,
            id: "42424242424242424242424242424242", queuedAtMs: 1_700_000_100_000), direction: "extension_to_host"))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "finalized"))
        #expect(transport.attempts == 0)
        var config = state.config
        config.syncPaused = false
        state.updateConfig(config)
        #expect(await waitForDurableAck(fixture, periodId: periodId))
        #expect(transport.attempts == 1)
    }

    @Test func stopUsesTrackedZoneEvenBeforeItsNotificationArrives() async throws {
        let fixture = try fixture(date: Date(timeIntervalSince1970: 1_700_006_500))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(bytes: batch(generation,
            id: "43434343434343434343434343434343", queuedAtMs: 1_700_006_500_000), direction: "extension_to_host"))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.clock.setTimeZone(TimeZone(secondsFromGMT: -12 * 3600)!)
        fixture.clock.setWallDate(Date(timeIntervalSince1970: -1))
        fixture.owner.stop()
        let period = try #require(fixture.owner.store.getPeriod(periodId: periodId))
        #expect(period.state == "finalized")
        #expect(period.finalizeTimeZone == "GMT")
        // Keyed by the period's start in the tracked zone; the rolled-back
        // wall clock at stop does not relabel it.
        #expect(period.requestedDay == "20231115")
    }

    @Test func failedCommittedLengthReadNeverTruncatesToZero() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let original = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "dddddddddddddddddddddddddddddddd", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        #expect(original["result"] as? String == "accepted")
        let periodId = try #require(original["period_id"] as? String)
        let fileURL = fixture.owner.store.periodFileURL(for: periodId)
        let originalBytes = try Data(contentsOf: fileURL)

        let reads = Counter()
        fixture.injector.setFailure { point in
            guard point == .read else { return }
            let count = reads.increment()
            if count == 4 { throw LifecycleInjectedFailure.injected }
        }
        let result = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", queuedAtMs: 1_700_000_100_000, text: "second"),
            direction: "extension_to_host"
        ))
        fixture.injector.setFailure(nil)
        #expect(result["result"] as? String == "rejected")
        #expect(try Data(contentsOf: fileURL) == originalBytes)
        fixture.owner.stop()
    }

    @Test func injectedMutationFailuresKeepOnlyThePreviouslyAcceptedPrefix() async throws {
        for (index, point) in [BrowserIntakeIOPoint.bind, .step, .begin, .write, .sync, .commit].enumerated() {
            try await verifyFailedSecondBatch(point, index: index + 1)
        }
    }

    @Test func callerIdleRestartMustAnswerValidHello() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        #expect(await fixture.clock.waitForSleepCount(1))
        let hello = Data(#"{"type":"hello","protocol":1,"version":"1.0.0","brand":"chrome","inst":"desktop_inst_1"}"#.utf8)
        let initialHello = try reply(await fixture.owner.accept(bytes: hello, direction: "extension_to_host"))
        #expect(initialHello["type"] as? String == "hello_ack")
        let emptyPeriod = try #require(fixture.owner.store.getOpenPeriodId())
        let emptyFile = fixture.owner.store.periodFileURL(for: emptyPeriod)
        #expect(try Data(contentsOf: emptyFile).isEmpty)

        fixture.clock.advance(seconds: 301)
        #expect(await fixture.clock.waitForSleepCount(2))
        #expect(fixture.owner.store.getPeriod(periodId: emptyPeriod)?.state == "retired")
        #expect(FileManager.default.fileExists(atPath: emptyFile.path) == false)
        #expect(fixture.owner.store.getAllFinalizedPeriods().isEmpty)
        #expect(fixture.owner.store.storeIsFailed() == false)
        fixture.owner.stop()

        let restarted = try BrowserIntakeOwner.start(
            spoolRoot: fixture.root,
            projection: fixture.projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "lifecycle-pairing"),
            clock: fixture.clock,
            transport: fixture.transport,
            routeResolver: HomeBaseURLResolver { .held },
            ioInjector: fixture.injector
        )
        await restarted.start()
        #expect(restarted.store.storeIsFailed() == false)
        #expect(restarted.store.getAllFinalizedPeriods().allSatisfy {
            FileManager.default.fileExists(atPath: restarted.store.periodFileURL(for: $0.periodId).path)
        })
        let result = await restarted.accept(bytes: hello, direction: "extension_to_host")
        var returnedHello = false
        switch result {
        case .message(let bytes):
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            returnedHello = object?["type"] as? String == "hello_ack"
            print("CALLER_IDLE_PROBE hello=message validHello=\(returnedHello)")
        case .refusal(let refusal):
            print("CALLER_IDLE_PROBE hello=refusal code=\(refusal.code)")
        }
        #expect(returnedHello)
        restarted.stop()
    }

    @Test(arguments: [false, true]) func finalizingIntentRecoversWithItsStoredCivilContext(afterSync: Bool) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "21212121212121212121212121212121", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        if afterSync {
            fixture.owner.store.crashPoint = .afterFinalizeSync
        } else {
            fixture.injector.setFailure { point in
                if point == .finalizePublication { throw LifecycleInjectedFailure.injected }
            }
        }
        fixture.clock.advance(seconds: 301)
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.owner.store.getPeriod(periodId: periodId)?.state != "finalizing", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let intent = try #require(fixture.owner.store.getPeriod(periodId: periodId))
        #expect(intent.state == "finalizing")
        let storedDay = try #require(intent.requestedDay)
        let storedSegment = try #require(intent.requestedSegment)
        let storedZone = try #require(intent.finalizeTimeZone)
        #expect(storedZone == "GMT")
        fixture.owner.stop()
        fixture.owner.store.crashPoint = .none
        fixture.injector.setFailure(nil)
        fixture.clock.setTimeZone(TimeZone(secondsFromGMT: -7 * 60 * 60)!)
        fixture.clock.setWallDate(fixture.clock.wallNow().addingTimeInterval(86_400))

        let recovered = try BrowserIntakeOwner.start(
            spoolRoot: fixture.root,
            projection: fixture.projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "lifecycle-pairing"),
            clock: fixture.clock,
            transport: fixture.transport,
            routeResolver: HomeBaseURLResolver { .held },
            ioInjector: fixture.injector
        )
        await recovered.start()
        let published = try #require(recovered.store.getPeriod(periodId: periodId))
        #expect(published.state == "finalized")
        #expect(published.requestedDay == storedDay)
        #expect(published.requestedSegment == storedSegment)
        #expect(published.finalizeTimeZone == storedZone)
        #expect(recovered.store.storeIsFailed() == false)
        recovered.stop()
    }

    @Test func ackReconciliationRequiresCanonicalKeyAndEveryBindingField() async throws {
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        transport.setStoredSegmentKey("canonical-browser-segment")
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "22222222222222222222222222222222", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "finalized"))
        fixture.pause.set(false)
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await transport.waitForAttempts(1))
        let durableDeadline = ContinuousClock.now + .seconds(2)
        while fixture.owner.store.getPeriod(periodId: periodId)?.ackDurable != true && ContinuousClock.now < durableDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let storedBinding = try fixture.owner.store.storedDeliveryBinding(periodId: periodId)
        let binding = try #require(storedBinding)
        #expect(binding.generation == generation)
        #expect(binding.source == "browser")
        #expect(binding.periodId == periodId)
        #expect(binding.filename == "browser_pages.jsonl")
        let storedPeriod = try #require(fixture.owner.store.getPeriod(periodId: periodId))
        #expect(binding.requestedDay == storedPeriod.requestedDay)
        #expect(binding.requestedSegment == storedPeriod.requestedSegment)
        #expect(binding.size == UInt64(storedPeriod.committedLength))
        #expect(binding.sha256 == storedPeriod.fileSha256)
        #expect(binding.canonicalKey == "canonical-browser-segment")
        #expect(binding.metadata == nil)
        let ackURL = BrowserIngestAckStore.ackURL(
            periodDirectory: fixture.owner.store.periodFileURL(for: periodId).deletingLastPathComponent()
        )
        #expect(try BrowserIngestAckStore.read(from: ackURL, ioInjector: fixture.injector) == binding)
        #expect(storedPeriod.ackDurable)

        transport.setDayListing(matchingListing(binding, key: "different-canonical-key"))
        let readsBeforeMismatch = transport.dayReads
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        let mismatchDeadline = ContinuousClock.now + .seconds(2)
        while transport.dayReads == readsBeforeMismatch && ContinuousClock.now < mismatchDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.owner.store.periodFileURL(for: periodId).path))
        #expect(fixture.owner.store.getPeriod(periodId: periodId)?.state == "finalized")

        transport.setDayListing(matchingListing(binding))
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "delivered"))
        #expect(transport.attempts == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.owner.store.periodFileURL(for: periodId).path) == false)
        fixture.owner.stop()

        for variant in 0..<7 { try await verifyInvalidLegacyBinding(variant) }
    }

    @Test func ackParentSyncFailureRetriesDurabilityWithoutReupload() async throws {
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "23232323232323232323232323232323", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "finalized"))

        let syncCalls = Counter()
        let parentSyncFailures = Counter()
        let proofCalls = Counter()
        let injector = fixture.injector
        fixture.injector.setFailure { point in
            guard point == .proof, proofCalls.increment() == 1 else { return }
            injector.setFailure { point in
                guard point == .sync else { return }
                if syncCalls.increment() == 2 {
                    parentSyncFailures.increment()
                    throw LifecycleInjectedFailure.injected
                }
            }
        }
        fixture.pause.set(false)
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await transport.waitForAttempts(1))
        let fileURL = fixture.owner.store.periodFileURL(for: periodId)
        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: fileURL.deletingLastPathComponent())
        let ackDeadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: ackURL.path), ContinuousClock.now < ackDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: ackURL.path))
        #expect(fixture.owner.store.getPeriod(periodId: periodId)?.ackDurable == false)
        #expect(proofCalls.current == 1)
        #expect(parentSyncFailures.current == 1)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let storedBinding = try fixture.owner.store.storedDeliveryBinding(periodId: periodId)
        let binding = try #require(storedBinding)
        fixture.injector.setFailure(nil)
        transport.setDayListing(matchingListing(binding))

        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "delivered"))
        #expect(fixture.owner.store.getPeriod(periodId: periodId)?.ackDurable == true)
        #expect(transport.attempts == 1)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        fixture.owner.stop()
    }

    @Test func proofFenceRejectsAckAfterCredentialReplacementAndStop() async throws {
        let replacementTransport = LifecycleTransport()
        replacementTransport.setOutcomeSuccess(true)
        let replacement = try fixture(transport: replacementTransport)
        defer { try? FileManager.default.removeItem(at: replacement.root) }
        replacement.pause.set(true)
        await replacement.owner.start()
        await replacement.clock.waitUntilSleeping()
        let oldGeneration = try #require(replacement.owner.store.getActiveGeneration())
        let accepted = try reply(await replacement.owner.accept(
            bytes: batch(oldGeneration, id: "45454545454545454545454545454545", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        let payload = replacement.owner.store.periodFileURL(for: periodId)
        let originalPayload = try Data(contentsOf: payload)
        replacement.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(replacement, periodId: periodId, state: "finalized"))

        let replacementProofCalls = Counter()
        let replacementCompleted = Counter()
        let replacementInjector = replacement.injector
        let replacementOwner = replacement.owner
        replacement.injector.setFailure { point in
            guard point == .proof, replacementProofCalls.increment() == 1 else { return }
            // Retirement validates its payload through the same proof hook.
            replacementInjector.setFailure(nil)
            try replacementOwner.credentialWillChange(identityToken: "replacement-pairing", browserWarningWasPresented: true)
            try replacementOwner.credentialDidChange(identityToken: "replacement-pairing")
            _ = replacementCompleted.increment()
        }
        replacement.pause.set(false)
        await replacement.updateRoute(.held)
        await replacement.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await replacementTransport.waitForAttempts(1))

        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: payload.deletingLastPathComponent())
        let replacementDeadline = ContinuousClock.now + .seconds(2)
        // Entering the proof callback is not completion of credential replacement.
        while replacementCompleted.current == 0 && ContinuousClock.now < replacementDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(replacementCompleted.current == 1)
        #expect(replacementProofCalls.current == 1)
        #expect(replacement.owner.store.getActiveGeneration() != oldGeneration)
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        let retiredPayload = replacement.root.appendingPathComponent("retired/periods/\(periodId)/browser_pages.jsonl")
        let retiredAckURL = BrowserIngestAckStore.ackURL(periodDirectory: retiredPayload.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: retiredAckURL.path) == false)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(try Data(contentsOf: retiredPayload) == originalPayload)
        #expect(replacement.owner.store.storeIsFailed() == false)

        replacementInjector.setFailure(nil)
        await replacement.updateRoute(.held)
        await replacement.updateRoute(.url("http://127.0.0.1:49321"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(replacementTransport.attempts == 1)
        #expect(replacementTransport.hashes.count == 1)
        #expect(FileManager.default.fileExists(atPath: ackURL.path) == false)
        #expect(try Data(contentsOf: retiredPayload) == originalPayload)
        replacement.owner.stop()

        let stopTransport = LifecycleTransport()
        stopTransport.setOutcomeSuccess(true)
        let stopped = try fixture(transport: stopTransport)
        defer { try? FileManager.default.removeItem(at: stopped.root) }
        stopped.pause.set(true)
        await stopped.owner.start()
        await stopped.clock.waitUntilSleeping()
        let generation = try #require(stopped.owner.store.getActiveGeneration())
        let stoppedAccepted = try reply(await stopped.owner.accept(
            bytes: batch(generation, id: "46464646464646464646464646464646", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let stoppedPeriodId = try #require(stoppedAccepted["period_id"] as? String)
        let stoppedPayload = stopped.owner.store.periodFileURL(for: stoppedPeriodId)
        stopped.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(stopped, periodId: stoppedPeriodId, state: "finalized"))

        let stopProofCalls = Counter()
        let stopCompleted = Counter()
        let stopInjector = stopped.injector
        let stoppedOwner = stopped.owner
        stopped.injector.setFailure { point in
            guard point == .proof, stopProofCalls.increment() == 1 else { return }
            stoppedOwner.stop()
            try stoppedOwner.credentialReloaded(identityToken: "lifecycle-pairing")
            _ = stopCompleted.increment()
        }
        stopped.pause.set(false)
        await stopped.updateRoute(.held)
        await stopped.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await stopTransport.waitForAttempts(1))

        let stoppedAckURL = BrowserIngestAckStore.ackURL(periodDirectory: stoppedPayload.deletingLastPathComponent())
        let stopDeadline = ContinuousClock.now + .seconds(2)
        while stopCompleted.current == 0 && ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(stopCompleted.current == 1)
        #expect(stopProofCalls.current == 1)
        #expect(FileManager.default.fileExists(atPath: stoppedAckURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: stoppedPayload.path))
        #expect(stopped.owner.store.storeIsFailed() == false)

        stopInjector.setFailure(nil)
        await stopped.owner.scheduleDelivery()
        try await Task.sleep(for: .milliseconds(100))
        #expect(stopTransport.attempts == 1)
        #expect(FileManager.default.fileExists(atPath: stoppedAckURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: stoppedPayload.path))
    }

    @Test func segmentRemovedProofCleansOnlyItsPeriodAndRecoveryFinishesUnlink() async throws {
        let removedTransport = LifecycleTransport()
        removedTransport.setFirstOutcomeSegmentRemovedThenFail()
        let fixture = try fixture(transport: removedTransport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "24242424242424242424242424242424", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        let payload = fixture.owner.store.periodFileURL(for: periodId)
        fixture.clock.advance(seconds: 1)
        fixture.injector.setSizeOverride { url, actual in
            url == payload ? fixture.projection.policy.file : actual
        }
        let second = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "27272727272727272727272727272727", queuedAtMs: 1_700_000_101_000),
            direction: "extension_to_host"
        ))
        fixture.injector.setSizeOverride(nil)
        let secondPeriodId = try #require(second["period_id"] as? String)
        let secondPayload = fixture.owner.store.periodFileURL(for: secondPeriodId)
        #expect(secondPeriodId != periodId)
        let firstHash = try #require(fixture.owner.store.getPeriod(periodId: periodId)?.fileSha256)
        fixture.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(fixture, periodId: secondPeriodId, state: "finalized"))
        fixture.pause.set(false)
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await removedTransport.waitForAttempts(2))
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "removed"))
        #expect(FileManager.default.fileExists(atPath: payload.path) == false)
        #expect(fixture.owner.store.getPeriod(periodId: secondPeriodId)?.state == "finalized")
        #expect(FileManager.default.fileExists(atPath: secondPayload.path))
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await removedTransport.waitForAttempts(3))
        try await Task.sleep(for: .milliseconds(80))
        #expect(removedTransport.attempts >= 3)
        #expect(fixture.owner.store.getPeriod(periodId: periodId)?.state == "removed")
        #expect(removedTransport.hashes.filter { $0 == firstHash }.count == 1)
        #expect(FileManager.default.fileExists(atPath: secondPayload.path))
        fixture.owner.stop()

        let recoveryTransport = LifecycleTransport()
        recoveryTransport.setOutcomeSegmentRemoved()
        let interrupted = try self.fixture(transport: recoveryTransport)
        defer { try? FileManager.default.removeItem(at: interrupted.root) }
        interrupted.pause.set(true)
        await interrupted.owner.start()
        await interrupted.clock.waitUntilSleeping()
        let interruptedGeneration = try #require(interrupted.owner.store.getActiveGeneration())
        let interruptedReply = try reply(await interrupted.owner.accept(
            bytes: batch(interruptedGeneration, id: "25252525252525252525252525252525", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let interruptedPeriod = try #require(interruptedReply["period_id"] as? String)
        let interruptedPayload = interrupted.owner.store.periodFileURL(for: interruptedPeriod)
        interrupted.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(interrupted, periodId: interruptedPeriod, state: "finalized"))
        let writes = Counter()
        let unlinkInjector = interrupted.injector
        recoveryTransport.setBeforeResult {
            unlinkInjector.setFailure { point in
                if point == .write && writes.increment() == 1 { throw LifecycleInjectedFailure.injected }
            }
        }
        interrupted.pause.set(false)
        await interrupted.updateRoute(.held)
        await interrupted.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await recoveryTransport.waitForAttempts(1))
        #expect(interrupted.owner.store.getPeriod(periodId: interruptedPeriod)?.state == "removed")
        #expect(interrupted.owner.store.getPeriod(periodId: interruptedPeriod)?.cleanupDurable == false)
        #expect(FileManager.default.fileExists(atPath: interruptedPayload.path))
        interrupted.owner.stop()
        interrupted.injector.setFailure(nil)

        let recovered = try BrowserIntakeOwner.start(
            spoolRoot: interrupted.root,
            projection: interrupted.projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "lifecycle-pairing"),
            clock: interrupted.clock,
            transport: recoveryTransport,
            routeResolver: HomeBaseURLResolver { .held },
            ioInjector: interrupted.injector
        )
        await recovered.start()
        #expect(recovered.store.getPeriod(periodId: interruptedPeriod)?.cleanupDurable == true)
        #expect(FileManager.default.fileExists(atPath: interruptedPayload.path) == false)
        #expect(recoveryTransport.attempts == 1)
        #expect(recovered.store.storeIsFailed() == false)
        recovered.stop()
    }

    // Caller-only synthetic regression. No socket, owner service, or real credentials.
    @Test(arguments: ["lifecycle-pairing", "foreign-pairing"])
    func callerRecoveredCustodyMustMatchLoadedPairing(token: String) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let oldGeneration = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(oldGeneration, id: "fafafafafafafafafafafafafafafafa", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.owner.stop()
        #expect(fixture.owner.store.getPeriod(periodId: periodId)?.state == "finalized")
        let destination = "http://127.0.0.1:49322"
        let route = BrowserIntakeRouteState()
        _ = route.update(BrowserIntakeRouteCapability(serverURL: destination,
            identityDigest: BrowserIntakeStore.identityDigest(of: token), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let transport = LifecycleTransport()
        let replacement = try BrowserIntakeOwner.start(
            spoolRoot: fixture.root,
            projection: fixture.projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: token),
            clock: fixture.clock,
            transport: transport,
            routeResolver: HomeBaseURLResolver { .url(destination) },
            ioInjector: fixture.injector,
            routeState: route
        )
        defer { replacement.stop() }
        let admissionBeforeStart = replacement.authority.isAdmissionOpen()
        await replacement.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while transport.completedAttempts == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let attempts = transport.attempts
        let bytes = transport.bytesSent
        let servers = transport.servers
        print("CALLER_STARTUP_PROBE token=\(token) admission=\(admissionBeforeStart) attempts=\(attempts) bodyBytesRead=\(bytes) servers=\(servers)")
        if token == "lifecycle-pairing" {
            #expect(attempts > 0)
            #expect(bytes > 0)
            #expect(servers == [destination])
        } else {
            #expect(admissionBeforeStart == false)
            #expect(attempts == 0)
            #expect(bytes == 0)
            #expect(servers.isEmpty)
        }
    }

    @Test func realCredentialSaveAndAccessRefreshKeepTheSameJournalGeneration() async throws {
        let paired = pairing(instanceID: "browser-credential-test")
        let storage = PairingStore(pairing: paired)
        let credentials = PairingCredentialStore(store: storage)
        _ = try credentials.load()
        let fixture = try fixture(token: PairingCredentialStore.identityToken(for: paired))
        defer { fixture.owner.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.owner.bindCredentials(credentials)
        await fixture.owner.start()
        let original = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(bytes: batch(original,
            id: "31313131313131313131313131313131", queuedAtMs: 1_700_000_100_000), direction: "extension_to_host"))
        let held = try #require(accepted["period_id"] as? String)
        let oldPayload = fixture.owner.store.periodFileURL(for: held)
        let originalPayload = try Data(contentsOf: oldPayload)
        let revisions = credentials.currentGenerations()
        _ = try credentials.updateRelayAccess(expectedPairingGen: revisions.pairingGeneration,
            expectedAccessGen: revisions.accessMutationGeneration, relayOrigin: "https://relay.example",
            deviceToken: "refreshed-token", expiresAtString: nil)
        #expect(fixture.owner.store.getActiveGeneration() == original)
        try credentials.save(paired, browserWarningWasPresented: true)
        let replacement = try #require(fixture.owner.store.getActiveGeneration())
        #expect(replacement == original)
        #expect(fixture.owner.store.getPeriod(periodId: held)?.generation == original)
        #expect(try Data(contentsOf: oldPayload) == originalPayload)
        #expect(fixture.owner.retiredCustodyInventory() == .empty)
    }

    @Test func reloadMismatchKeepsCustodyAndClosesAdmission() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let oldGeneration = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(oldGeneration, id: "ffffffffffffffffffffffffffffffff", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.owner.stop()

        let replacement = try BrowserIntakeOwner.start(
            spoolRoot: fixture.root,
            projection: fixture.projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "foreign-pairing"),
            clock: fixture.clock,
            transport: fixture.transport,
            routeResolver: HomeBaseURLResolver { .held },
            ioInjector: fixture.injector
        )
        #expect(replacement.authority.isAdmissionOpen() == false)
        #expect(replacement.store.getActiveGeneration() == oldGeneration)
        #expect(replacement.store.getPeriod(periodId: periodId)?.state == "finalized")
        #expect(FileManager.default.fileExists(atPath: replacement.store.periodFileURL(for: periodId).path))
        let state = replacement.authority.status()
        #expect(state["capture"] as? String == "unavailable")
        #expect(state["destination_generation"] is NSNull)
    }

    @Test func callerQuotaRefusalMustNotPoisonDelivery() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "13131313131313131313131313131313", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        let fileURL = fixture.owner.store.periodFileURL(for: periodId)
        let before = try Data(contentsOf: fileURL)
        let database = fixture.root.appendingPathComponent("intake.sqlite")
        fixture.injector.setSizeOverride { url, actual in
            url == database ? fixture.projection.policy.spoolBytes : actual
        }
        let reply = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "12121212121212121212121212121212", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        #expect(reply["result"] as? String == "rejected")
        #expect(reply["reason"] as? String == "resource_exhausted")
        #expect(try Data(contentsOf: fileURL) == before)
        let duplicate = try self.reply(await fixture.owner.accept(
            bytes: batch(generation, id: "13131313131313131313131313131313", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        #expect(duplicate["result"] as? String == "duplicate")
        #expect(try Data(contentsOf: fileURL) == before)
        let failedUnderPressure = fixture.owner.store.storeIsFailed()
        fixture.injector.setSizeOverride(nil)
        let failedAfterPressure = fixture.owner.store.storeIsFailed()
        let permitAfterPressure = fixture.owner.gate.currentPermit() != nil
        print("CALLER_QUOTA_PROBE failedUnderPressure=\(failedUnderPressure) failedAfterPressure=\(failedAfterPressure) permitAfterPressure=\(permitAfterPressure)")
        #expect(failedUnderPressure == false)
        #expect(failedAfterPressure == false)
        #expect(permitAfterPressure)
        fixture.owner.stop()
    }

    @Test func injectedSizePressureRotatesWithoutALargeFile() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let first = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "14141414141414141414141414141414", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let firstPeriod = try #require(first["period_id"] as? String)
        let firstFile = fixture.owner.store.periodFileURL(for: firstPeriod)
        fixture.injector.setSizeOverride { url, actual in
            url == firstFile ? fixture.projection.policy.file : actual
        }
        let second = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "15151515151515151515151515151515", queuedAtMs: 1_700_000_100_001),
            direction: "extension_to_host"
        ))
        #expect(second["result"] as? String == "accepted")
        #expect(second["period_id"] as? String != firstPeriod)
        #expect(fixture.owner.store.getPeriod(periodId: firstPeriod)?.state == "finalized")
        #expect(fixture.owner.store.storeIsFailed() == false)
        fixture.owner.stop()
    }

    @Test func stagingWriteFailureSetsDeliveryFailedAndKeepsCustody() async throws {
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "13131313131313131313131313131313", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        let acceptedPeriod = try #require(fixture.owner.store.getPeriod(periodId: periodId))
        let acceptedFileSize = try #require(FileManager.default.attributesOfItem(atPath: fixture.owner.store.periodFileURL(for: periodId).path)[.size] as? Int)
        #expect(acceptedFileSize == acceptedPeriod.committedLength)
        let writes = Counter()
        fixture.injector.setFailure { point in
            if point == .write, writes.increment() == 2 { throw LifecycleInjectedFailure.injected }
        }
        fixture.clock.advance(seconds: 301)
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let status = fixture.owner.store.currentStatus(nowMs: 1_700_000_401_000, monotonicFreshnessMs: 0)
            if status["delivery"] as? String == "failed" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let status = fixture.owner.store.currentStatus(nowMs: 1_700_000_401_000, monotonicFreshnessMs: 0)
        #expect(status["delivery"] as? String == "failed")
        #expect(status["failure"] as? String == "local_io")
        #expect(fixture.owner.store.getPeriod(periodId: periodId)?.state == "finalized")
        #expect(transport.sources.first == "browser")
        #expect(transport.attempts == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.owner.store.periodFileURL(for: periodId).path))
        #expect(fixture.owner.store.storeIsFailed() == false)
        fixture.owner.stop()
    }

    @Test func damagedRetryAgeFailsClosed() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        defer { fixture.owner.stop() }
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        try fixture.owner.store.recordBatchSeen(generation: generation, inst: "fixture", batchId: "fixture", queuedAtMs: 1, initialAgeMs: 0)
        await fixture.owner.stopAndDrain()
        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.root.appendingPathComponent("intake.sqlite").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "UPDATE batch_seen SET first_seen_ms = -1", nil, nil, nil) == SQLITE_OK)
        #expect(throws: BrowserIntakeStoreError.localIO) {
            try fixture.owner.store.getBatchAge(generation: generation, inst: "fixture", batchId: "fixture")
        }
        #expect(fixture.owner.store.storeIsFailed())
    }

    @Test func wallClockBeforeEpochKeepsEstablishedFloor() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        defer { fixture.owner.stop() }
        let floor = fixture.owner.store.getFloorMs()
        fixture.clock.setWallDate(Date(timeIntervalSince1970: -1))
        _ = fixture.owner.authority.status()
        #expect(fixture.owner.store.getFloorMs() >= floor)
        #expect(!fixture.owner.store.storeIsFailed())
        #expect(BrowserAgeStamp.wallMilliseconds(Date(timeIntervalSince1970: .infinity)) == UInt64(Int64.max))
    }

    @Test(arguments: [false, true])
    func recreatedStoreChargesDowntimeAndRejectsUnknownBoot(reboot: Bool) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let acceptedBytes = batch(generation, id: "aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae", queuedAtMs: 1_700_000_100_000)
        let accepted = try reply(await fixture.owner.accept(bytes: acceptedBytes, direction: "extension_to_host"))
        let period = try #require(accepted["period_id"] as? String)
        let payload = fixture.owner.store.periodFileURL(for: period)
        let original = try Data(contentsOf: payload)
        let queued = UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000) - 9 * 60 * 1000
        let delta = Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"instance-one","batch_id":"afafafafafafafafafafafafafafafaf","queued_at_ms":\(queued),"records":[{"t":"delta","ts":\(queued),"ctx":"unseen","op":"add","block":{"id":"b","text":"delta"}}]}
        """.utf8)
        #expect(try reply(await fixture.owner.accept(bytes: delta, direction: "extension_to_host"))["reason"] as? String == "snapshot_required")
        fixture.clock.advance(seconds: 30)
        #expect(try reply(await fixture.owner.accept(bytes: delta, direction: "extension_to_host"))["reason"] as? String == "snapshot_required")
        fixture.owner.stop()
        fixture.clock.advance(seconds: reboot ? 1 : 40)
        fixture.clock.setWallDate(Date(timeIntervalSince1970: 1_600_000_000))
        if reboot { fixture.clock.reboot() }
        let store = try BrowserIntakeStore(rootURL: fixture.root, projection: fixture.projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: { fixture.clock.ageStamp() })
        let authority = BrowserIntakeAuthority(store: store, projection: fixture.projection,
            monotonicClock: fixture.clock, wallClock: { fixture.clock.wallNow() }, timeZone: fixture.clock.timeZone())
        try authority.reconcileIdentity("lifecycle-pairing", mode: .reload)
        #expect(try authority.accept(bytes: delta, direction: "extension_to_host")["reason"] as? String == "expired_unaccepted")
        #expect(try authority.accept(bytes: acceptedBytes, direction: "extension_to_host")["result"] as? String == "duplicate")
        #expect(try Data(contentsOf: payload) == original)
        #expect(!store.storeIsFailed())
    }

    @Test func retryAgeSurvivesAuthorityRecreationAndRollback() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let queued = UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000) - 9 * 60 * 1000
        let delta = Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"instance-one","batch_id":"acacacacacacacacacacacacacacacac","queued_at_ms":\(queued),"records":[{"t":"delta","ts":\(queued),"ctx":"missing-context","op":"add","block":{"id":"b","text":"delta"}}]}
        """.utf8)
        #expect(try reply(await fixture.owner.accept(bytes: delta, direction: "extension_to_host"))["reason"] as? String == "snapshot_required")
        fixture.clock.advance(seconds: 30)
        #expect(try reply(await fixture.owner.accept(bytes: delta, direction: "extension_to_host"))["reason"] as? String == "snapshot_required")
        fixture.clock.setWallDate(Date(timeIntervalSince1970: 1_600_000_000))
        let authority = BrowserIntakeAuthority(store: fixture.owner.store, projection: fixture.projection,
            monotonicClock: fixture.clock, wallClock: { fixture.clock.wallNow() }, timeZone: fixture.clock.timeZone())
        // The remaining thirty seconds must not reset on the new authority.
        _ = try authority.accept(bytes: delta, direction: "extension_to_host")
        fixture.clock.advance(seconds: 40)
        #expect(try authority.accept(bytes: delta, direction: "extension_to_host")["reason"] as? String == "expired_unaccepted")
        fixture.owner.stop()
    }

    @Test func quietCustodyCrossesWeekDuringClockRollback() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(bytes: batch(generation,
            id: "adadadadadadadadadadadadadadadad", queuedAtMs: 1_700_000_100_000), direction: "extension_to_host"))
        let id = try #require(accepted["period_id"] as? String)
        fixture.clock.setWallDate(Date(timeIntervalSince1970: 1_600_000_000))
        fixture.clock.advance(seconds: 7 * 24 * 60 * 60 + 1)
        let state = try decodedState(fixture.owner.authority.status(), projection: fixture.projection)
        #expect(state.custodyStale)
        #expect(state.capture == "permitted")
        #expect(FileManager.default.fileExists(atPath: fixture.owner.store.periodFileURL(for: id).path))
        fixture.owner.stop()
    }

    @Test func initialAgeAndMonotonicRetryAgeSurviveWallRollback() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let queued = UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000) - 9 * 60 * 1000
        let delta = Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"instance-one","batch_id":"abababababababababababababababab","queued_at_ms":\(queued),"records":[{"t":"delta","ts":\(queued),"ctx":"missing-context","op":"add","block":{"id":"block-one","text":"delta"}}]}
        """.utf8)
        let first = try reply(await fixture.owner.accept(bytes: delta, direction: "extension_to_host"))
        #expect(first["reason"] as? String == "snapshot_required")
        fixture.clock.advance(seconds: 61)
        fixture.clock.setWallDate(Date(timeIntervalSince1970: 1_600_000_000))
        let second = try reply(await fixture.owner.accept(bytes: delta, direction: "extension_to_host"))
        #expect(second["reason"] as? String == "expired_unaccepted")
        fixture.owner.stop()
    }

    @Test func pausedStateKeepsDuplicatesAndAcceptsValidBatches() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        fixture.owner.authority.setPaused(true)
        let queuedAt = UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000)
        let acceptedBytes = batch(generation, id: "31313131313131313131313131313131", queuedAtMs: queuedAt)
        let accepted = try reply(await fixture.owner.accept(bytes: acceptedBytes, direction: "extension_to_host"))
        #expect(accepted["result"] as? String == "accepted")
        let duplicate = try reply(await fixture.owner.accept(bytes: acceptedBytes, direction: "extension_to_host"))
        #expect(duplicate["result"] as? String == "duplicate")
        let status = try decodedState(fixture.owner.authority.status(), projection: fixture.projection)
        #expect(status.capture == "paused")
        #expect(status.capture != "permitted")

        let newBatch = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "32323232323232323232323232323232", queuedAtMs: queuedAt + 1),
            direction: "extension_to_host"
        ))
        #expect(newBatch["result"] as? String == "accepted")
        let malformed = await fixture.owner.accept(bytes: Data("{".utf8), direction: "extension_to_host")
        guard case .refusal(let refusal) = malformed else {
            Issue.record("malformed input was emitted as a wire message")
            return
        }
        #expect(refusal.code == "bad_json")
        fixture.owner.stop()
    }

    @Test func failedStoreStatusIsAValidHostState() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "33333333333333333333333333333333", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        let fileURL = fixture.owner.store.periodFileURL(for: periodId)
        let acceptedBytes = try Data(contentsOf: fileURL)

        fixture.injector.setFailure { point in
            if point == .read { throw LifecycleInjectedFailure.injected }
        }
        let failed = await fixture.owner.accept(
            bytes: batch(generation, id: "34343434343434343434343434343434", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        )
        fixture.injector.setFailure(nil)
        // A read failure during this request is a local refusal. If an owner
        // status read detects it first, the identified batch gets a retryable
        // rejection instead. Neither path may earn an accepted receipt.
        switch failed {
        case .refusal(let refusal):
            #expect(refusal.code == "local_io")
        case .message:
            let rejection = try reply(failed)
            #expect(rejection["result"] as? String == "rejected")
            #expect(rejection["reason"] as? String == "resource_exhausted")
            #expect(rejection["class"] as? String == "retryable")
        }
        let state = try decodedState(fixture.owner.authority.status(), projection: fixture.projection)
        #expect(state.capture == "unavailable")
        #expect(state.destinationGeneration == nil)
        #expect(state.periodId == nil)
        #expect(state.delivery == "failed")
        #expect(state.failure != nil)
        #expect(try Data(contentsOf: fileURL) == acceptedBytes)
        fixture.owner.stop()
    }

    @Test func fullStaleAndTransportFailureRoundTripTogether() async throws {
        let transport = LifecycleTransport()
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "35353535353535353535353535353535", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        let payload = fixture.owner.store.periodFileURL(for: periodId)
        fixture.clock.advance(seconds: 7 * 24 * 60 * 60 + 301)
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "finalized"))
        _ = fixture.owner.authority.status()
        fixture.pause.set(false)
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await transport.waitForAttempts(1))
        fixture.injector.setSizeOverride { url, actual in
            url.lastPathComponent == "intake.sqlite" ? fixture.projection.policy.spoolBytes : actual
        }
        let state = try decodedState(fixture.owner.authority.status(), projection: fixture.projection)
        #expect(state.capture == "intake_off")
        #expect(state.delivery == "failed")
        #expect(state.failure != nil)
        #expect(state.custodyFull)
        #expect(state.custodyStale)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        fixture.owner.stop()
    }

    @Test func staleCustodyStillAcceptsAndUploadsAcrossWallRollback() async throws {
        let transport = LifecycleTransport()
        transport.setOutcomeSuccess(true)
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let first = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "36363636363636363636363636363636", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let firstPeriodId = try #require(first["period_id"] as? String)
        fixture.clock.advance(seconds: 7 * 24 * 60 * 60 + 301)
        #expect(await waitForPeriodState(fixture, periodId: firstPeriodId, state: "finalized"))
        let staleStatus = fixture.owner.authority.status()
        let custody = try #require(staleStatus["custody"] as? [String: Bool])
        #expect(custody["stale"] == true)
        let freshQueuedAt = UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000)
        let second = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "37373737373737373737373737373737", queuedAtMs: freshQueuedAt),
            direction: "extension_to_host"
        ))
        #expect(second["result"] as? String == "accepted")
        let secondPeriodId = try #require(second["period_id"] as? String)
        let firstPayload = fixture.owner.store.periodFileURL(for: firstPeriodId)
        let secondPayload = fixture.owner.store.periodFileURL(for: secondPeriodId)
        fixture.pause.set(false)
        fixture.clock.advance(seconds: 301)
        #expect(await transport.waitForAttempts(2))
        fixture.clock.setWallDate(Date(timeIntervalSince1970: 1_600_000_000))
        let rolledBack = try decodedState(fixture.owner.authority.status(), projection: fixture.projection)
        #expect(rolledBack.custodyStale)
        #expect(FileManager.default.fileExists(atPath: firstPayload.path))
        #expect(FileManager.default.fileExists(atPath: secondPayload.path))
        let persistedBinding = try fixture.owner.store.storedDeliveryBinding(periodId: firstPeriodId)
        let binding = try #require(persistedBinding)
        try fixture.owner.store.releaseProven(periodId: firstPeriodId, binding: binding, nowMs: fixture.owner.store.getFloorMs())
        let youngerOnly = try decodedState(fixture.owner.authority.status(), projection: fixture.projection)
        #expect(!youngerOnly.custodyStale)
        #expect(FileManager.default.fileExists(atPath: secondPayload.path))
        fixture.owner.stop()
    }

    @Test func failedFloorAndAgePersistenceCloseAdmissionWithoutLosingCustody() async throws {
        for failAt in [2, 5] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            fixture.pause.set(true)
            await fixture.owner.start()
            await fixture.clock.waitUntilSleeping()
            let generation = try #require(fixture.owner.store.getActiveGeneration())
            let first = try reply(await fixture.owner.accept(
                bytes: batch(generation, id: String(format: "%032x", 0x380 + failAt), queuedAtMs: 1_700_000_100_000),
                direction: "extension_to_host"
            ))
            let periodId = try #require(first["period_id"] as? String)
            let fileURL = fixture.owner.store.periodFileURL(for: periodId)
            let originalBytes = try Data(contentsOf: fileURL)
            fixture.clock.advance(seconds: 1)
            let steps = Counter()
            fixture.injector.setFailure { point in
                if point == .step && steps.increment() == failAt { throw LifecycleInjectedFailure.injected }
            }
            let failed = try reply(await fixture.owner.accept(
                bytes: batch(generation, id: String(format: "%032x", 0x390 + failAt), queuedAtMs: 1_700_000_101_000),
                direction: "extension_to_host"
            ))
            fixture.injector.setFailure(nil)
            #expect(failed["result"] as? String == "rejected")
            #expect(fixture.owner.store.storeIsFailed())
            #expect(try Data(contentsOf: fileURL) == originalBytes)
            #expect(fixture.owner.authority.isAdmissionOpen() == false)
            fixture.owner.stop()
        }
    }

    @Test func retryableTransportFailureGetsOneOwnerScheduledRetry() async throws {
        let transport = LifecycleTransport()
        let fixture = try fixture(transport: transport)
        defer { fixture.owner.stop(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let accepted = try reply(await fixture.owner.accept(
            bytes: batch(generation, id: "38383838383838383838383838383838", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        let periodId = try #require(accepted["period_id"] as? String)
        fixture.clock.advance(seconds: 301)
        #expect(await transport.waitForAttempts(1))
        #expect(await waitForPeriodState(fixture, periodId: periodId, state: "finalized"))
        #expect(await waitForDeliveryState(fixture, state: "failed"))
        let failed = try decodedState(fixture.owner.authority.status(), projection: fixture.projection)
        #expect(failed.delivery == "failed")
        #expect(failed.failure != nil)

        transport.setOutcomeSuccess(true)
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await transport.waitForAttempts(2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.attempts == 2)
        #expect(transport.maxConcurrent == 1)
        fixture.owner.stop()
    }

    @Test(arguments: [false, true])
    func deliveredRetentionKeepsDuplicateThroughHorizonAndReclaimsHistoryAfterward(removed: Bool) async throws {
        let transport = LifecycleTransport()
        if removed { transport.setOutcomeSegmentRemoved() } else { transport.setOutcomeSuccess(true) }
        let fixture = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.pause.set(true)
        await fixture.owner.start()
        await fixture.clock.waitUntilSleeping()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let firstBytes = batch(generation, id: "39393939393939393939393939393939", queuedAtMs: 1_700_000_100_000)
        let accepted = try reply(await fixture.owner.accept(bytes: firstBytes, direction: "extension_to_host"))
        let deliveredPeriodId = try #require(accepted["period_id"] as? String)
        fixture.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(fixture, periodId: deliveredPeriodId, state: "finalized"))
        fixture.pause.set(false)
        await fixture.updateRoute(.held)
        await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        #expect(await transport.waitForAttempts(1))
        if !removed {
            let storedBinding = try fixture.owner.store.storedDeliveryBinding(periodId: deliveredPeriodId)
            let binding = try #require(storedBinding)
            transport.setDayListing(matchingListing(binding))
            await fixture.updateRoute(.held)
            await fixture.updateRoute(.url("http://127.0.0.1:49321"))
        }
        #expect(await waitForPeriodState(fixture, periodId: deliveredPeriodId, state: removed ? "removed" : "delivered"))
        let deliveredAt = try #require(fixture.owner.store.getPeriod(periodId: deliveredPeriodId)?.deliveredAtMs)
        #expect(try reply(await fixture.owner.accept(bytes: firstBytes, direction: "extension_to_host"))["result"] as? String == "duplicate")

        transport.setOutcomeSuccess(false)
        let heldGeneration = try #require(fixture.owner.store.getActiveGeneration())
        let heldReply = try reply(await fixture.owner.accept(
            bytes: batch(heldGeneration, id: "3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a", queuedAtMs: UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000)),
            direction: "extension_to_host"
        ))
        let heldPeriodId = try #require(heldReply["period_id"] as? String)
        let heldPayload = fixture.owner.store.periodFileURL(for: heldPeriodId)
        fixture.clock.advance(seconds: 301)
        #expect(await waitForPeriodState(fixture, periodId: heldPeriodId, state: "finalized"))
        #expect(await transport.waitForAttempts(2))

        let horizon600 = deliveredAt + 600_000
        let nowAfterSecondBoundary = UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000)
        if horizon600 > nowAfterSecondBoundary {
            fixture.clock.advance(seconds: Double(horizon600 - nowAfterSecondBoundary) / 1000)
        }
        #expect(try reply(await fixture.owner.accept(bytes: firstBytes, direction: "extension_to_host"))["result"] as? String == "duplicate")

        let horizonBeforeExpiry = deliveredAt + 1_199_000
        let nowBeforeExpiry = UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000)
        if horizonBeforeExpiry > nowBeforeExpiry {
            fixture.clock.advance(seconds: Double(horizonBeforeExpiry - nowBeforeExpiry) / 1000)
        }
        #expect(try reply(await fixture.owner.accept(bytes: firstBytes, direction: "extension_to_host"))["result"] as? String == "duplicate")

        let exactHorizon = deliveredAt + 1_200_000
        let nowAtHorizon = UInt64(fixture.clock.wallNow().timeIntervalSince1970 * 1000)
        if exactHorizon > nowAtHorizon {
            fixture.clock.advance(seconds: Double(exactHorizon - nowAtHorizon) / 1000)
        }
        #expect(try reply(await fixture.owner.accept(bytes: firstBytes, direction: "extension_to_host"))["result"] as? String == "duplicate")

        let sleepCount = fixture.clock.sleepCount()
        fixture.clock.advance(seconds: 301)
        #expect(await fixture.clock.waitForSleepCount(sleepCount + 1))
        #expect(fixture.owner.store.getPeriod(periodId: deliveredPeriodId) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.owner.store.periodFileURL(for: deliveredPeriodId).deletingLastPathComponent().path))
        #expect(fixture.owner.store.getPeriod(periodId: heldPeriodId)?.state == "finalized")
        #expect(FileManager.default.fileExists(atPath: heldPayload.path))

        let newGeneration = try #require(fixture.owner.store.getActiveGeneration())
        #expect(newGeneration == generation)
        let expiredReplay = try reply(await fixture.owner.accept(
            bytes: batch(newGeneration, id: "39393939393939393939393939393939", queuedAtMs: 1_700_000_100_000),
            direction: "extension_to_host"
        ))
        #expect(expiredReplay["result"] as? String == "rejected")
        #expect(expiredReplay["reason"] as? String == "expired_unaccepted")
        fixture.owner.stop()
    }

    @Test func duplicateRootKeysUseLastMemberWins() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let bytes = Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"instance-one","batch_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","batch_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","queued_at_ms":1700000100000,"records":[{"t":"segment_start","ts":1700000100000,"ctx":"context-one","blocks":[{"id":"block-one","text":"page"}]}]}
        """.utf8)
        guard case .accept(.batch(let decoded)) = BrowserPayloadDecoder.decode(
            bytes: bytes,
            direction: "extension_to_host",
            projection: fixture.projection
        ) else {
            Issue.record("duplicate root key payload did not decode")
            return
        }
        #expect(Data(decoded.batchId.utf8) == Data("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".utf8))

        let duplicateRecordField = Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"instance-one","batch_id":"12121212121212121212121212121212","queued_at_ms":1700000100000,"records":[{"t":"segment_start","ts":1700000100000,"ctx":"context-one","ctx":"","blocks":[{"id":"block-one","text":"page"}]}]}
        """.utf8)
        guard case .refuse(let recordRefusal) = BrowserPayloadDecoder.decode(
            bytes: duplicateRecordField,
            direction: "extension_to_host",
            projection: fixture.projection
        ) else {
            Issue.record("duplicate record key did not use the last member")
            return
        }
        #expect(recordRefusal.field == "ctx")
        fixture.owner.stop()
    }

    @Test func opaqueIdentifiersCompareExactUTF8() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.owner.start()
        let generation = try #require(fixture.owner.store.getActiveGeneration())
        let composed = String(UnicodeScalar(0x00E9)!)
        let decomposed = String(UnicodeScalar(0x0065)!) + String(UnicodeScalar(0x0301)!)
        let instanceBytes = Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"\(composed)","batch_id":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","queued_at_ms":1700000100000,"records":[{"t":"segment_start","ts":1700000100000,"ctx":"context-one","inst":"\(decomposed)","blocks":[{"id":"block-one","text":"page"}]}]}
        """.utf8)
        guard case .refuse(let instanceRefusal) = BrowserPayloadDecoder.decode(
            bytes: instanceBytes,
            direction: "extension_to_host",
            projection: fixture.projection
        ) else {
            Issue.record("canonically equivalent instance ids were treated as identical")
            return
        }
        #expect(instanceRefusal.field == "inst")

        let contextBytes = Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"instance-one","batch_id":"ffffffffffffffffffffffffffffffff","queued_at_ms":1700000100000,"records":[{"t":"delta","ts":1700000100000,"ctx":"\(composed)","op":"add","block":{"id":"block-one","text":"first"}},{"t":"delta","ts":1700000100001,"ctx":"\(decomposed)","op":"add","block":{"id":"block-two","text":"second"}}]}
        """.utf8)
        guard case .refuse(let contextRefusal) = BrowserPayloadDecoder.decode(
            bytes: contextBytes,
            direction: "extension_to_host",
            projection: fixture.projection
        ) else {
            Issue.record("canonically equivalent context ids were treated as identical")
            return
        }
        #expect(contextRefusal.code == "mixed_context")
        fixture.owner.stop()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.withLock { value } }
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

#endif
