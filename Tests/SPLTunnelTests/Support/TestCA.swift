// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security
@testable import SPLTunnel

enum TestCA {
    struct Bundle: Sendable {
        let caCertificatePEM: String
        let serverCertificatePEM: String
        let serverPrivateKeyPEM: String
        let clientCertificatePEM: String
        let clientPrivateKeyPEM: String
        let pairing: StoredPairing
    }

    static func make(localEndpoints: [LocalEndpoint] = []) throws -> Bundle {
        let caKey = P256.Signing.PrivateKey()
        let serverKey = P256.Signing.PrivateKey()
        let clientKey = P256.Signing.PrivateKey()

        let caDER = try certificate(
            subject: "solstone-test-ca",
            issuer: "solstone-test-ca",
            subjectPublicKey: caKey.publicKey,
            issuerPrivateKey: caKey,
            isCA: true,
            extendedKeyUsage: []
        )
        let serverDER = try certificate(
            subject: "localhost",
            issuer: "solstone-test-ca",
            subjectPublicKey: serverKey.publicKey,
            issuerPrivateKey: caKey,
            isCA: false,
            extendedKeyUsage: [CertBuilder.oidServerAuth],
            subjectAlternativeNames: true
        )
        let clientDER = try certificate(
            subject: "solstone-test-client",
            issuer: "solstone-test-ca",
            subjectPublicKey: clientKey.publicKey,
            issuerPrivateKey: caKey,
            isCA: false,
            extendedKeyUsage: [CertBuilder.oidClientAuth]
        )

        let caPEM = CryptoCSR.pemEncode(caDER, label: "CERTIFICATE")
        let serverPEM = CryptoCSR.pemEncode(serverDER, label: "CERTIFICATE")
        let clientPEM = CryptoCSR.pemEncode(clientDER, label: "CERTIFICATE")
        let clientKeyPEM = CryptoCSR.pemEncode(CryptoCSR.exportPKCS8(clientKey), label: "PRIVATE KEY")

        let pairing = StoredPairing(
            instanceID: "test-instance",
            homeLabel: "test home",
            relayEndpoint: "ws://127.0.0.1:1",
            fingerprint: "",
            clientCertPEM: clientPEM,
            clientKeyPEM: clientKeyPEM,
            caChainPEM: caPEM,
            relayEnrollment: .enrolled(deviceToken: "test-token", expiresAt: nil),
            localEndpoints: localEndpoints,
            pairedAt: Date(timeIntervalSince1970: 0)
        )

        return Bundle(
            caCertificatePEM: caPEM,
            serverCertificatePEM: serverPEM,
            serverPrivateKeyPEM: CryptoCSR.pemEncode(CryptoCSR.exportPKCS8(serverKey), label: "PRIVATE KEY"),
            clientCertificatePEM: clientPEM,
            clientPrivateKeyPEM: clientKeyPEM,
            pairing: pairing
        )
    }

    static func secIdentity(certificatePEM: String, privateKeyPEM: String) throws -> sec_identity_t {
        let pairing = StoredPairing(
            instanceID: "identity",
            homeLabel: "identity",
            relayEndpoint: "ws://127.0.0.1:1",
            fingerprint: "",
            clientCertPEM: certificatePEM,
            clientKeyPEM: privateKeyPEM,
            caChainPEM: certificatePEM,
            relayEnrollment: .enrolled(deviceToken: "token", expiresAt: nil),
            pairedAt: Date(timeIntervalSince1970: 0)
        )
        return try InnerTLS.makeIdentity(pairing: pairing)
    }

    static func fingerprint(certificatePEM: String) throws -> String {
        guard let certificate = try CertChain.certificates(fromPEM: certificatePEM).first else {
            throw CertChainError.emptyChain
        }
        return CertChain.sha256Fingerprint(of: certificate)
    }

    private static func certificate(
        subject: String,
        issuer: String,
        subjectPublicKey: P256.Signing.PublicKey,
        issuerPrivateKey: P256.Signing.PrivateKey,
        isCA: Bool,
        extendedKeyUsage: [[UInt64]],
        subjectAlternativeNames: Bool = false
    ) throws -> [UInt8] {
        try CertBuilder.certificate(
            subject: subject,
            issuer: issuer,
            subjectPublicKey: subjectPublicKey,
            issuerPrivateKey: issuerPrivateKey,
            isCA: isCA,
            extendedKeyUsage: extendedKeyUsage,
            subjectAlternativeNames: subjectAlternativeNames
        )
    }
}
