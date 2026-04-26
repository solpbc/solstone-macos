import Testing
@testable import sol_mac

@Suite("SolMacLogsArgv")
struct SolMacLogsArgvTests {
    @Test func defaultShowArgs() {
        let argv = buildLogsArgv(tail: false, category: nil, last: nil)
        #expect(argv == [
            "show", "--predicate", #"subsystem == "app.solstone.observer""#,
            "--last", "1h",
            "--info", "--debug", "--style", "compact"
        ])
    }

    @Test func tailArgsOmitLast() {
        let argv = buildLogsArgv(tail: true, category: nil, last: nil)
        #expect(argv == [
            "stream", "--predicate", #"subsystem == "app.solstone.observer""#,
            "--level", "debug"
        ])
    }

    @Test func categoryPredicate() {
        let argv = buildLogsArgv(tail: false, category: "audio", last: nil)
        #expect(argv[2] == #"subsystem == "app.solstone.observer" AND category == "audio""#)
    }

    @Test func customLastDuration() {
        let argv = buildLogsArgv(tail: false, category: nil, last: "30m")
        #expect(argv.contains("30m"))
    }

    @Test func tailWithCategory() {
        let argv = buildLogsArgv(tail: true, category: "upload", last: nil)
        #expect(argv == [
            "stream", "--predicate", #"subsystem == "app.solstone.observer" AND category == "upload""#,
            "--level", "debug"
        ])
    }
}
