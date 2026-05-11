// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation

public enum CryptoCSRError: Error, Equatable, Sendable {
    case invalidDeviceLabel
    case signatureFailed
    case encodingFailed
    case invalidPKCS8(reason: String)
}

public enum CryptoCSR {
    private static let oidCommonName: [UInt64] = [2, 5, 4, 3]
    private static let oidEcPublicKey: [UInt64] = [1, 2, 840, 10045, 2, 1]
    private static let oidPrime256v1: [UInt64] = [1, 2, 840, 10045, 3, 1, 7]
    private static let oidEcdsaWithSHA256: [UInt64] = [1, 2, 840, 10045, 4, 3, 2]

    public static func generate(deviceLabel: String) throws -> (csrPEM: String, privateKeyPEM: String) {
        guard !deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CryptoCSRError.invalidDeviceLabel
        }

        let privateKey = P256.Signing.PrivateKey()
        let csrDER = try buildCSR(commonName: deviceLabel, privateKey: privateKey)
        let privateKeyDER = exportPKCS8(privateKey)
        return (
            csrPEM: pemEncode(csrDER, label: "CERTIFICATE REQUEST"),
            privateKeyPEM: pemEncode(privateKeyDER, label: "PRIVATE KEY")
        )
    }

    static func buildCSR(commonName: String, privateKey: P256.Signing.PrivateKey) throws -> [UInt8] {
        guard !commonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CryptoCSRError.invalidDeviceLabel
        }

        let subject = DER.sequence([
            DER.set([
                DER.sequence([
                    DER.objectIdentifier(oidCommonName),
                    DER.utf8String(commonName)
                ])
            ])
        ])
        let algorithmIdentifier = DER.sequence([
            DER.objectIdentifier(oidEcPublicKey),
            DER.objectIdentifier(oidPrime256v1)
        ])
        let subjectPublicKeyInfo = DER.sequence([
            algorithmIdentifier,
            DER.bitString(Array(privateKey.publicKey.x963Representation))
        ])
        let certInfo = DER.sequence([
            DER.integer([0x00]),
            subject,
            subjectPublicKeyInfo,
            DER.contextSpecific(tag: 0, value: [])
        ])

        let signature: P256.Signing.ECDSASignature
        do {
            signature = try privateKey.signature(for: Data(certInfo))
        } catch {
            throw CryptoCSRError.signatureFailed
        }

        let signatureAlgorithm = DER.sequence([
            DER.objectIdentifier(oidEcdsaWithSHA256)
        ])
        return DER.sequence([
            certInfo,
            signatureAlgorithm,
            DER.bitString(Array(signature.derRepresentation))
        ])
    }

    static func exportPKCS8(_ privateKey: P256.Signing.PrivateKey) -> [UInt8] {
        let scalar = leftPad(Array(privateKey.rawRepresentation), count: 32)
        let publicPoint = Array(privateKey.publicKey.x963Representation)
        let algorithmIdentifier = DER.sequence([
            DER.objectIdentifier(oidEcPublicKey),
            DER.objectIdentifier(oidPrime256v1)
        ])
        let ecPrivateKey = DER.sequence([
            DER.integer([0x01]),
            DER.octetString(scalar),
            DER.contextSpecific(tag: 0, value: DER.objectIdentifier(oidPrime256v1)),
            DER.contextSpecific(tag: 1, value: DER.bitString(publicPoint))
        ])
        return DER.sequence([
            DER.integer([0x00]),
            algorithmIdentifier,
            DER.octetString(ecPrivateKey)
        ])
    }

    static func pkcs8PEMToPrivateKey(_ pem: String) throws -> P256.Signing.PrivateKey {
        let der = try pemDecode(pem, label: "PRIVATE KEY")
        let scalar = try parsePKCS8PrivateScalar(der)
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: Data(scalar))
        } catch {
            throw CryptoCSRError.invalidPKCS8(reason: "invalid P-256 scalar")
        }
    }

    static func pemEncode(_ bytes: [UInt8], label: String) -> String {
        let base64 = Data(bytes).base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<next]))
            index = next
        }
        return "-----BEGIN \(label)-----\n\(lines.joined(separator: "\n"))\n-----END \(label)-----\n"
    }

    static func pemDecode(_ pem: String, label: String) throws -> [UInt8] {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        guard let beginRange = pem.range(of: begin),
              let endRange = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex) else {
            throw CryptoCSRError.encodingFailed
        }

        let body = pem[beginRange.upperBound..<endRange.lowerBound]
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else {
            throw CryptoCSRError.encodingFailed
        }
        return Array(data)
    }

    private static func parsePKCS8PrivateScalar(_ bytes: [UInt8]) throws -> [UInt8] {
        let outer = try ASN1.readSingle(bytes)
        guard outer.tag == 0x30 else {
            throw CryptoCSRError.invalidPKCS8(reason: "outer value is not a sequence")
        }
        let outerChildren = try ASN1.children(of: outer)
        guard outerChildren.count == 3 else {
            throw CryptoCSRError.invalidPKCS8(reason: "outer sequence has wrong child count")
        }
        guard outerChildren[0].tag == 0x02, outerChildren[0].value == [0x00] else {
            throw CryptoCSRError.invalidPKCS8(reason: "outer version is not 0")
        }
        try validateAlgorithmIdentifier(outerChildren[1])
        guard outerChildren[2].tag == 0x04 else {
            throw CryptoCSRError.invalidPKCS8(reason: "private key wrapper is not an octet string")
        }

        let inner = try ASN1.readSingle(outerChildren[2].value)
        guard inner.tag == 0x30 else {
            throw CryptoCSRError.invalidPKCS8(reason: "inner value is not an ECPrivateKey sequence")
        }
        let innerChildren = try ASN1.children(of: inner)
        guard innerChildren.count >= 2 else {
            throw CryptoCSRError.invalidPKCS8(reason: "inner sequence is incomplete")
        }
        guard innerChildren[0].tag == 0x02, innerChildren[0].value == [0x01] else {
            throw CryptoCSRError.invalidPKCS8(reason: "inner version is not 1")
        }
        guard innerChildren[1].tag == 0x04 else {
            throw CryptoCSRError.invalidPKCS8(reason: "private scalar is missing")
        }
        let scalar = innerChildren[1].value
        guard scalar.count == 32 else {
            throw CryptoCSRError.invalidPKCS8(reason: "private scalar is not 32 bytes")
        }
        return scalar
    }

    private static func validateAlgorithmIdentifier(_ node: ASN1.Node) throws {
        guard node.tag == 0x30 else {
            throw CryptoCSRError.invalidPKCS8(reason: "algorithm identifier is not a sequence")
        }
        let children = try ASN1.children(of: node)
        guard children.count == 2,
              children[0].full == DER.objectIdentifier(oidEcPublicKey),
              children[1].full == DER.objectIdentifier(oidPrime256v1) else {
            throw CryptoCSRError.invalidPKCS8(reason: "algorithm identifier is not P-256 EC")
        }
    }

    private static func leftPad(_ bytes: [UInt8], count: Int) -> [UInt8] {
        if bytes.count >= count {
            return bytes
        }
        return Array(repeating: 0, count: count - bytes.count) + bytes
    }
}

