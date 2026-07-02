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
        state.supervisedJournalRunner = RecordingSupervisedChildRunner(recorder: recorder)
        state.terminationDrainer = MainActorHoppingTerminationDrainer(recorder: recorder)

        await state.performQuitPreparation()

        let events = await recorder.events()
        #expect(events == [
            "journal:stopForTermination",
            "drain:clear",
            "drain:wait:start",
            "drain:mainActorHop",
            "drain:wait:end"
        ])
    }

    @Test func updateDrainRunsAfterJournalStop() async {
        let recorder = TerminationDrainRecorder()
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.supervisedJournalRunner = RecordingSupervisedChildRunner(recorder: recorder)
        state.terminationDrainer = MainActorHoppingTerminationDrainer(recorder: recorder)

        await state.performUpdatePreparation()

        let events = await recorder.events()
        #expect(events == [
            "journal:stop",
            "drain:clear",
            "drain:wait:start",
            "drain:mainActorHop",
            "drain:wait:end"
        ])
    }

    @Test func drainAwaitProceedsAfterShortPendingWorkCompletes() async {
        let recorder = TerminationDrainRecorder()
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.supervisedJournalRunner = RecordingSupervisedChildRunner(recorder: recorder)
        state.terminationDrainer = DelayedTerminationDrainer(recorder: recorder)

        await state.performQuitPreparation()

        let events = await recorder.events()
        #expect(events == [
            "journal:stopForTermination",
            "drain:clear",
            "drain:wait:start",
            "drain:wait:end"
        ])
    }
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

private actor RecordingSupervisedChildRunner: SupervisedChildRunning {
    private let recorder: TerminationDrainRecorder

    init(recorder: TerminationDrainRecorder) {
        self.recorder = recorder
    }

    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws {
    }

    func restart() async throws {
    }

    func stop() async {
        await recorder.append("journal:stop")
    }

    func stopForTermination() async {
        await recorder.append("journal:stopForTermination")
    }

    func currentRuntimeKey() async -> String? {
        nil
    }

    func markReady() async {
    }
}
