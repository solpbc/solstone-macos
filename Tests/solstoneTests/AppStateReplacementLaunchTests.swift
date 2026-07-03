import Foundation
import Testing
@testable import solstone

@Suite("AppState replacement launch")
@MainActor
struct AppStateReplacementLaunchTests {
    @Test func replacementLaunchRunnerFailureIsLoggedAndSwallowed() {
        let state = AppState.forSnapshot()
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
    }
}

private enum ReplacementLaunchTestError: Error {
    case spawn
}
