import Testing
@testable import solstone

@Suite("SolVersionParser")
struct SolVersionParserTests {
    @Test func parsesKnownVersionFormats() {
        #expect(SolVersionParser.parse("sol (solstone) 0.3.2\n") == "0.3.2")
        #expect(SolVersionParser.parse("solstone 0.3.2") == "0.3.2")
        #expect(SolVersionParser.parse("solstone, version 0.3.2") == "0.3.2")
        #expect(SolVersionParser.parse("sol 0.3.2 (build abcd)") == "0.3.2")
        #expect(SolVersionParser.parse("solstone 0.3.2-dev0") == "0.3.2")
    }

    @Test func rejectsUnknownVersionFormats() {
        #expect(SolVersionParser.parse("") == nil)
        #expect(SolVersionParser.parse("unknown-output") == nil)
    }
}
