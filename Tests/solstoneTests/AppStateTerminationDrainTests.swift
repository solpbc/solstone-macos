import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("AppState termination drain")
@MainActor
struct AppStateTerminationDrainTests {
    @Test func quitDrainClearsCallbackThenAwaitsMainActorHoppingCompletion() async {
        let recorder = TerminationDrainRecorder()
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.terminationDrainer = MainActorHoppingTerminationDrainer(recorder: recorder)

        await state.performQuitPreparation()

        let events = await recorder.events()
        #expect(events == [
            "drain:clear",
            "drain:wait:start",
            "drain:mainActorHop",
            "drain:wait:end"
        ])
    }

    @Test func updateDrainRunsAfterJournalStop() async {
        let recorder = TerminationDrainRecorder()
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.terminationDrainer = MainActorHoppingTerminationDrainer(recorder: recorder)

        await state.performUpdatePreparation()

        let events = await recorder.events()
        #expect(events == [
            "drain:clear",
            "drain:wait:start",
            "drain:mainActorHop",
            "drain:wait:end"
        ])
    }

    @Test func drainAwaitProceedsAfterShortPendingWorkCompletes() async {
        let recorder = TerminationDrainRecorder()
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.terminationDrainer = DelayedTerminationDrainer(recorder: recorder)

        await state.performQuitPreparation()

        let events = await recorder.events()
        #expect(events == [
            "drain:clear",
            "drain:wait:start",
            "drain:wait:end"
        ])
    }

    @Test func stopEnqueuesLastSegmentBeforeTerminationDrainWaits() async throws {
        let root = try makeTempDirectory("termination-last-segment")
        defer { try? FileManager.default.removeItem(at: root) }
        let finalizerAndDrainer = RecordingTerminationFinalizerDrainer()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            finalizer: finalizerAndDrainer,
            allowsEmptyDisplayConfigurationForTesting: true
        )
        let segmentDirectory = root.appendingPathComponent("111118.incomplete", isDirectory: true)
        let segment = FakeCaptureSegment(outputDirectory: segmentDirectory)
        manager.seedRecordingForTesting(currentSegment: segment)

        let outcome = await manager.enqueueTransition(.stop(reason: .quit))

        guard case .committed = outcome else {
            Issue.record("expected quit stop to commit")
            return
        }
        #expect(await finalizerAndDrainer.events() == [.enqueue(segmentDirectory)])

        await finalizerAndDrainer.setOnSegmentComplete(nil)
        await finalizerAndDrainer.waitForCompletion()

        #expect(await finalizerAndDrainer.events() == [
            .enqueue(segmentDirectory),
            .clearCallback,
            .waitForCompletion
        ])
    }
}

private enum TerminationDrainEvent: Equatable, Sendable {
    case enqueue(URL)
    case clearCallback
    case setCallback
    case waitForCompletion
}

private actor TerminationDrainRecorder {
    private var recordedEvents: [String] = []

    func append(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }
}

private actor MainActorHoppingTerminationDrainer: TerminationDraining {
    private let recorder: TerminationDrainRecorder

    init(recorder: TerminationDrainRecorder) {
        self.recorder = recorder
    }

    func setOnSegmentComplete(_ callback: (@Sendable (URL, SegmentReconciliation) async -> Void)?) async {
        await recorder.append(callback == nil ? "drain:clear" : "drain:set")
    }

    func waitForCompletion() async {
        await recorder.append("drain:wait:start")
        await MainActor.run {}
        await recorder.append("drain:mainActorHop")
        await recorder.append("drain:wait:end")
    }
}

private actor DelayedTerminationDrainer: TerminationDraining {
    private let recorder: TerminationDrainRecorder

    init(recorder: TerminationDrainRecorder) {
        self.recorder = recorder
    }

    func setOnSegmentComplete(_ callback: (@Sendable (URL, SegmentReconciliation) async -> Void)?) async {
        await recorder.append(callback == nil ? "drain:clear" : "drain:set")
    }

    func waitForCompletion() async {
        await recorder.append("drain:wait:start")
        try? await Task.sleep(for: .milliseconds(10))
        await recorder.append("drain:wait:end")
    }
}

private actor RecordingTerminationFinalizerDrainer: SegmentFinalizing, TerminationDraining {
    private var recordedEvents: [TerminationDrainEvent] = []

    func enqueue(_ job: RemixQueue.RemixJob) async {
        recordedEvents.append(.enqueue(job.segmentDirectory))
    }

    func inFlightPaths() async -> Set<String> {
        []
    }

    func setOnSegmentComplete(_ callback: (@Sendable (URL, SegmentReconciliation) async -> Void)?) async {
        recordedEvents.append(callback == nil ? .clearCallback : .setCallback)
    }

    func waitForCompletion() async {
        recordedEvents.append(.waitForCompletion)
    }

    func events() -> [TerminationDrainEvent] {
        recordedEvents
    }
}
