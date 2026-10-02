import JournalRuntime
import Testing

@Suite("JournalRuntime UICopy")
struct JournalRuntimeUICopyTests {
    @Test func integrityWarningNamesTheLibrary() {
        #expect(UICopy.installerVerifyIntegrityWarning(library: "tokenizers").contains("tokenizers"))
    }
}
