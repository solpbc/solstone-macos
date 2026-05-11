// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Testing
@testable import SPLTunnel

@Suite("DER")
struct DERTests {
    @Test func cryptoImportWorks() {
        let digest = SHA256.hash(data: Data())
        #expect(Array(digest).count == 32)
    }

    @Test func sequenceEmpty() {
        #expect(DER.sequence([]) == [0x30, 0x00])
    }

    @Test func integerZero() {
        #expect(DER.integer([0]) == [0x02, 0x01, 0x00])
    }

    @Test func integerAddsSignByte() {
        #expect(DER.integer([0x80]) == [0x02, 0x02, 0x00, 0x80])
    }

    @Test func integerStripsRedundantLeadingZeros() {
        #expect(DER.integer([0x00, 0x00, 0x01]) == [0x02, 0x01, 0x01])
    }

    @Test func bitStringAddsUnusedBitsByte() {
        #expect(DER.bitString([0x04, 0x01, 0x02]) == [0x03, 0x04, 0x00, 0x04, 0x01, 0x02])
    }

    @Test func objectIdentifierEncodesP256EcPublicKeyOID() {
        #expect(DER.objectIdentifier([1, 2, 840, 10045, 2, 1]) == [
            0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01
        ])
    }

    @Test func contextSpecificEmpty() {
        #expect(DER.contextSpecific(tag: 0, value: []) == [0xa0, 0x00])
    }

    @Test func lengthForms() {
        #expect(DER.length(127) == [0x7f])
        #expect(DER.length(128) == [0x81, 0x80])
        #expect(DER.length(256) == [0x82, 0x01, 0x00])
    }

    @Test func primitiveTags() {
        #expect(DER.set([]) == [0x31, 0x00])
        #expect(DER.octetString([0x01]) == [0x04, 0x01, 0x01])
        #expect(DER.utf8String("sol") == [0x0c, 0x03, 0x73, 0x6f, 0x6c])
        #expect(DER.null() == [0x05, 0x00])
    }
}
