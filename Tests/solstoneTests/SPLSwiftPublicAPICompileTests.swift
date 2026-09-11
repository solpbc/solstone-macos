// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing

@Suite("SPLTunnel Public API Conformance")
struct SPLSwiftPublicAPICompileTests {
    @Test func publicSupervisorAttemptStateAndUnavailabilityTypesAreAccessible() {
        let idle = TunnelSupervisorAttemptState.idle
        let attempting = TunnelSupervisorAttemptState.attempting
        let connected = TunnelSupervisorAttemptState.connected
        let unavailRetrying = TunnelSupervisorAttemptState.unavailable(.retrying(failureClass: .unreachable, attempt: 1, retryAfter: .seconds(10)))
        let unavailReplacing = TunnelSupervisorAttemptState.unavailable(.replacing)
        let terminalAuth = TunnelSupervisorAttemptState.terminal(.authRefreshRequired)

        #expect(idle == .idle)
        #expect(attempting == .attempting)
        #expect(connected == .connected)
        #expect(unavailRetrying != unavailReplacing)
        #expect(terminalAuth != idle)
    }
}
