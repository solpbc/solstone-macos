// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
@testable import SPLTunnel

enum MockHomeCA {
    enum Error: Swift.Error, Equatable {
        case invalidPEM
        case invalidCSR(String)
        case unsupportedAlgorithm
        case signatureInvalid
    }

    static func parseAndVerifyCSR(_ pem: String) throws -> (cn: String, publicKey: P256.Signing.PublicKey) {
        let bytes: [UInt8]
        do {
            bytes = try CryptoCSR.pemDecode(pem, label: "CERTIFICATE REQUEST")
        } catch {
            throw Error.invalidPEM
        }

        let outer = try ASN1.readSingle(bytes)
        guard outer.tag == 0x30 else {
            throw Error.invalidCSR("outer value is not a sequence")
        }
        let children = try ASN1.children(of: outer)
        guard children.count == 3 else {
            throw Error.invalidCSR("wrong child count")
        }

        let info = children[0]
        let algorithm = children[1]
        let signature = children[2]
        guard algorithm.full == CertBuilder.signatureAlgorithm() else {
            throw Error.unsupportedAlgorithm
        }
        guard signature.tag == 0x03, signature.value.first == 0x00 else {
            throw Error.invalidCSR("signature is not a bit string")
        }

        let infoChildren = try ASN1.children(of: info)
        guard infoChildren.count == 4 else {
            throw Error.invalidCSR("certification request info has wrong child count")
        }
        let cn = try commonName(from: infoChildren[1])
        let publicKey = try publicKey(from: infoChildren[2])
        let signatureDER = Data(signature.value.dropFirst())
        let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        guard publicKey.isValidSignature(ecdsaSignature, for: Data(info.full)) else {
            throw Error.signatureInvalid
        }
        return (cn: cn, publicKey: publicKey)
    }

    static func signCSR(
        csrPEM: String,
        caKey: P256.Signing.PrivateKey,
        caCertPEM _: String,
        validityDays _: Int = 1
    ) throws -> String {
        let request = try parseAndVerifyCSR(csrPEM)
        let cert = try CertBuilder.certificate(
            subject: request.cn,
            issuer: "MockHome CA",
            subjectPublicKey: request.publicKey,
            issuerPrivateKey: caKey,
            isCA: false,
            extendedKeyUsage: [CertBuilder.oidClientAuth]
        )
        return CryptoCSR.pemEncode(cert, label: "CERTIFICATE")
    }

    private static func commonName(from subject: ASN1.Node) throws -> String {
        guard subject.tag == 0x30 else {
            throw Error.invalidCSR("subject is not a sequence")
        }
        let sets = try ASN1.children(of: subject)
        for set in sets where set.tag == 0x31 {
            for attribute in try ASN1.children(of: set) where attribute.tag == 0x30 {
                let values = try ASN1.children(of: attribute)
                guard values.count == 2 else {
                    continue
                }
                if values[0].full == DER.objectIdentifier(CertBuilder.oidCommonName),
                   values[1].tag == 0x0c,
                   let cn = String(bytes: values[1].value, encoding: .utf8) {
                    return cn
                }
            }
        }
        throw Error.invalidCSR("subject common name missing")
    }

    private static func publicKey(from spki: ASN1.Node) throws -> P256.Signing.PublicKey {
        guard spki.tag == 0x30 else {
            throw Error.invalidCSR("subject public key info is not a sequence")
        }
        let children = try ASN1.children(of: spki)
        guard children.count == 2,
              children[0].full == DER.sequence([
                DER.objectIdentifier(CertBuilder.oidEcPublicKey),
                DER.objectIdentifier(CertBuilder.oidPrime256v1),
              ]),
              children[1].tag == 0x03,
              children[1].value.first == 0x00 else {
            throw Error.unsupportedAlgorithm
        }
        do {
            return try P256.Signing.PublicKey(x963Representation: Data(children[1].value.dropFirst()))
        } catch {
            throw Error.invalidCSR("invalid p-256 public key")
        }
    }
}
