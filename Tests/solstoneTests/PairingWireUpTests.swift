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
            "AXID.Settings.Service.pairingMarkConfirm",
            "AXID.Settings.Service.pairingMarkMismatch",
            "AXID.Settings.Service.pairingMismatchFreshLink",
            "AXID.Settings.Service.pairingMismatchSupport",
            "can't sync over the internet yet"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }
}
