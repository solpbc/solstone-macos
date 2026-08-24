// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Dispatch
import Foundation
import SolstoneCore
import Testing
@testable import solstone

@MainActor
final class DiagnosticEvidenceHarness {
    let clock: TestClock
    let bytes: InMemoryDiagnosticEvidenceBytesStore
    let store: DiagnosticEvidenceStore
    let recorder: DiagnosticEvidenceRecorder
    private let taskStarts: LockedCounter
    private let storeCalls: LockedCounter

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        let taskStarts = LockedCounter()
        let storeCalls = LockedCounter()
        let countingBytes = CountingDiagnosticEvidenceBytesStore(
            base: bytes,
            onReadCanonical: { storeCalls.increment() }
        )
        self.clock = clock
        self.bytes = bytes
        self.taskStarts = taskStarts
        self.storeCalls = storeCalls
        self.store = DiagnosticEvidenceStore(bytesStore: countingBytes, now: { clock.now })
        self.recorder = DiagnosticEvidenceRecorder(
            store: store,
            now: { clock.now },
            taskStarted: { taskStarts.increment() }
        )
    }

    func entries() async -> [DiagnosticEvidenceEntry] {
        await recorder.drain()
        guard case .available(let envelope) = await store.read() else {
            return []
        }
        return envelope.entries
    }

    func canonicalBytes() async -> Data? {
        await recorder.drain()
        // Independent JSON encodes can vary key order; normalize only cross-fixture canonical comparisons.
        guard let data = bytes.stored,
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return bytes.stored
        }
        return canonical
    }

    func waitForRecorderTasks(_ count: Int) async throws {
        try await withTimeout(seconds: 10) {
            await self.taskStarts.waitUntilCount(count)
        }
    }

    func waitForStoreCalls(_ count: Int) async throws {
        try await withTimeout(seconds: 10) {
            await self.storeCalls.waitUntilCount(count)
        }
    }

    var recorderTaskStartCount: Int { taskStarts.count }
    var storeCallCount: Int { storeCalls.count }
}

private final class CountingDiagnosticEvidenceBytesStore: DiagnosticEvidenceBytesStoring, @unchecked Sendable {
    private let base: InMemoryDiagnosticEvidenceBytesStore
    private let onReadCanonical: @Sendable () -> Void

    init(
        base: InMemoryDiagnosticEvidenceBytesStore,
        onReadCanonical: @escaping @Sendable () -> Void
    ) {
        self.base = base
        self.onReadCanonical = onReadCanonical
    }

    func readCanonical() -> DiagnosticEvidenceBytesRead {
        onReadCanonical()
        return base.readCanonical()
    }

    func encode(_ envelope: DiagnosticEvidenceEnvelope) -> DiagnosticEvidenceEncodingResult {
        base.encode(envelope)
    }

    func stage(_ data: Data) -> DiagnosticEvidenceStagingResult {
        base.stage(data)
    }

