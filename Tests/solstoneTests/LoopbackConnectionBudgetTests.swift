// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

// The journal door admits eight concurrent streams per carrier, and the loopback
// tunnel maps one stream to each persistent TCP connection and holds it for that
// connection's whole life. Every URLSession pool aimed at the tunnel therefore
// has to fit inside eight together.
//
// None of them declared a limit before this suite existed: each took the
// platform default of six per host, `URLSession.shared` added a pool this
// process cannot configure, and three clients minted a fresh pool on every
// instantiation. Overrunning the budget does not degrade — the door refuses the
// next stream and the request reaches the owner as a bare connection loss.
@Suite("Loopback connection budget")
struct LoopbackConnectionBudgetTests {
    @Test func everyLoopbackPoolFitsInsideTheDoorStreamBudget() {
        let declared = BoundedLoopbackClient.loopbackConnectionsPerHost
            + BoundedLoopbackClient.uploadConnectionsPerHost
        #expect(declared <= BoundedLoopbackClient.tunnelStreamBudget)
    }

    @Test func theBoundedLoopbackPoolDeclaresItsConnectionLimit() {
        let config = BoundedLoopbackClient.makeSessionConfiguration()
        #expect(config.httpMaximumConnectionsPerHost == BoundedLoopbackClient.loopbackConnectionsPerHost)
    }

    @Test func theIngestPoolDeclaresItsConnectionLimit() {
        let config = UploadClient.defaultSessionConfiguration()
        #expect(config.httpMaximumConnectionsPerHost == BoundedLoopbackClient.uploadConnectionsPerHost)
    }

    @Test func loopbackControlTrafficSharesOnePool() {
        // `makeSession()` stays available for tests that need an isolated pool;
        // what must not come back is a caller taking it as a default argument.
        #expect(BoundedLoopbackClient.sharedSession === BoundedLoopbackClient.sharedSession)
        #expect(BoundedLoopbackClient.makeSession() !== BoundedLoopbackClient.sharedSession)
    }
}
