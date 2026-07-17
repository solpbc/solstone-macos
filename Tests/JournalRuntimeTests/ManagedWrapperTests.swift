// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalRuntime

@Suite("ManagedWrapper")
struct ManagedWrapperTests {
    @Test func exactRoundTripRecognitionRequiresCanonicalBytes() {
        let target = "/tmp/runtime dir with ' quote/0.6.4_py20260510_aaaaaaaaaaaaaaaa/bin/sol"
        let canonical = ManagedWrapper.canonicalScriptData(forTarget: target)

        #expect(ManagedWrapper.canonicalTarget(fromExactScriptData: canonical) == target)

        let missingTrailingNewline = Data(ManagedWrapper.script(forTarget: target).utf8)
        #expect(ManagedWrapper.canonicalTarget(fromExactScriptData: missingTrailingNewline) == nil)

        let noncanonical = Data("""
        #!/bin/sh
        \(ManagedWrapper.appOwnedChildMarker)
        echo before
        exec \(ManagedWrapper.shellSingleQuoted(target)) "$@"
        """.utf8)
        #expect(ManagedWrapper.canonicalTarget(fromExactScriptData: noncanonical) == nil)
    }

    @Test func componentSafeContainmentRejectsSiblingPrefix() {
        #expect(ManagedWrapper.isUnderRoot("/tmp/runtime/bin/sol", root: "/tmp/runtime"))
        #expect(ManagedWrapper.isUnderRoot("/tmp/runtime/child/../bin/sol", root: "/tmp/runtime"))
        #expect(!ManagedWrapper.isUnderRoot("/tmp/runtime-x/bin/sol", root: "/tmp/runtime"))
    }
}