    func readStaged(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceBytesRead {
        base.readStaged(staging)
    }

    func commit(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceCommitResult {
        base.commit(staging)
    }

    func removeStaging(_ staging: DiagnosticEvidenceStagingHandle) {
        base.removeStaging(staging)
    }
}

final class GatedDiagnosticEvidenceBytesStore: DiagnosticEvidenceBytesStoring, @unchecked Sendable {
    private let base = InMemoryDiagnosticEvidenceBytesStore()
    private let lock = NSLock()
    private let firstRead = DispatchSemaphore(value: 0)
    private let releaseRead = DispatchSemaphore(value: 0)
    private var shouldGateFirstRead = true
    private(set) var readCanonicalCount = 0
    private(set) var commitCount = 0

    func readCanonical() -> DiagnosticEvidenceBytesRead {
        let shouldBlock = lock.withLock {
            readCanonicalCount += 1
            defer { shouldGateFirstRead = false }
            return shouldGateFirstRead
        }
        if shouldBlock {
            firstRead.signal()
            releaseRead.wait()
        }
        return base.readCanonical()
    }

    func encode(_ envelope: DiagnosticEvidenceEnvelope) -> DiagnosticEvidenceEncodingResult { base.encode(envelope) }
    func stage(_ data: Data) -> DiagnosticEvidenceStagingResult { base.stage(data) }
    func readStaged(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceBytesRead { base.readStaged(staging) }
    func removeStaging(_ staging: DiagnosticEvidenceStagingHandle) { base.removeStaging(staging) }

    func commit(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceCommitResult {
        let result = base.commit(staging)
        if result == .committed {
            lock.withLock { commitCount += 1 }
        }
        return result
    }

    func waitForFirstRead() -> Bool { firstRead.wait(timeout: .now() + 2) == .success }
    func releaseFirstRead() { releaseRead.signal() }
    func counts() -> (reads: Int, commits: Int) { lock.withLock { (readCanonicalCount, commitCount) } }
}

@MainActor
final class EvidenceStartSpy {
    var count = 0
}

@MainActor
final class PermissionPollTestScheduler {
    private(set) var armCount = 0
    private(set) var cancellationCount = 0
    private var passes: [UUID: PermissionPollScheduler.Pass] = [:]

    var outstandingArmCount: Int { passes.count }

    var scheduler: PermissionPollScheduler {
        PermissionPollScheduler { [self] pass in
            let id = UUID()
            armCount += 1
            passes[id] = pass
            return { [self] in
                guard passes.removeValue(forKey: id) != nil else { return }
                cancellationCount += 1
            }
        }
    }

    func fireOutstandingPasses() async {
        let outstandingPasses = Array(passes.values)
        for pass in outstandingPasses {
            await pass()
        }
    }
}

@MainActor
final class MutableScreenPermissionProvider {
    var prompted = true
    var preflight = true
    var granted = false
    private(set) var resetCount = 0

    var provider: ScreenRecordingPermissionProvider {
        ScreenRecordingPermissionProvider(
            hasPrompted: { self.prompted },
            preflight: { self.preflight },
            checkScreenRecording: { self.granted },
            resetPromptedFlag: {
                self.resetCount += 1
                self.prompted = false
            }
        )
    }
}

@MainActor
func makeScreenPermissionProvider(
    prompted: Bool = true,
    preflight: Bool = true,
    screenGranted: Bool = true,
    reset: @escaping @MainActor @Sendable () -> Void = {}
) -> ScreenRecordingPermissionProvider {
    ScreenRecordingPermissionProvider(
        hasPrompted: { prompted },
        preflight: { preflight },
        checkScreenRecording: { screenGranted },
        resetPromptedFlag: reset
    )
}

@MainActor
func makeEvidenceCoordinator(
    recorder: DiagnosticEvidenceRecorder,
    screenPermissionProvider: ScreenRecordingPermissionProvider,
    isTerminating: @escaping CaptureCoordinator.IsTerminatingProvider = { false },
    startOperation: CaptureCoordinator.StartOperation? = nil,
    logAdapter: DiagnosticEvidenceLoggingAdapter = DiagnosticEvidenceLoggingAdapter()
) throws -> (CaptureCoordinator, URL) {
    let root = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
        .appendingPathComponent("solstone-evidence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let coordinator = CaptureCoordinator(
        captureManager: CaptureManager(storageManager: StorageManager(baseDirectory: root)),
        pauseManager: PauseManager(),
        audioDeviceMonitor: AudioDeviceMonitor(startListening: false),
        isTerminating: isTerminating,
        configProvider: { (disabled: [], enabled: []) },
        bannerSink: { _ in },
        startOperation: startOperation,
        recorder: recorder,
        screenPermissionProvider: screenPermissionProvider,
        permissionPollScheduler: PermissionPollTestScheduler().scheduler,
        logAdapter: logAdapter
    )
    return (coordinator, root)
}

func evidenceCodes(_ entries: [DiagnosticEvidenceEntry]) -> [DiagnosticEvidenceCode] {
    entries.map(\.code)
}
