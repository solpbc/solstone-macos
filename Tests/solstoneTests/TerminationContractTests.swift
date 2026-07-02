import Foundation
import Testing

@Suite("Termination contract")
struct TerminationContractTests {
    @Test func applicationWillTerminateContainsNoBlockingDrain() throws {
        let source = try readSource("Sources/solstone/SolstoneCaptureApp.swift")
        let body = try extract(
            from: source,
            start: "func applicationWillTerminate(_ notification: Notification)",
            end: "@main"
        )

        for forbidden in ["DispatchSemaphore", "wait(timeout", "Task.detached", "beginActivity", "waitForCompletion"] {
            #expect(!body.contains(forbidden))
        }
    }

    @Test func appStateTerminationDrainIsBoundedAndSharedByPreparations() throws {
        let source = try readSource("Sources/solstone/AppState.swift")
        let drainBody = try extract(
            from: source,
            start: "private func drainRemixQueueForTermination() async",
            end: "    // MARK: - Login Item"
        )
        let quitBody = try extract(
            from: source,
            start: "internal func performQuitPreparation() async",
            end: "internal func performUpdatePreparation() async"
        )
        let updateBody = try extract(
            from: source,
            start: "internal func performUpdatePreparation() async",
            end: "private func drainRemixQueueForTermination() async"
        )

        #expect(ranges(of: "private func drainRemixQueueForTermination() async", in: source).count == 1)
        #expect(drainBody.contains("withTimeout(seconds: 30)"))
        #expect(drainBody.contains(".warning("))
        #expect(quitBody.contains("await drainRemixQueueForTermination()"))
        #expect(updateBody.contains("await drainRemixQueueForTermination()"))
    }

    private func readSource(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func extract(from source: String, start: String, end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source[startRange.upperBound...].range(of: end))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func ranges(of needle: String, in source: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source[searchStart...].range(of: needle) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }
}
