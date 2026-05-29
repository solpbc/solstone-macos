// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SPLTunnel

@Suite("PairURL")
struct PairURLTests {
    @Test func canonicalReferenceVectorParses() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.canonicalBlob))

        #expect(pairURL.version == 0x04)
        #expect(pairURL.addressBytes == [0xC0, 0x00, 0x02, 0x2A])
        #expect(pairURL.addressString == "192.0.2.42")
        #expect(pairURL.port == 0x1B9E)
        #expect(pairURL.nonceBytes == [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        #expect(pairURL.caFingerprintBytes == [
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
    }

    @Test func rejectsWrongScheme() {
        expectThrows(.wrongScheme("http")) {
            _ = try PairURL.parse(URL(string: "http://link.solpbc.org/p#\(Self.canonicalBlob)")!)
        }
    }

    @Test func rejectsWrongHost() {
        expectThrows(.wrongHost("example.com")) {
            _ = try PairURL.parse(URL(string: "https://example.com/p#\(Self.canonicalBlob)")!)
        }
    }

    @Test func rejectsWrongPath() {
        expectThrows(.wrongPath("/wrong")) {
            _ = try PairURL.parse(URL(string: "https://link.solpbc.org/wrong#\(Self.canonicalBlob)")!)
        }
    }

    @Test func rejectsMissingFragment() {
        expectThrows(.missingFragment) {
            _ = try PairURL.parse(URL(string: "https://link.solpbc.org/p")!)
        }
    }

    @Test func rejectsInvalidBase32() {
        expectThrows(.invalidBase32(.outOfAlphabet("?"))) {
            _ = try PairURL.parse(Self.url(fragment: "?"))
        }
    }

    @Test func rejectsInvalidVersion() {
        var bytes = Self.canonicalBytes
        bytes[0] = 0x01

        expectThrows(.invalidVersion(0x01)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsLegacyV2DirectBlob() {
        expectThrows(.invalidVersion(0x02)) {
            _ = try PairURL.parse(Self.url(fragment: "080W000258DSX8DJRFAEBXG733FAVFQFSBZBNFG14D2PF2DBSQQG"))
        }
    }

    @Test func rejectsIPv4AddressTypeWithLength39() {
        var bytes = Self.canonicalBytes
        bytes.removeLast()

        expectThrows(.invalidLength(39)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsIPv4AddressTypeWithLength41() {
        var bytes = Self.canonicalBytes
        bytes.append(0x00)

        expectThrows(.invalidLength(41)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsReservedIPv6AddressType() {
        var bytes = Self.canonicalBytes
        bytes[1] = 0x02

        expectThrows(.unsupportedAddrType(0x02)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsUnknownAddressType() {
        var bytes = Self.canonicalBytes
        bytes[1] = 0x03

        expectThrows(.unsupportedAddrType(0x03)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    private static let canonicalBlob = "0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"
    private static let canonicalBytes: [UInt8] = [
        0x04, 0x01, 0xC0, 0x00, 0x02, 0x2A, 0x1B, 0x9E,
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
    ]

    private static func url(fragment: String) -> URL {
        URL(string: "https://link.solpbc.org/p#\(fragment)")!
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var accumulator: UInt64 = 0
        var bitCount = 0
        var output = ""

        for byte in bytes {
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((accumulator >> UInt64(bitCount)) & 0x1f)
                output.append(alphabet[index])
                accumulator &= (1 << UInt64(bitCount)) - 1
            }
        }

        if bitCount > 0 {
            let index = Int((accumulator << UInt64(5 - bitCount)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }

    private func expectThrows(_ expected: PairURLError, _ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected \(expected)")
        } catch let error as PairURLError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error)")
        }
    }
}
