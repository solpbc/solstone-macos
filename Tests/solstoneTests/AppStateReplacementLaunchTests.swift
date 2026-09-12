import Foundation
import Testing
@testable import solstone

@Suite("AppState replacement launch")
@MainActor
struct AppStateReplacementLaunchTests {
    @Test func replacementLaunchRunnerFailureIsLoggedAndSwallowed() async {
        let harness = DiagnosticEvidenceHarness()
        var logEvents: [DiagnosticEvidenceLogEvent] = []
        let state = AppState.forSnapshot(
            recorder: harness.recorder,
            logAdapter: DiagnosticEvidenceLoggingAdapter { logEvents.append($0) }
        )
        var invocations: [ReplacementLaunchCommand] = []
        var runnerReachedThrow = false
        var returned = false
        state.replacementLaunchRunner = { command in
            invocations.append(command)
            runnerReachedThrow = true
            throw ReplacementLaunchTestError.spawn
        }

        state.launchReplacementForSettingsRestart()
        returned = true

        #expect(returned)
        #expect(runnerReachedThrow)
        #expect(invocations.count == 1)
        #expect(invocations.first?.predecessorPID == getpid())
        #expect(invocations.first?.bundlePath == Bundle.main.bundlePath)
        #expect(logEvents == [.terminationSettingsRelaunchSpawnFailed])
        #expect(await harness.entries().map(\.code) == [.terminationSettingsRelaunchSpawnFailed])
    }
}

private enum ReplacementLaunchTestError: Error {
    case spawn
}
