// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("Pairing WireUp")
struct PairingWireUpTests {
    @Test func settingsServiceTabReferencesExpectedPairingAXIDs() throws {
        let source = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let references = [
            "pairingSection",
            "externalServiceSection",
            "AXID.Settings.Service.pairingLink",
            "AXID.Settings.Service.pairingConnect",
            "AXID.Settings.Service.pairingUnpair",
            "AXID.Settings.Service.pairingRetry",
            "AXID.Settings.Service.pairingSwitchConfirm",
            "AXID.Settings.Service.pairingSwitchCancel",
            "AXID.Settings.Service.pairingFlowState",
            "AXID.Settings.Service.pairingFailureState",
            "AXID.Settings.Service.pairingConnectionState",
            "paired, but your home isn't on the paid tier — sync can't connect"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }
}
