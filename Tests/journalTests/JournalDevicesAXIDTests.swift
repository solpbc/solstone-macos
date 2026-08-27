// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import journal

@Suite("JournalDevicesAXID")
struct JournalDevicesAXIDTests {
    @Test func rowFingerprintIDsAreSanitizedAndMatchContractPattern() {
        let fingerprint = "ABC.123_$"
        let ids = [
            AXID.Journal.Devices.Row.container(fingerprint),
            AXID.Journal.Devices.Row.label(fingerprint),
            AXID.Journal.Devices.Row.detailState(fingerprint),
            AXID.Journal.Devices.Row.revoke(fingerprint),
        ]

        #expect(AXID.Journal.Devices.Row.sanitizedFingerprint(fingerprint) == "abc-123")
        #expect(AXID.Journal.Devices.Row.sanitizedFingerprint("éABC.１２_$") == "abc")
        #expect(AXID.Journal.Devices.Row.sanitizedFingerprint("é漢") == "unknown")
        for id in ids {
            #expect(id.range(of: AXContract.idPattern, options: .regularExpression) != nil)
            #expect(id.contains("fingerprint-abc-123"))
        }
        #expect(
            AXContract.stateKey(for: AXID.Journal.Devices.Row.detailState(fingerprint))
                == "journal.devices.row.fingerprint-{fingerprint}.detail.state"
        )
    }

    @Test func devicesRuntimeTemplatesAreRegistered() {
        let templates = Set(AXContract.parameterizedTemplates.map(\.template))

        #expect(templates.contains("journal.devices.row.fingerprint-{fingerprint}"))
        #expect(templates.contains("journal.devices.row.fingerprint-{fingerprint}.detail.state"))
        #expect(templates.contains("journal.devices.row.fingerprint-{fingerprint}.label"))
        #expect(templates.contains("journal.devices.row.fingerprint-{fingerprint}.revoke"))
    }

    @Test func devicesStateTokensMatchTokenPattern() {
        let tokens = JournalDevicesLoadState.axTokens + PairingState.axTokens + JournalDevicesCopiedState.axTokens

        for token in tokens {
            #expect(token.range(of: AXContract.tokenPattern, options: .regularExpression) != nil)
        }
    }
}
