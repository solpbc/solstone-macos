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
            extendedKeyUsage: [oidServerAuth],
            subjectAlternativeNames: true
        )
        let clientDER = try certificate(
            subject: "solstone-test-client",
            issuer: "solstone-test-ca",
            subjectPublicKey: clientKey.publicKey,
            issuerPrivateKey: caKey,
            isCA: false,
            extendedKeyUsage: [oidClientAuth]
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
            deviceToken: "test-token",
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
            deviceToken: "token",
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

    private static let oidCommonName: [UInt64] = [2, 5, 4, 3]
    private static let oidEcPublicKey: [UInt64] = [1, 2, 840, 10045, 2, 1]
    private static let oidPrime256v1: [UInt64] = [1, 2, 840, 10045, 3, 1, 7]
    private static let oidEcdsaWithSHA256: [UInt64] = [1, 2, 840, 10045, 4, 3, 2]
    private static let oidBasicConstraints: [UInt64] = [2, 5, 29, 19]
    private static let oidKeyUsage: [UInt64] = [2, 5, 29, 15]
    private static let oidExtendedKeyUsage: [UInt64] = [2, 5, 29, 37]
    private static let oidSubjectAlternativeName: [UInt64] = [2, 5, 29, 17]
    private static let oidServerAuth: [UInt64] = [1, 3, 6, 1, 5, 5, 7, 3, 1]
    private static let oidClientAuth: [UInt64] = [1, 3, 6, 1, 5, 5, 7, 3, 2]

    private static func certificate(
        subject: String,
        issuer: String,
        subjectPublicKey: P256.Signing.PublicKey,
        issuerPrivateKey: P256.Signing.PrivateKey,
        isCA: Bool,
        extendedKeyUsage: [[UInt64]],
        subjectAlternativeNames: Bool = false
    ) throws -> [UInt8] {
        let validity = DER.sequence([
            utcTime(Date(timeIntervalSinceNow: -3600)),
            utcTime(Date(timeIntervalSinceNow: 86400)),
        ])
        var extensions = [
            certificateExtension(oid: oidBasicConstraints, critical: true, value: basicConstraints(isCA: isCA)),
            certificateExtension(oid: oidKeyUsage, critical: true, value: keyUsage(isCA: isCA)),
        ]
        if !extendedKeyUsage.isEmpty {
            extensions.append(certificateExtension(
                oid: oidExtendedKeyUsage,
                critical: false,
                value: DER.sequence(extendedKeyUsage.map(DER.objectIdentifier))
            ))
        }
        if subjectAlternativeNames {
            extensions.append(certificateExtension(oid: oidSubjectAlternativeName, critical: false, value: san()))
        }

        let tbs = DER.sequence([
            DER.contextSpecific(tag: 0, value: DER.integer([0x02])),
            DER.integer(serialNumber()),
            signatureAlgorithm(),
            name(issuer),
            validity,
            name(subject),
            subjectPublicKeyInfo(subjectPublicKey),
            DER.contextSpecific(tag: 3, value: DER.sequence(extensions)),
        ])
        let signature = try issuerPrivateKey.signature(for: Data(tbs))
        return DER.sequence([
            tbs,
            signatureAlgorithm(),
            DER.bitString(Array(signature.derRepresentation)),
        ])
    }

    private static func name(_ commonName: String) -> [UInt8] {
        DER.sequence([
            DER.set([
                DER.sequence([
                    DER.objectIdentifier(oidCommonName),
                    DER.utf8String(commonName),
                ])
            ])
        ])
    }

    private static func subjectPublicKeyInfo(_ publicKey: P256.Signing.PublicKey) -> [UInt8] {
        DER.sequence([
            DER.sequence([
                DER.objectIdentifier(oidEcPublicKey),
                DER.objectIdentifier(oidPrime256v1),
            ]),
            DER.bitString(Array(publicKey.x963Representation)),
        ])
    }

    private static func signatureAlgorithm() -> [UInt8] {
        DER.sequence([DER.objectIdentifier(oidEcdsaWithSHA256)])
    }

    private static func certificateExtension(oid: [UInt64], critical: Bool, value: [UInt8]) -> [UInt8] {
        var elements = [DER.objectIdentifier(oid)]
        if critical {
            elements.append(boolean(true))
        }
        elements.append(DER.octetString(value))
        return DER.sequence(elements)
    }

    private static func basicConstraints(isCA: Bool) -> [UInt8] {
        isCA ? DER.sequence([boolean(true)]) : DER.sequence([])
    }

    private static func keyUsage(isCA: Bool) -> [UInt8] {
        isCA ? bitString(unusedBits: 2, bytes: [0x04]) : bitString(unusedBits: 7, bytes: [0x80])
    }

    private static func san() -> [UInt8] {
        DER.sequence([
            DER.tlv(tag: 0x82, value: Array("localhost".utf8)),
            DER.tlv(tag: 0x87, value: [127, 0, 0, 1]),
        ])
    }

    private static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return DER.tlv(tag: 0x17, value: Array(formatter.string(from: date).utf8))
    }

    private static func boolean(_ value: Bool) -> [UInt8] {
        DER.tlv(tag: 0x01, value: [value ? 0xff : 0x00])
    }

    private static func bitString(unusedBits: UInt8, bytes: [UInt8]) -> [UInt8] {
        DER.tlv(tag: 0x03, value: [unusedBits] + bytes)
    }

    private static func serialNumber() -> [UInt8] {
        [0x01] + (0..<15).map { _ in UInt8.random(in: 0...255) }
    }
}
