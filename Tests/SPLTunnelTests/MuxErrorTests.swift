// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SPLTunnel

@Suite("MuxError")
struct MuxErrorTests {
    @Test("flowControlError is public and equatable")
    func flowControlErrorIsPublicAndEquatable() {
        #expect(MuxError.flowControlError == MuxError.flowControlError)
        #expect(MuxError.flowControlError != MuxError.protocolError)
    }
}
