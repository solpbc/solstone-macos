import Testing
@testable import solstone

@Suite("Replacement launch gate")
struct ReplacementLaunchGateTests {
    @Test func doesNotLaunchWhileAlive() async {
        let events = LockedArray<String>([])

        await ReplacementLaunchGate.waitForPredecessorExitThenLaunch(
            maxPolls: 3,
            pollInterval: .milliseconds(1),
            isPredecessorAlive: {
                events.append("poll")
                return true
            },
            sleep: { _ in
                events.append("sleep")
            },
            launch: {
                events.append("launch")
            }
        )

        #expect(events.all == ["poll", "sleep", "poll", "sleep", "poll", "sleep", "launch"])
    }

    @Test func launchesOnceOnExit() async {
        let polls = LockedCounter()
        let sleeps = LockedCounter()
        let launches = LockedCounter()

        await ReplacementLaunchGate.waitForPredecessorExitThenLaunch(
            maxPolls: 10,
            pollInterval: .milliseconds(1),
            isPredecessorAlive: {
                polls.increment()
                return polls.count < 3
            },
            sleep: { _ in
                sleeps.increment()
            },
            launch: {
                launches.increment()
            }
        )

        #expect(polls.count == 3)
        #expect(sleeps.count == 2)
        #expect(launches.count == 1)
    }

    @Test func launchesOnceAfterBoundWhenNeverDies() async {
        let polls = LockedCounter()
        let sleeps = LockedCounter()
        let launches = LockedCounter()

        await ReplacementLaunchGate.waitForPredecessorExitThenLaunch(
            maxPolls: 3,
            pollInterval: .milliseconds(1),
            isPredecessorAlive: {
                polls.increment()
                return true
            },
            sleep: { _ in
                sleeps.increment()
            },
            launch: {
                launches.increment()
            }
        )

        #expect(polls.count == 3)
        #expect(sleeps.count == 3)
        #expect(launches.count == 1)
    }

    @Test func commandEmbedsPidBoundAndBundle() {
        let command = ReplacementLaunchGate.command(
            predecessorPID: 12_345,
            bundlePath: "/Applications/sol stone test.app"
        )

        #expect(command.predecessorPID == 12_345)
        #expect(command.bundlePath == "/Applications/sol stone test.app")
        #expect(ReplacementLaunchGate.maxPolls == 150)
        #expect(command.shellCommand.contains("kill -0 12345"))
        #expect(command.shellCommand.contains("[ $i -lt 150 ]"))
        #expect(command.shellCommand.contains("sleep 0.200"))
        #expect(command.shellCommand.contains("/usr/bin/open -n"))
        #expect(command.shellCommand.contains("'/Applications/sol stone test.app'"))
    }
}
