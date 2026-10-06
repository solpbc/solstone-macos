// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

@Suite("Carried pairing certificate validation")
struct CarriedPairingCertificateValidationTests {
    @Test func rekeyPairingRequiresCertificateKeyFingerprintInstanceAndCA() throws {
        let certificates = try CertChain.certificates(fromPEM: leafCertificatePEM)
        let leaf = try #require(certificates.first)
        let caCertificates = try CertChain.certificates(fromPEM: caCertificatePEM)
        let ca = try #require(caCertificates.first)
        let instanceID = try CertChain.jidFromSPKI(CertChain.canonicalP256SubjectPublicKeyInfoDER(certificate: ca))
        let fingerprint = "sha256:\(CertChain.sha256Fingerprint(of: leaf))"
        let validReply = pairingReply(
            certificate: leafCertificatePEM,
            caChain: [caCertificatePEM],
            instanceID: instanceID,
            fingerprint: fingerprint
        )

        let pairing = try URLSessionCarriedPairingControlClient.pairing(
            from: validReply,
            privateKeyPEM: leafPrivateKeyPEM
        )
        #expect(pairing.fingerprint == fingerprint)
        #expect(pairing.instanceID == instanceID)

        let unrelatedKey = try CryptoCSR.generate(deviceLabel: "test fixture").privateKeyPEM
        #expect(throws: CarriedPairingControlError.invalidResponse) {
            try URLSessionCarriedPairingControlClient.pairing(from: validReply, privateKeyPEM: unrelatedKey)
        }

        let wrongFingerprint = pairingReply(
            certificate: leafCertificatePEM,
            caChain: [caCertificatePEM],
            instanceID: instanceID,
            fingerprint: "sha256:\(String(repeating: "0", count: 64))"
        )
        #expect(throws: CarriedPairingControlError.invalidResponse) {
            try URLSessionCarriedPairingControlClient.pairing(from: wrongFingerprint, privateKeyPEM: leafPrivateKeyPEM)
        }

        let wrongInstance = pairingReply(
            certificate: leafCertificatePEM,
            caChain: [caCertificatePEM],
            instanceID: "another-journal",
            fingerprint: fingerprint
        )
        #expect(throws: CarriedPairingControlError.invalidResponse) {
            try URLSessionCarriedPairingControlClient.pairing(from: wrongInstance, privateKeyPEM: leafPrivateKeyPEM)
        }

        let unrelatedCA = try #require(try CertChain.certificates(fromPEM: testCACertPEM).first)
        let unrelatedInstanceID = try CertChain.jidFromSPKI(
            CertChain.canonicalP256SubjectPublicKeyInfoDER(certificate: unrelatedCA)
        )
        let wrongCA = pairingReply(
            certificate: leafCertificatePEM,
            caChain: [testCACertPEM],
            instanceID: unrelatedInstanceID,
            fingerprint: fingerprint
        )
        #expect(throws: CarriedPairingControlError.invalidResponse) {
            try URLSessionCarriedPairingControlClient.pairing(from: wrongCA, privateKeyPEM: leafPrivateKeyPEM)
        }
    }

    private func pairingReply(
        certificate: String,
        caChain: [String],
        instanceID: String,
        fingerprint: String
    ) -> CarriedPairingPairingReply {
        CarriedPairingPairingReply(
            clientCert: certificate,
            caChain: caChain,
            instanceID: instanceID,
            homeLabel: "test-home",
            fingerprint: fingerprint,
            localEndpoints: nil,
            relayAccess: nil
        )
    }

    private let caCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIBqTCCAU+gAwIBAgIUaxnJ5SncskdgPRWxSc+XR8s0nE4wCgYIKoZIzj0EAwIw
    IjEgMB4GA1UEAwwXY2FycmllZC1wYWlyaW5nLXRlc3QtY2EwHhcNMjYxMDA2MTky
    NDExWhcNMzYxMDAzMTkyNDExWjAiMSAwHgYDVQQDDBdjYXJyaWVkLXBhaXJpbmct
    dGVzdC1jYTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBxLy4LAiZen+z1nUrid
    AS5q6ubJmvBsmtQya4uMrkjMIggL8vFtphX/iEZt+bqGog+GELSZGgdmmO2NKx8A
    JG+jYzBhMB0GA1UdDgQWBBSna0gxr9ZbpVosFrdOKiTJLQYN8TAfBgNVHSMEGDAW
    gBSna0gxr9ZbpVosFrdOKiTJLQYN8TAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB
    /wQEAwIBBjAKBggqhkjOPQQDAgNIADBFAiAWvWYvoUwMhPhtYmUMG+dbJGYmpKbu
    +/fheEoLyr5srAIhAMaONiBbEzkv/5YmA3ggDF2ivX9REHchsl67NbbHPOK4
    -----END CERTIFICATE-----
    """

    private let leafCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIBvzCCAWWgAwIBAgIUe+zPj1MEJYHqVJ/9cWht5h9m9DkwCgYIKoZIzj0EAwIw
    IjEgMB4GA1UEAwwXY2FycmllZC1wYWlyaW5nLXRlc3QtY2EwHhcNMjYxMDA2MTky
    NDExWhcNMzYxMDAzMTkyNDExWjAmMSQwIgYDVQQDDBtjYXJyaWVkLXBhaXJpbmct
    dGVzdC1jbGllbnQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQ7dLmsXrn2lTwN
    FXL0oUgyKw4dvcc6ZMebC5gnZcSSgiJanHcoiW4McUVkYp2keURxWxLTP+hIgb3b
    j18Eo7F0o3UwczAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUE
    DDAKBggrBgEFBQcDAjAdBgNVHQ4EFgQUhjsgxxXIncyi8lkjRNSJSTY36IEwHwYD
    VR0jBBgwFoAUp2tIMa/WW6VaLBa3TiokyS0GDfEwCgYIKoZIzj0EAwIDSAAwRQIh
    AIKIsHuQBOUflCKtDAF1TvX+KKYj5U9Ab3zd2XnT7wxJAiAYVrmuqr3d2EeGUc/i
    /Xb4D1BFGKX+N2cxRVCmJbMTnQ==
    -----END CERTIFICATE-----
    """

    private let leafPrivateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgBW8BDhcyjNXEboRW
    lpBkOvqFkpReiKiJYVZ4CE3ar8+hRANCAAQ7dLmsXrn2lTwNFXL0oUgyKw4dvcc6
    ZMebC5gnZcSSgiJanHcoiW4McUVkYp2keURxWxLTP+hIgb3bj18Eo7F0
    -----END PRIVATE KEY-----
    """
}
