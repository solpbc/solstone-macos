// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import JournalRuntime

@Suite("Journal process utilities")
struct JournalProcessUtilitiesTests {
    @Test func cleanupProbesConfiguredDirectDoorThenConveyWithoutLegacyDefault() async throws {
        let fixture = try JournalRootFixture()
        defer { fixture.clear() }
        try fixture.writeConfig(#"{"pairing":{"direct_port":9000}}"#)
        let runner = FakeSubprocessRunner()
        runner.enqueueLsof(port: 7657, .success(exitCode: 0))
        runner.enqueueLsof(port: 9000, .success(exitCode: 1))
        runner.enqueueLsof(port: 5015, .success(exitCode: 1))

        let failure = await assertPortsReleased(
            resolution: resolveJournalDirectDoorPort(journalRoot: fixture.rootURL),
            runner: runner
        )

        #expect(failure == nil)
        #expect(runner.lsofPorts() == [9000, 5015])
    }

    @Test func cleanupPreservesPortsFailureForBoundDirectDoorPort() async throws {
        let fixture = try JournalRootFixture()
        defer { fixture.clear() }
        try fixture.writeConfig(#"{"pairing":{"direct_port":9000}}"#)
        let runner = FakeSubprocessRunner()
        runner.enqueueLsof(port: 9000, .success(exitCode: 0))

        let failure = await assertPortsReleased(
            resolution: resolveJournalDirectDoorPort(journalRoot: fixture.rootURL),
            runner: runner
        )

        #expect(failure?.step == .ports)
        #expect(failure?.message.contains("port 9000") == true)
        #expect(runner.lsofPorts() == [9000])
    }

    @Test func cleanupPreservesPortsFailureForBoundConveyPort() async throws {
        let fixture = try JournalRootFixture()
        defer { fixture.clear() }
        try fixture.writeConfig(#"{"pairing":{"direct_port":9000}}"#)
        let runner = FakeSubprocessRunner()
        runner.enqueueLsof(port: 9000, .success(exitCode: 1))
        runner.enqueueLsof(port: 5015, .success(exitCode: 0))

        let failure = await assertPortsReleased(
            resolution: resolveJournalDirectDoorPort(journalRoot: fixture.rootURL),
            runner: runner
        )

        #expect(failure?.step == .ports)
        #expect(failure?.message.contains("port 5015") == true)
        #expect(runner.lsofPorts() == [9000, 5015])
    }

    @Test func cleanupUsesNormalDefaultWhenConfigIsMissing() async throws {
        let fixture = try JournalRootFixture()
        defer { fixture.clear() }
        let runner = FakeSubprocessRunner()
        runner.enqueueLsof(port: 7657, .success(exitCode: 1))
        runner.enqueueLsof(port: 5015, .success(exitCode: 1))

        let failure = await assertPortsReleased(
            resolution: resolveJournalDirectDoorPort(journalRoot: fixture.rootURL),
            runner: runner
        )

        #expect(failure == nil)
        #expect(runner.lsofPorts() == [7657, 5015])
    }
}
