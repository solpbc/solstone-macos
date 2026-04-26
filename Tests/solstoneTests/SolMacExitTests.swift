import Testing
import SolstoneCore

@Suite("SolMacExit")
struct SolMacExitTests {
    @Test func rawValuesMatchSpec() {
        #expect(SolMacExit.success.rawValue == 0)
        #expect(SolMacExit.invalidArgs.rawValue == 1)
        #expect(SolMacExit.ipcError.rawValue == 2)
        #expect(SolMacExit.appNotRunning.rawValue == 3)
        #expect(SolMacExit.versionMismatch.rawValue == 4)
        #expect(SolMacExit.localValidation.rawValue == 5)
    }
}
