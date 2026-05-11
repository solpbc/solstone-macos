// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SPLTunnel

// Canonical v1 Universal Link shape:
// https://link.solpbc.org/p#h=https%3A%2F%2F192.168.1.20%2Fpair%3Ftoken%3Dnonce123&t=nonce123&f=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f&l=living%20room%20mac&v=1

@Suite("PairURL")
struct PairURLTests {
    private let fingerprint = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    @Test func parsesValidUniversalLink() throws {
        let parsed = try PairURL.parse(makePairURL())
        #expect(parsed.homeURL.absoluteString == "https://192.168.1.20/pair?token=nonce123")
        #expect(parsed.token == "nonce123")
        #expect(parsed.caFingerprintHex == fingerprint)
        #expect(parsed.label == "living room mac")
        #expect(parsed.version == 1)
    }

    @Test func canonicalizesFingerprintAndDecodesPercentEncodedLabel() throws {
        let parsed = try PairURL.parse(makePairURL(fingerprint: fingerprint.uppercased(), label: "living room mac"))
        #expect(parsed.caFingerprintHex == fingerprint)
        #expect(parsed.label == "living room mac")
    }

    @Test func initStringParsesValidUniversalLink() throws {
        let parsed = try PairURL(string: makePairURL().absoluteString)
        #expect(parsed.token == "nonce123")
    }

    @Test func rejectsWrongScheme() {
        expectThrows(.wrongScheme) {
            _ = try PairURL.parse(URL(string: "http://link.solpbc.org/p#\(fragment())")!)
        }
    }

    @Test func rejectsWrongHost() {
        expectThrows(.wrongHost) {
            _ = try PairURL.parse(URL(string: "https://example.com/p#\(fragment())")!)
        }
    }

    @Test func rejectsWrongPath() {
        expectThrows(.wrongPath) {
            _ = try PairURL.parse(URL(string: "https://link.solpbc.org/not-p#\(fragment())")!)
        }
    }

    @Test func rejectsMissingFragment() {
        expectThrows(.missingFragment) {
            _ = try PairURL.parse(URL(string: "https://link.solpbc.org/p")!)
        }
    }

    @Test func rejectsMissingHomeField() {
        expectThrows(.missingField("h")) {
            _ = try PairURL.parse(makePairURL(omitting: "h"))
        }
    }

    @Test func rejectsMissingTokenField() {
        expectThrows(.missingField("t")) {
            _ = try PairURL.parse(makePairURL(omitting: "t"))
        }
    }

    @Test func rejectsMissingFingerprintField() {
        expectThrows(.missingField("f")) {
            _ = try PairURL.parse(makePairURL(omitting: "f"))
        }
    }

    @Test func rejectsMissingLabelField() {
        expectThrows(.missingField("l")) {
            _ = try PairURL.parse(makePairURL(omitting: "l"))
        }
    }

    @Test func rejectsInvalidVersion() {
        expectThrows(.invalidVersion) {
            _ = try PairURL.parse(makePairURL(version: "2"))
        }
    }

    @Test func rejectsMalformedHomeURL() {
        expectThrows(.malformedHomeURL) {
            _ = try PairURL.parse(makePairURL(homeURL: "not a url"))
        }
    }

    @Test func rejectsNonHTTPSHomeURL() {
        expectThrows(.nonHTTPSHomeURL) {
            _ = try PairURL.parse(makePairURL(homeURL: "http://192.168.1.20/pair?token=nonce123"))
        }
    }

    @Test func rejectsInvalidFingerprintLength() {
        expectThrows(.invalidFingerprint) {
            _ = try PairURL.parse(makePairURL(fingerprint: "abc"))
        }
    }

    @Test func rejectsInvalidFingerprintCharacters() {
        expectThrows(.invalidFingerprint) {
            _ = try PairURL.parse(makePairURL(fingerprint: String(repeating: "g", count: 64)))
        }
    }

    @Test func rejectsEmptyToken() {
        expectThrows(.emptyToken) {
            _ = try PairURL.parse(makePairURL(token: ""))
        }
    }

    @Test func rejectsEmptyLabel() {
        expectThrows(.emptyLabel) {
            _ = try PairURL.parse(makePairURL(label: ""))
        }
    }

    private func makePairURL(
        homeURL: String = "https://192.168.1.20/pair?token=nonce123",
        token: String = "nonce123",
        fingerprint: String? = nil,
        label: String = "living room mac",
        version: String = "1",
        omitting omittedField: String? = nil
    ) -> URL {
        let values = [
            "h": encode(homeURL),
            "t": encode(token),
            "f": encode(fingerprint ?? self.fingerprint),
            "l": encode(label),
            "v": encode(version),
        ]
        let fragment = ["h", "t", "f", "l", "v"]
            .compactMap { key -> String? in
                guard key != omittedField, let value = values[key] else { return nil }
                return "\(key)=\(value)"
            }
            .joined(separator: "&")
        return URL(string: "https://link.solpbc.org/p#\(fragment)")!
    }

    private func fragment() -> String {
        makePairURL().fragment!
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
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
