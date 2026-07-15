// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Placement reopen launcher")
struct PlacementReopenLauncherTests {
    @Test func commandUsesSingletonOpenWithExplicitTarget() {
        let command = PlacementReopenLauncher.command(
            predecessorPID: 12_345,
            targetBundlePath: "/Applications/sol stone.app"
        )

        #expect(command.predecessorPID == 12_345)
        #expect(command.targetBundlePath == "/Applications/sol stone.app")
        #expect(command.shellCommand.contains("kill -0 12345"))
        #expect(command.shellCommand.contains("[ $i -lt 150 ]"))
        #expect(command.shellCommand.contains("/usr/bin/open '/Applications/sol stone.app'"))
        #expect(!command.shellCommand.contains("/usr/bin/open -n"))
    }

    @Test func waitsForExitThenLaunchesOnce() async {
        let polls = LockedCounter()
        let sleeps = LockedCounter()
        let launches = LockedCounter()

        let didLaunch = await PlacementReopenLauncher.waitForPredecessorExitThenLaunch(
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

        #expect(didLaunch)
        #expect(polls.count == 3)
        #expect(sleeps.count == 2)
        #expect(launches.count == 1)
    }

    @Test func neverLaunchesOnTimeoutWhilePredecessorAlive() async {
        let launches = LockedCounter()

        let didLaunch = await PlacementReopenLauncher.waitForPredecessorExitThenLaunch(
            maxPolls: 3,
            pollInterval: .milliseconds(1),
            isPredecessorAlive: { true },
            sleep: { _ in },
            launch: {
                launches.increment()
            }
        )

        #expect(!didLaunch)
        #expect(launches.count == 0)
    }

    @Test func runDetachedSurfacesSpawnError() {
        let command = PlacementReopenLauncher.command(
            predecessorPID: 1,
            targetBundlePath: "/Applications/solstone.app"
        )

        #expect(throws: Error.self) {
            try PlacementReopenLauncher.runDetached(command, shellPath: "/definitely/missing/solstone-shell")
        }
    }
}
