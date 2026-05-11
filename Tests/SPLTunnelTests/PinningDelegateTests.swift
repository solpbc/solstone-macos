// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Security
import Testing
@testable import SPLTunnel

@Suite("PinningDelegate")
struct PinningDelegateTests {
    @Test func matchesLeafFingerprint() throws {
        let certificate = try #require(try CertChain.certificates(fromPEM: TestCertificates.cert1).first)
        let trust = try makeTrust(certificate: certificate)
        let fingerprint = CertChain.sha256Fingerprint(of: certificate)

        #expect(PinningDelegate.fingerprintMatchesPin(serverTrust: trust, expected: fingerprint))
    }

    @Test func rejectsMismatchedLeafFingerprint() throws {
        let certificate = try #require(try CertChain.certificates(fromPEM: TestCertificates.cert1).first)
        let trust = try makeTrust(certificate: certificate)
        let other = try #require(try CertChain.certificates(fromPEM: TestCertificates.cert2).first)

        #expect(!PinningDelegate.fingerprintMatchesPin(
            serverTrust: trust,
            expected: CertChain.sha256Fingerprint(of: other)
        ))
    }

    @Test func acceptsSha256Prefix() throws {
        let certificate = try #require(try CertChain.certificates(fromPEM: TestCertificates.cert1).first)
        let trust = try makeTrust(certificate: certificate)
        let fingerprint = CertChain.sha256Fingerprint(of: certificate)

        #expect(PinningDelegate.fingerprintMatchesPin(serverTrust: trust, expected: "sha256:\(fingerprint)"))
    }

    private func makeTrust(certificate: SecCertificate) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }
}
