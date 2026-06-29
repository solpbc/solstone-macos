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
        #expect(pairURL.kind == .direct)
        #expect(pairURL.addressBytes == [0xC0, 0x00, 0x02, 0x2A])
        #expect(pairURL.candidates == [PairCandidate(address: "192.0.2.42", port: 0x1B9E)])
        #expect(pairURL.nonceBytes == [
            0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
        ])
        #expect(pairURL.caFingerprintBytes == [
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
        #expect(pairURL.caFingerprintKind == .certificateSHA256)
        #expect(pairURL.instanceID == nil)
        #expect(pairURL.totp == nil)
        #expect(pairURL.relayOrigin == nil)
    }

    @Test func wellKnownRelayReferenceVectorParses() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.wellKnownRelayBlob))

        #expect(pairURL.version == 0x03)
        #expect(pairURL.kind == .relay)
        #expect(pairURL.instanceID == "12345678-1234-5678-1234-567812345678")
        #expect(pairURL.totp == "123456")
        #expect(pairURL.nonceBytes == [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
        #expect(pairURL.caFingerprintKind == .spkiSHA256)
        #expect(pairURL.caFingerprintBytes == [
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
        #expect(pairURL.candidates == [])
        #expect(pairURL.relayOrigin == nil)
    }

    @Test func customRelayReferenceVectorParses() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.customRelayBlob))

        #expect(pairURL.kind == .relay)
        #expect(pairURL.instanceID == "12345678-1234-5678-1234-567812345678")
        #expect(pairURL.totp == "123456")
        #expect(pairURL.relayOrigin?.absoluteString == "https://relay.example")
    }

    @Test func multiAddressReferenceVectorParses() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.multiAddressBlob))

        #expect(pairURL.version == 0x05)
        #expect(pairURL.kind == .direct)
        #expect(pairURL.addressBytes == [0xC0, 0x00, 0x02, 0x0A])
        #expect(pairURL.candidates == [
            PairCandidate(address: "192.0.2.10", port: 7657),
            PairCandidate(address: "198.51.100.20", port: 7657),
        ])
        #expect(pairURL.nonceBytes == (0x00...0x0F).map(UInt8.init))
        #expect(pairURL.caFingerprintBytes == (0xA0...0xAF).map(UInt8.init))
        #expect(pairURL.caFingerprintKind == .certificateSHA256)
        #expect(pairURL.instanceID == nil)
        #expect(pairURL.totp == nil)
        #expect(pairURL.relayOrigin == nil)
    }

    @Test func multiAddressReferenceVectorReconstructsExactBlob() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.multiAddressBlob))

        #expect(Self.hex(Self.reconstructedMultiBytes(from: pairURL)) == Self.multiAddressHex)
    }

    @Test func alternateV04VectorParsesOneCandidate() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.alternateDirectBlob))

        #expect(pairURL.version == 0x04)
        #expect(pairURL.candidates == [PairCandidate(address: "192.0.2.10", port: 7657)])
    }

    @Test func rejectsWrongScheme() {
        expectThrows(.wrongScheme("http")) {
            _ = try PairURL.parse(URL(string: "http://go.solstone.app/p#\(Self.canonicalBlob)")!)
        }
    }

    @Test func rejectsWrongHost() {
        expectThrows(.wrongHost("example.com")) {
            _ = try PairURL.parse(URL(string: "https://example.com/p#\(Self.canonicalBlob)")!)
        }
    }

    @Test func rejectsWrongPath() {
        expectThrows(.wrongPath("/wrong")) {
            _ = try PairURL.parse(URL(string: "https://go.solstone.app/wrong#\(Self.canonicalBlob)")!)
        }
    }

    @Test func rejectsMissingFragment() {
        expectThrows(.missingFragment) {
            _ = try PairURL.parse(URL(string: "https://go.solstone.app/p")!)
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

    @Test func rejectsLegacyDirectFragment() {
        let legacyBytes: [UInt8] = [
            0x02, 0x01, 0xC0, 0x00, 0x02, 0x2A, 0x1B, 0x9E,
            0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
        ]

        expectThrows(.invalidVersion(0x02)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(legacyBytes)))
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

    @Test func rejectsRelayUnsupportedFingerprintTag() {
        var bytes = Self.relayBytes()
        bytes[36] = 0x02

        expectThrows(.unsupportedCAFingerprintTag(0x02)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsRelaySelectorLengthMismatch() {
        var bytes = Self.relayBytes()
        bytes[53] = 0x04

        expectThrows(.invalidLength(54)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsRelayInvalidOrigin() {
        let bytes = Self.relayBytes(selector: "ftp://relay.example")

        expectThrows(.invalidRelayOrigin) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsMultiAddressZeroCount() {
        var bytes = Self.multiAddressBytes
        bytes[2] = 0

        expectThrows(.invalidLength(bytes.count)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsMultiAddressTruncatedLength() {
        var bytes = Self.multiAddressBytes
        bytes.removeLast()

        expectThrows(.invalidLength(bytes.count)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsMultiAddressExtraByte() {
        var bytes = Self.multiAddressBytes
        bytes.append(0x00)

        expectThrows(.invalidLength(bytes.count)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsMultiAddressUnsupportedAddressType() {
        var bytes = Self.multiAddressBytes
        bytes[1] = 0x02

        expectThrows(.unsupportedAddrType(0x02)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    @Test func rejectsFutureVersion() {
        var bytes = Self.multiAddressBytes
        bytes[0] = 0x06

        expectThrows(.invalidVersion(0x06)) {
            _ = try PairURL.parse(Self.url(fragment: Self.encode(bytes)))
        }
    }

    private static let canonicalBlob = "0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"
    private static let alternateDirectBlob = "0G0W000218EYJ001081G81860W40J2GB1G6GW3X0M6HA7955MTKTHADANEPAVBNF"
    private static let multiAddressBlob = "0M0G47F9R00042P66DJ18001081G81860W40J2GB1G6GW3X0M6HA7955MTKTHADANEPAVBNF"
    private static let multiAddressHex = "0501021de9c000020ac6336414000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    private static let wellKnownRelayBlob = "0C938NKR28T5CY0J6HB7G4HMASW03RJ004HMASW9NF6YY0938NKRKAYDXW0XXBDYXZ5FXENY04HMASW9NF6YY00"
    private static let customRelayBlob = "0C938NKR28T5CY0J6HB7G4HMASW03RJ004HMASW9NF6YY0938NKRKAYDXW0XXBDYXZ5FXENY04HMASW9NF6YY5B8EHT70WST5WQQ4SBCC5WJWSBRC5PQ0V35"
    private static let canonicalBytes: [UInt8] = [
        0x04, 0x01, 0xC0, 0x00, 0x02, 0x2A, 0x1B, 0x9E,
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
    ]
    private static let multiAddressBytes: [UInt8] = [
        0x05, 0x01, 0x02, 0x1D, 0xE9,
        0xC0, 0x00, 0x02, 0x0A,
        0xC6, 0x33, 0x64, 0x14,
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF,
    ]

    private static func url(fragment: String) -> URL {
        URL(string: "https://go.solstone.app/p#\(fragment)")!
    }

    private static func relayBytes(selector: String = "") -> [UInt8] {
        let selectorBytes = Array(selector.utf8)
        return [
            0x03,
            0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
            0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
            0x01, 0xE2, 0x40,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            0x01,
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            UInt8(selectorBytes.count),
        ] + selectorBytes
    }

    private static func reconstructedMultiBytes(from pairURL: PairURL) -> [UInt8] {
        guard let first = pairURL.candidates.first else {
            return []
        }
        var bytes: [UInt8] = [
            pairURL.version,
            0x01,
            UInt8(pairURL.candidates.count),
            UInt8(first.port >> 8),
            UInt8(first.port & 0x00FF),
        ]
        for candidate in pairURL.candidates {
            bytes.append(contentsOf: candidate.address.split(separator: ".").map { UInt8($0)! })
        }
        bytes.append(contentsOf: pairURL.nonceBytes)
        bytes.append(contentsOf: pairURL.caFingerprintBytes)
        return bytes
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
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
