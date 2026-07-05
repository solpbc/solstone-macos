import JournalRuntime
import Testing

@Suite("JournalRuntime UICopy")
struct JournalRuntimeUICopyTests {
    @Test func runtimeCopyStrings() {
        #expect(UICopy.JOURNAL_CHILD_BREAKER_TRIPPED == "journal stopped after repeated exits")
        #expect(UICopy.JOURNAL_MATERIALIZE_FAILED == "journal runtime couldn't be prepared")
        #expect(UICopy.JOURNAL_SPAWN_BLOCKED_PORTS == "journal ports are still in use")
        #expect(UICopy.JOURNAL_SPAWN_PORT_CHECK_FAILED == "couldn't verify journal ports are free")
        #expect(UICopy.JOURNAL_READINESS_TIMEOUT == "journal didn't become ready in time")
        #expect(UICopy.JOURNAL_SETUP_NEEDED_BEFORE_UPGRADE == "journal setup needed before upgrade can continue")
        #expect(UICopy.INSTALLER_READINESS_GATE_FAILED == "couldn't get the journal ready for this Mac")
        #expect(UICopy.installerVerifyIntegrityWarning(library: "tokenizers") == "couldn't get tokenizers ready; continuing")
    }
}