enum ASN1 {
    struct Node: Equatable {
        let tag: UInt8
        let value: [UInt8]
        let full: [UInt8]
    }

    static func readSingle(_ bytes: [UInt8]) throws -> Node {
        var index = 0
        let node = try readNode(bytes, index: &index)
        guard index == bytes.count else {
            throw CryptoCSRError.invalidPKCS8(reason: "trailing ASN.1 data")
        }
        return node
    }

    static func children(of node: Node) throws -> [Node] {
        var index = 0
        var children: [Node] = []
        while index < node.value.count {
            children.append(try readNode(node.value, index: &index))
        }
        return children
    }

    static func readNode(_ bytes: [UInt8], index: inout Int) throws -> Node {
        let start = index
        guard index + 2 <= bytes.count else {
            throw CryptoCSRError.invalidPKCS8(reason: "truncated ASN.1 header")
        }

        let tag = bytes[index]
        index += 1
        let length = try readLength(bytes, index: &index)
        guard index + length <= bytes.count else {
            throw CryptoCSRError.invalidPKCS8(reason: "truncated ASN.1 value")
        }

        let value = Array(bytes[index..<(index + length)])
        index += length
        return Node(tag: tag, value: value, full: Array(bytes[start..<index]))
    }

    private static func readLength(_ bytes: [UInt8], index: inout Int) throws -> Int {
        guard index < bytes.count else {
            throw CryptoCSRError.invalidPKCS8(reason: "missing ASN.1 length")
        }

        let first = bytes[index]
        index += 1
        if first & 0x80 == 0 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= MemoryLayout<Int>.size, index + byteCount <= bytes.count else {
            throw CryptoCSRError.invalidPKCS8(reason: "invalid ASN.1 length")
        }

        var value = 0
        for _ in 0..<byteCount {
            value = (value << 8) | Int(bytes[index])
            index += 1
        }
        return value
    }
}
