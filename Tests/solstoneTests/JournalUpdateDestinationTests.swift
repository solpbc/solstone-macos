// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("JournalUpdateDestination")
@MainActor
struct JournalUpdateDestinationTests {
    private let home = TunnelPairingIdentity(instanceID: "home", fingerprint: "home-ca")

    @Test func matchingIdentityIsRequired() async {
        var requested: String?
        let verified = await verifyLocalJournalForUpdate(expected: home, currentPairing: { home }) { id in
            requested = id
            return true
        }
        #expect(verified)
        #expect(requested == home.instanceID)
        #expect(await verifyLocalJournalForUpdate(expected: home, currentPairing: { home }) { _ in false } == false)
        #expect(await verifyLocalJournalForUpdate(expected: nil, currentPairing: { nil }) { _ in
            Issue.record("unpaired discovery must not run")
            return true
        } == false)
    }

    @Test func pairingChangeDuringDiscoveryDiscardsTheMatch() async {
        var current: TunnelPairingIdentity? = home
        let verified = await verifyLocalJournalForUpdate(expected: home, currentPairing: { current }) { _ in
            current = TunnelPairingIdentity(instanceID: "home", fingerprint: "changed-ca")
            return true
        }
        #expect(!verified)
    }
}
