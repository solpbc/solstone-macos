// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Testing
@testable import SPLTunnel

@Suite("CryptoCSR")
struct CryptoCSRTests {
    @Test func generateProducesPEMMarkersAndLineWrap() throws {
        let generated = try CryptoCSR.generate(deviceLabel: "test mac")

        #expect(generated.csrPEM.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----\n"))
        #expect(generated.csrPEM.hasSuffix("-----END CERTIFICATE REQUEST-----\n"))
        #expect(generated.privateKeyPEM.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
        #expect(generated.privateKeyPEM.hasSuffix("-----END PRIVATE KEY-----\n"))
        for line in generated.csrPEM.split(separator: "\n") where !line.hasPrefix("-----") {
            #expect(line.count <= 64)
        }
        for line in generated.privateKeyPEM.split(separator: "\n") where !line.hasPrefix("-----") {
            #expect(line.count <= 64)
        }
    }

    @Test func csrSubjectCNMatchesDeviceLabel() throws {
        let csr = try buildTestCSR(label: "Jer's mac")
        let certInfo = try certificateInfo(from: csr)
        let subject = try ASN1.children(of: certInfo)[1]
        let rdn = try #require(try ASN1.children(of: subject).first)
        let attr = try #require(try ASN1.children(of: rdn).first)
        let attrChildren = try ASN1.children(of: attr)

        #expect(attrChildren[0].full == DER.objectIdentifier([2, 5, 4, 3]))
        #expect(String(decoding: attrChildren[1].value, as: UTF8.self) == "Jer's mac")
    }

    @Test func csrContainsExpectedP256SPKI() throws {
        let csr = try buildTestCSR(label: "test mac")
        let certInfo = try certificateInfo(from: csr)
        let spki = try ASN1.children(of: certInfo)[2]
        let spkiChildren = try ASN1.children(of: spki)
        let algorithm = try ASN1.children(of: spkiChildren[0])
        let publicKey = spkiChildren[1]

        #expect(algorithm[0].full == DER.objectIdentifier([1, 2, 840, 10045, 2, 1]))
        #expect(algorithm[1].full == DER.objectIdentifier([1, 2, 840, 10045, 3, 1, 7]))
        #expect(publicKey.value.count == 66)
        #expect(publicKey.value[0] == 0x00)
        #expect(publicKey.value[1] == 0x04)
    }

    @Test func csrSignatureVerifies() throws {
        let privateKey = P256.Signing.PrivateKey()
        let csr = try CryptoCSR.buildCSR(commonName: "test mac", privateKey: privateKey)
        let outer = try ASN1.children(of: ASN1.readSingle(csr))
        let certInfo = outer[0]
        let spki = try ASN1.children(of: certInfo)[2]
        let publicKeyBitString = try ASN1.children(of: spki)[1]
        let publicKeyBytes = Array(publicKeyBitString.value.dropFirst())
        let signatureBytes = Array(outer[2].value.dropFirst())

        let publicKey = try P256.Signing.PublicKey(x963Representation: Data(publicKeyBytes))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(signatureBytes))
        #expect(publicKey.isValidSignature(signature, for: Data(certInfo.full)))
    }

    @Test func csrHasEmptyAttributes() throws {
        let csr = try buildTestCSR(label: "test mac")
        let certInfo = try certificateInfo(from: csr)
        let attrs = try ASN1.children(of: certInfo)[3]
        #expect(attrs.full == [0xa0, 0x00])
    }

    @Test func pkcs8RoundTripsPrivateScalar() throws {
        let privateKey = P256.Signing.PrivateKey()
        let pem = CryptoCSR.pemEncode(CryptoCSR.exportPKCS8(privateKey), label: "PRIVATE KEY")
        let parsed = try CryptoCSR.pkcs8PEMToPrivateKey(pem)
        #expect(parsed.rawRepresentation == privateKey.rawRepresentation)
    }

    @Test func pkcs8RejectsSEC1() throws {
        let privateKey = P256.Signing.PrivateKey()
        let sec1 = DER.sequence([
            DER.integer([0x01]),
            DER.octetString(Array(privateKey.rawRepresentation)),
            DER.contextSpecific(tag: 0, value: DER.objectIdentifier([1, 2, 840, 10045, 3, 1, 7])),
            DER.contextSpecific(tag: 1, value: DER.bitString(Array(privateKey.publicKey.x963Representation)))
        ])
        let pem = CryptoCSR.pemEncode(sec1, label: "PRIVATE KEY")

        expectPKCS8Error {
            _ = try CryptoCSR.pkcs8PEMToPrivateKey(pem)
        }
    }

    @Test func pemRoundTrip() throws {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let pem = CryptoCSR.pemEncode(bytes, label: "TEST")
        #expect(try CryptoCSR.pemDecode(pem, label: "TEST") == bytes)
    }

    @Test func oidEncodingsMatchReference() {
        #expect(DER.objectIdentifier([2, 5, 4, 3]) == [0x06, 0x03, 0x55, 0x04, 0x03])
        #expect(DER.objectIdentifier([1, 2, 840, 10045, 2, 1]) == [
            0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01
        ])
        #expect(DER.objectIdentifier([1, 2, 840, 10045, 3, 1, 7]) == [
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07
        ])
        #expect(DER.objectIdentifier([1, 2, 840, 10045, 4, 3, 2]) == [
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02
        ])
    }

    private func buildTestCSR(label: String) throws -> [UInt8] {
        try CryptoCSR.buildCSR(commonName: label, privateKey: P256.Signing.PrivateKey())
    }

    private func certificateInfo(from csr: [UInt8]) throws -> ASN1.Node {
        let outer = try ASN1.readSingle(csr)
        return try ASN1.children(of: outer)[0]
    }

    private func expectPKCS8Error(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected invalidPKCS8")
        } catch CryptoCSRError.invalidPKCS8 {
        } catch {
            Issue.record("Expected invalidPKCS8, got \(error)")
        }
    }
}
