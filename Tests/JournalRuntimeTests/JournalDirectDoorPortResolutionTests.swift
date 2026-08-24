// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import JournalRuntime

@Suite("JournalDirectDoorPortResolution")
struct JournalDirectDoorPortResolutionTests {
    @Test func missingAndAbsentKeysUseNormalDefault() throws {
        let fixture = try JournalRootFixture()
        defer { fixture.clear() }

        #expect(resolveJournalDirectDoorPort(journalRoot: fixture.rootURL) == normalDefault())

        try fixture.writeConfig("{}")
        #expect(resolveJournalDirectDoorPort(journalRoot: fixture.rootURL) == normalDefault())

        try fixture.writeConfig(#"{"pairing":{}}"#)
        #expect(resolveJournalDirectDoorPort(journalRoot: fixture.rootURL) == normalDefault())
    }

    @Test func validDirectPortIsConfiguredAndPreflightsConveySecond() throws {
        let fixture = try JournalRootFixture()
        defer { fixture.clear() }
        try fixture.writeConfig(#"{"pairing":{"direct_port":9000}}"#)

        let resolution = resolveJournalDirectDoorPort(journalRoot: fixture.rootURL)

        #expect(resolution == JournalDirectDoorPortResolution(port: 9000, provenance: .configured))
        #expect(JournalLifecyclePortPreflight.orderedPorts(for: resolution) == [9000, 5015])
    }

    @Test func malformedShapesAndValuesDegradeToDefault() throws {
        let fixture = try JournalRootFixture()
        defer { fixture.clear() }
        let cases: [(String, JournalDirectDoorPortDegradationReason)] = [
            ("{", .invalidJSON),
            ("[]", .rootNotObject),
            (#"{"pairing":null}"#, .pairingNull),
            (#"{"pairing":[]}"#, .pairingNotObject),
            (#"{"pairing":{"direct_port":null}}"#, .directPortNull),
            (#"{"pairing":{"direct_port":"9000"}}"#, .directPortWrongType),
            (#"{"pairing":{"direct_port":true}}"#, .directPortWrongType),
            (#"{"pairing":{"direct_port":9000.0}}"#, .directPortWrongType),
            (#"{"pairing":{"direct_port":0}}"#, .directPortZero),
            (#"{"pairing":{"direct_port":-1}}"#, .directPortOutOfRange),
            (#"{"pairing":{"direct_port":65536}}"#, .directPortOutOfRange),
        ]

        for (json, reason) in cases {
            try fixture.writeConfig(json)
            #expect(resolveJournalDirectDoorPort(journalRoot: fixture.rootURL) == degradedDefault(reason))
        }
    }

    @Test(.enabled(if: geteuid() != 0, "root can bypass the fixture's mode-bit read denial"))
    func unreadableConfigDegradesToDefault() throws {
        let fixture = try JournalRootFixture()
        defer { fixture.clear() }
        try fixture.writeConfig(#"{"pairing":{"direct_port":9000}}"#)
        let originalPermissions = try fixture.makeConfigUnreadable()
        defer { try? fixture.restoreConfigPermissions(originalPermissions) }

        #expect(resolveJournalDirectDoorPort(journalRoot: fixture.rootURL) == degradedDefault(.configUnreadable))
    }

    @Test func degradationFormatterCarriesReasonAndFallbackPort() {
        let message = journalDirectDoorPortDegradationMessage(reason: .invalidJSON, fallbackPort: 7657)

        #expect(message.contains("reason=invalid-json"))
        #expect(message.contains("fallbackPort=7657"))
    }

    private func normalDefault() -> JournalDirectDoorPortResolution {
        JournalDirectDoorPortResolution(port: 7657, provenance: .normalDefault)
    }

    private func degradedDefault(_ reason: JournalDirectDoorPortDegradationReason) -> JournalDirectDoorPortResolution {
        JournalDirectDoorPortResolution(port: 7657, provenance: .degraded(reason: reason))
    }
}
