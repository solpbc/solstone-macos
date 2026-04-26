import Testing
import SolstoneCore

@Suite("SolMacCopy")
struct SolMacCopyTests {
    @Test func appNotRunningLiteral() {
        #expect(SolMacCopy.appNotRunning == "solstone is not running")
    }

    @Test func stopNoopLiteral() {
        #expect(SolMacCopy.stopNoop == "solstone is not recording")
    }

    @Test func versionMismatchTemplate() {
        #expect(
            SolMacCopy.versionMismatch(serverVersion: 2, clientVersion: 1) ==
                "protocol version skew: cli v1 → app v2. update one to match."
        )
    }

    @Test func installAndTranslocationLiteralsPresent() {
        #expect(!SolMacCopy.installSuccess.isEmpty)
        #expect(!SolMacCopy.installNeedsAuth.isEmpty)
        #expect(!SolMacCopy.translocationDetected.isEmpty)
        #expect(!SolMacCopy.translocationRemedy.isEmpty)
    }
}
