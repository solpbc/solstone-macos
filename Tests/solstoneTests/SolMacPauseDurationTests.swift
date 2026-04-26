import ArgumentParser
import Testing
@testable import sol_mac

@Suite("SolMacPauseDuration")
struct SolMacPauseDurationTests {
    @Test func parses30s() throws {
        #expect(try parsePauseDuration("30s") == 30)
    }

    @Test func parses30m() throws {
        #expect(try parsePauseDuration("30m") == 1_800)
    }

    @Test func parses2h() throws {
        #expect(try parsePauseDuration("2h") == 7_200)
    }

    @Test func parses1d() throws {
        #expect(try parsePauseDuration("1d") == 86_400)
    }

    @Test func parsesBareInteger() throws {
        #expect(try parsePauseDuration("60") == 60)
    }

    @Test func parsesZero() throws {
        #expect(try parsePauseDuration("0") == 0)
    }

    @Test func rejectsGarbage() {
        #expect(throws: ValidationError.self) {
            try parsePauseDuration("garbage")
        }
    }

    @Test func rejectsNegativeOrEmpty() {
        #expect(throws: ValidationError.self) {
            try parsePauseDuration("-1")
        }
        #expect(throws: ValidationError.self) {
            try parsePauseDuration("")
        }
    }
}
