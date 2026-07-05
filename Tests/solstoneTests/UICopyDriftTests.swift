import JournalRuntime
import Testing
@testable import solstone

@Suite("UICopy drift")
struct UICopyDriftTests {
    @Test func duplicatedMixedJournalRuntimeCopyStaysInSync() {
        #expect(solstone.UICopy.JOURNAL_MATERIALIZE_FAILED == JournalRuntime.UICopy.JOURNAL_MATERIALIZE_FAILED)
        #expect(solstone.UICopy.JOURNAL_READINESS_TIMEOUT == JournalRuntime.UICopy.JOURNAL_READINESS_TIMEOUT)
    }
}
