// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

struct SyntheticRemixError: Error, Sendable {}

final class RemixGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func release() {
        lock.withLock { released = true }
    }

    var isReleased: Bool {
        lock.withLock { released }
    }
}

/// One-shot gate that blocks `wait()` until `release()` is called. Used to
/// hold a faked async operation in flight without wall-clock sleeps.
final class OneShotContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let saved = continuation
            continuation = nil
            return saved
        }
        pending?.resume()
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        let continuations = lock.withLock {
            value += 1
            var ready: [CheckedContinuation<Void, Never>] = []
            var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
            for waiter in waiters {
                if value >= waiter.target {
                    ready.append(waiter.continuation)
                } else {
                    pending.append(waiter)
                }
            }
            waiters = pending
            return ready
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    var count: Int {
        lock.withLock { value }
    }

    func waitUntilCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            var shouldResume = false
            lock.withLock {
                if value >= target {
                    shouldResume = true
                } else {
                    waiters.append((target: target, continuation: continuation))
                }
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

final class FakeScreenshotCapturer: SegmentScreenshotCapturing, @unchecked Sendable {
    enum Behavior: Sendable {
        case normal
        case hangStop
        case throwOnStart
    }

    let behavior: Behavior
    let startCount = LockedCounter()
    let stopCount = LockedCounter()
    let finishCount = LockedCounter()

    init(behavior: Behavior = .normal) {
        self.behavior = behavior
    }

    func start() async throws {
        startCount.increment()
        if case .throwOnStart = behavior {
            throw FakeCaptureError.startFailed
        }
    }

    func stop() async {
        stopCount.increment()
        if case .hangStop = behavior {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func updateContentFilter(_ filter: SCContentFilter) async {}

    func finishWithTimeout(seconds: Double) async -> Result<(URL, Int), Error>? {
        finishCount.increment()
        return .success((URL(fileURLWithPath: "/tmp/fake.mp4"), 1))
    }
}

final class FakeAudioManager: SegmentAudioManaging, @unchecked Sendable {
    enum Behavior: Sendable {
        case normal
        case hangFinishAll
    }

    let behavior: Behavior
    let startSystemAudioCount = LockedCounter()
    let addMicrophoneCount = LockedCounter()
    let finishAllCount = LockedCounter()

    init(behavior: Behavior = .normal) {
        self.behavior = behavior
    }

    func setSegmentStartTime(_ time: CMTime) {}

    func startSystemAudio() throws -> String {
        startSystemAudioCount.increment()
        return "system"
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {}

    func addMicrophone(_ device: AudioInputDevice) throws -> String {
        addMicrophoneCount.increment()
        return device.uid
    }

    func removeMicrophone(deviceUID: String) {}

    func hasMicrophone(deviceUID: String) -> Bool { false }

    func activeMicrophoneUIDs() -> [String] { [] }

    func getMicMetadata() -> [[String: Any]] { [] }

    func finishAll() async -> [AudioRemixerInput] {
        finishAllCount.increment()
        if case .hangFinishAll = behavior {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return []
    }
}

@MainActor
final class FakeCaptureSegment: CaptureSegmentWriting, @unchecked Sendable {
    enum FinishCaptureBehavior: Sendable {
        case normal(URL?)
        case hang
    }

    let outputDirectory: URL
    let finishBehaviors: LockedArray<FinishCaptureBehavior>
    let startBehavior: FakeSegmentStartBehavior
    let startGate: OneShotContinuationGate?
    let finishGate: OneShotContinuationGate?
    let startCount = LockedCounter()
    let finishCaptureCount = LockedCounter()

    init(
        outputDirectory: URL,
        finishBehaviors: [FinishCaptureBehavior] = [.normal(nil)],
        startBehavior: FakeSegmentStartBehavior = .normal,
        startGate: OneShotContinuationGate? = nil,
        finishGate: OneShotContinuationGate? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.finishBehaviors = LockedArray(finishBehaviors)
        self.startBehavior = startBehavior
        self.startGate = startGate
        self.finishGate = finishGate
    }

    func start(
        displayInfos: [DisplayInfo],
        filters: [CGDirectDisplayID: SCContentFilter],
        audioFilter: SCContentFilter?,
        mics: [AudioInputDevice],
        micCaptureManager: MicrophoneCaptureManager?,
        systemAudioCaptureManager: SystemAudioCaptureManager?
    ) async throws {
        startCount.increment()
        await startGate?.wait()
        if case .throwPartway = startBehavior {
            throw FakeCaptureError.startFailed
        }
    }

    func finishCapture() async -> SegmentCaptureResult? {
        finishCaptureCount.increment()
        await finishGate?.wait()
        let behavior = finishBehaviors.removeFirst(default: .normal(nil))
        switch behavior {
        case .hang:
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        case .normal(let directory):
            let dir = directory ?? outputDirectory
            return SegmentCaptureResult(
                segmentDirectory: dir,
                timePrefix: String(dir.lastPathComponent.prefix(6)),
                capturedDurationSeconds: 1,
                audioInputs: [],
                debugKeepRejected: false,
                silenceMusic: true,
                micMetadataJSON: nil
            )
        }
    }

    func updateContentFilter(_ filters: [CGDirectDisplayID: SCContentFilter]) async throws {}
    func addMicrophone(_ device: AudioInputDevice) throws {}
    func removeMicrophone(deviceUID: String) {}
    func hasMicrophone(deviceUID: String) -> Bool { false }
    func activeMicrophoneUIDs() -> [String] { [] }
}

enum FakeSegmentStartBehavior: Sendable {
    case normal
    case throwPartway
}

final class FakeRemixer: AudioRemixing, @unchecked Sendable {
    enum Behavior: Sendable {
        case hang
        case success
        case gatedSuccess(RemixGate)
        case throwing(any Error & Sendable)
    }

    let behavior: Behavior
    let remixCount = LockedCounter()
    let recordedInputs = LockedArray<[AudioRemixerInput]>([])
    let recordedSilenceMusic = LockedArray<Bool>([])

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func waitForRemixStart(_ target: Int = 1) async {
        await remixCount.waitUntilCount(target)
    }

    func remix(
        inputs: [AudioRemixerInput],
        to outputURL: URL,
        deleteSourceFiles: Bool,
        silenceMusic: Bool
    ) async throws -> AudioRemixerResult {
        remixCount.increment()
        recordedInputs.append(inputs)
        recordedSilenceMusic.append(silenceMusic)
        switch behavior {
        case .hang:
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return AudioRemixerResult(tracksWritten: 0, tracksSkipped: 0, sourceFiles: [])
        case .success:
            try Data("ok".utf8).write(to: outputURL)
            return AudioRemixerResult(tracksWritten: 1, tracksSkipped: 0, sourceFiles: [])
        case .gatedSuccess(let gate):
            while !gate.isReleased && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            try Data("ok".utf8).write(to: outputURL)
            return AudioRemixerResult(tracksWritten: 1, tracksSkipped: 0, sourceFiles: [])
        case .throwing(let error):
            throw error
        }
    }
}

final class CountingRecovery: IncompleteSegmentRecovering, @unchecked Sendable {
    enum Behavior: Sendable {
        case normal
        case hang
    }

    let behavior: Behavior
    let count = LockedCounter()

    init(_ behavior: Behavior = .normal) {
        self.behavior = behavior
    }

    func waitForRecoverAll(_ target: Int) async {
        await count.waitUntilCount(target)
    }

    func recoverAll(excludingActiveSegment activeSegmentPath: String?) async -> Int {
        count.increment()
        if case .hang = behavior {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return 1
    }
}

final class FakeFinalizer: SegmentFinalizing, @unchecked Sendable {
    let enqueuedDirectories = LockedArray<URL>([])
    let events = LockedArray<String>([])
    private let inFlight: Set<String>

    init(inFlight: Set<String> = []) {
        self.inFlight = inFlight
    }

    func enqueue(_ job: RemixQueue.RemixJob) async {
        enqueuedDirectories.append(job.segmentDirectory)
        events.append("enqueue")
    }

    func inFlightPaths() async -> Set<String> { inFlight }

    func waitForCompletion() async {
        events.append("wait")
    }
}

final class LockedArray<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element]

    init(_ values: [Element]) {
        self.values = values
    }

    func removeFirst(default defaultValue: Element) -> Element {
        lock.withLock {
            guard !values.isEmpty else { return defaultValue }
            return values.removeFirst()
        }
    }

    func append(_ value: Element) {
        lock.withLock {
            values.append(value)
        }
    }

    var all: [Element] {
        lock.withLock { values }
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.withLock { self.value = value }
    }

    var current: Value? {
        lock.withLock { value }
    }
}

enum FakeCaptureError: Error {
    case startFailed
}

func makeTempDirectory(_ prefix: String = "solstone-test") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func waitUntil(
    timeout: Duration,
    poll: Duration = .milliseconds(50),
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: poll)
    }
    #expect(await predicate())
}
