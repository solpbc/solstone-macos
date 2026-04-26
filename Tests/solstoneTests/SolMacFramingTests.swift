// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore

@Suite("SolMacFraming")
struct SolMacFramingTests {
    @Test func newlineInJSONStringIsEscaped() throws {
        let error = IPCError(code: "internal_error", message: "line one\nline two", hint: nil)
        let data = try IPCWire.encoder.encode(error)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\\n"))
        #expect(!data.contains(0x0A))
    }

    @Test func malformedJSONThrows() {
        let data = Data(#"{"kind":"ping","value":"oops""#.utf8)
        #expect(throws: (any Error).self) {
            _ = try IPCWire.decoder.decode(IPCCommand.self, from: data)
        }
    }
}
