// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Same-Mac pairing reads the device label off the main thread")
@MainActor
struct SameMachineDeviceLabelThreadTests {
    @Test func theLabelIsReadOnABackgroundQueue() async {
        let label = await SPLPairingDefaults.deviceLabelOffMainThread {
            Thread.isMainThread ? "read on main" : "read off main"
        }
        #expect(label == "read off main")
    }

    @Test func pairStartGetsTheLabelReadOffTheMainThread() async {
        let sent = SentLabels()
        let result = await performSameMachineHomePairing(
            baseURL: "http://127.0.0.1:5015",
            existingPairing: .noneHeld,
            startPairing: { _, label in
                sent.record(label)
                return .failure(SameMachinePairStartFailure(kind: .transport))
            },
            readDeviceLabel: { Thread.isMainThread ? "read on main" : "read off main" },
            submitPairingLink: { _ in .idle }
        )

        #expect(result == .failed(.pairStart(.transport)))
        #expect(sent.labels == ["read off main"])
    }
}
