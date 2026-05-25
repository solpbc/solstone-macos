// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Testing
@testable import solstone

@Suite("WindowExclusionManager filter map keys")
struct WindowExclusionFilterMapKeysTests {
    private struct MockDisplay: DisplayIDProvider {
        let displayID: CGDirectDisplayID
    }

    @Test func oneDisplayProducesOneKey() {
        let displays = [MockDisplay(displayID: 10)]

        let keys = WindowExclusionManager.filterMapKeys(from: displays)

        #expect(keys == Set(displays.map(\.displayID)))
    }

    @Test func threeDisplaysProduceExpectedKeys() {
        let displays = [
            MockDisplay(displayID: 10),
            MockDisplay(displayID: 20),
            MockDisplay(displayID: 30),
        ]

        let keys = WindowExclusionManager.filterMapKeys(from: displays)

        #expect(keys == Set<CGDirectDisplayID>([10, 20, 30]))
    }
}
