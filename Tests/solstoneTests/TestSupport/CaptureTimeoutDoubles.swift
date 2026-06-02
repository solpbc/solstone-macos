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

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
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
    let startCount = LockedCounter()
    let finishCaptureCount = LockedCounter()

    init(
        outputDirectory: URL,
        finishBehaviors: [FinishCaptureBehavior] = [.normal(nil)],
        startBehavior: FakeSegmentStartBehavior = .normal
    ) {
        self.outputDirectory = outputDirectory
        self.finishBehaviors = LockedArray(finishBehaviors)
        self.startBehavior = startBehavior
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
        if case .throwPartway = startBehavior {
            throw FakeCaptureError.startFailed
        }
    }

    func finishCapture() async -> SegmentCaptureResult? {
        finishCaptureCount.increment()
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
                captureStartTime: Date().addingTimeInterval(-1),
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
    private let inFlight: Set<String>

    init(inFlight: Set<String> = []) {
        self.inFlight = inFlight
    }

    func enqueue(_ job: RemixQueue.RemixJob) async {
        enqueuedDirectories.append(job.segmentDirectory)
    }

    func inFlightPaths() async -> Set<String> { inFlight }
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
