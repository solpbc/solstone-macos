// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Testing
@testable import SPLTunnel

@Suite("PinningDelegate")
struct PinningDelegateTests {
    @Test func pinMatchesAcceptsSha256Prefix() {
        let der = Self.fixtureDER
        let expected = Array(SHA256.hash(data: der).prefix(16))

        #expect(PinningDelegate.pinMatches(certificateDER: der, expectedFingerprintBytes: expected))
    }

    @Test func pinMatchesRejectsMutatedExpectedFingerprint() {
        let der = Self.fixtureDER
        var expected = Array(SHA256.hash(data: der).prefix(16))
        expected[0] ^= 0xff

        #expect(!PinningDelegate.pinMatches(certificateDER: der, expectedFingerprintBytes: expected))
    }

    @Test func pinMatchesRejectsZeroLengthExpectedFingerprint() {
        #expect(!PinningDelegate.pinMatches(certificateDER: Self.fixtureDER, expectedFingerprintBytes: []))
    }

    @Test func pinMatchesRejectsWrongLengthExpectedFingerprint() {
        let der = Self.fixtureDER
        let expected = Array(SHA256.hash(data: der).prefix(15))

        #expect(!PinningDelegate.pinMatches(certificateDER: der, expectedFingerprintBytes: expected))
    }

    private static let fixtureDER = Data([
        0x30, 0x82, 0x01, 0x22, 0x30, 0x81, 0xCA, 0xA0,
        0x03, 0x02, 0x01, 0x02, 0x02, 0x08, 0x12, 0x34,
        0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x30, 0x0A,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04,
        0x03, 0x02, 0x30, 0x15, 0x31, 0x13, 0x30, 0x11,
        0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, 0x0A, 0x73,
        0x6F, 0x6C, 0x73, 0x74, 0x6F, 0x6E, 0x65, 0x2D,
        0x74, 0x30, 0x1E, 0x17, 0x0D, 0x32, 0x36, 0x30,
        0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30,
        0x30, 0x5A, 0x17, 0x0D, 0x32, 0x37, 0x30, 0x31,
        0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
        0x5A
    ])
}
