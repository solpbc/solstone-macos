// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SPLTunnel

@Suite("PairURL")
struct PairURLTests {
    private let pin = Data(0..<32)
    private let expectedPinHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

    @Test func parsesValidSPLURL() throws {
        let parsed = try PairURL(splURL: makeSPLURL(host: "192.168.1.20"))
        #expect(parsed.lanURL.absoluteString == "https://192.168.1.20/pair?token=nonce123")
        #expect(parsed.nonce == "nonce123")
        #expect(parsed.caFingerprintHex == expectedPinHex)
    }

    @Test func acceptsBase64URLWithAndWithoutPadding() throws {
        let padded = try PairURL(splURL: makeSPLURL(host: "192.168.1.20", padded: true))
        let unpadded = try PairURL(splURL: makeSPLURL(host: "192.168.1.20", padded: false))
        #expect(padded == unpadded)
    }

    @Test func rejectsWrongScheme() {
        expectThrows(.wrongScheme) {
            _ = try PairURL(splURL: URL(string: "https://pair?u=x&pin=y")!)
        }
    }

    @Test func rejectsWrongPairHostOrPath() {
        expectThrows(.wrongHost) {
            _ = try PairURL(splURL: URL(string: "spl://not-pair?u=x&pin=y")!)
        }
    }

    @Test func rejectsMissingU() {
        expectThrows(.missingU) {
            _ = try PairURL(splURL: URL(string: "spl://pair?pin=\(b64url(pin))")!)
        }
    }

    @Test func rejectsMissingPin() {
        let encoded = b64url(Data("https://192.168.1.20/pair?token=x".utf8))
        expectThrows(.missingPin) {
            _ = try PairURL(splURL: URL(string: "spl://pair?u=\(encoded)")!)
        }
    }

    @Test func rejectsMalformedBase64URL() {
        expectThrows(.malformedLanURL) {
            _ = try PairURL(splURL: URL(string: "spl://pair?u=***&pin=\(b64url(pin))")!)
        }
    }

    @Test func rejectsDecodedPairURLWithoutToken() {
        expectThrows(.missingToken) {
            _ = try PairURL(splURL: makeSPLURL(lanURL: "https://192.168.1.20/pair"))
        }
    }

    @Test func rejectsMalformedDecodedPairURL() {
        expectThrows(.malformedLanURL) {
            _ = try PairURL(splURL: makeSPLURL(lanURL: "not a url"))
        }
    }

    @Test func rejectsNonHTTPSLanURL() {
        expectThrows(.nonHTTPSLanURL) {
            _ = try PairURL(splURL: makeSPLURL(lanURL: "http://192.168.1.20/pair?token=nonce123"))
        }
    }

    @Test func rejectsInvalidPinLength() {
        expectThrows(.invalidPinLength) {
            _ = try PairURL(splURL: makeSPLURL(host: "192.168.1.20", pin: Data([0x01])))
        }
    }

    @Test func allowsUploadClientFixtureMatrix() throws {
        let accepted = [
            "nas.local",
            "NAS.LOCAL.",
            "myserver",
            "NAS",
            "10.0.0.5",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.20",
            "169.254.10.2",
            "100.64.0.1",
            "100.121.250.106",
            "100.127.255.255",
            "fe80::1",
            "FE80::ABCD",
            "fc00::1",
            "fd12:3456::1",
        ]
        for host in accepted {
            _ = try PairURL(splURL: makeSPLURL(host: host))
        }

        let rejected = [
            "100.63.255.255",
            "100.128.0.0",
            "localhost",
            "127.0.0.1",
            "::1",
            "8.8.8.8",
            "172.15.0.1",
            "172.32.0.1",
            "api.solstone.app",
            "example.com",
            "192.168.1",
            "999.1.1.1",
        ]
        for host in rejected {
            expectThrows(.nonLocalHost) {
                _ = try PairURL(splURL: makeSPLURL(host: host))
            }
        }
    }

    private func makeSPLURL(host: String, padded: Bool = false, pin: Data? = nil) -> URL {
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        return makeSPLURL(lanURL: "https://\(renderedHost)/pair?token=nonce123", padded: padded, pin: pin)
    }

    private func makeSPLURL(lanURL: String, padded: Bool = false, pin: Data? = nil) -> URL {
        let u = b64url(Data(lanURL.utf8), padded: padded)
        let pin = b64url(pin ?? self.pin, padded: padded)
        return URL(string: "spl://pair?u=\(u)&pin=\(pin)")!
    }

    private func b64url(_ data: Data, padded: Bool = false) -> String {
        var encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        if !padded {
            encoded.removeAll { $0 == "=" }
        }
        return encoded
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
