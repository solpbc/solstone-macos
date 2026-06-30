// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security

public enum PairingCAPinKind: Sendable, Equatable, Hashable {
    case certificateSHA256
    case spkiSHA256
}

public struct PairingCAPin: Sendable, Equatable, Hashable {
    public let kind: PairingCAPinKind
    public let prefixBytes: [UInt8]

    public init(kind: PairingCAPinKind, prefixBytes: [UInt8]) {
        self.kind = kind
        self.prefixBytes = prefixBytes
    }
}

/// Certificate helpers for pair-response storage and CA-chain pinning.
/// Direct links carry a CA cert DER hash prefix; relay links carry a CA SPKI
/// hash prefix. Established sessions anchor trust to the stored private CA
/// chain.
public enum CertChain {
    public static func certificates(fromPEM pem: String) throws -> [SecCertificate] {
        let blocks = try pemBlocks(from: pem, label: "CERTIFICATE")
        guard !blocks.isEmpty else {
            throw CertChainError.emptyChain
        }

        return try blocks.map { der in
            guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
                throw CertChainError.invalidCertificate
            }
            return certificate
        }
    }

    public static func sha256Fingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return hex(SHA256.hash(data: data))
    }

    public static func pinMatches(certificate: SecCertificate, pin: PairingCAPin) -> Bool {
        guard !pin.prefixBytes.isEmpty else {
            return false
        }

        let digest: [UInt8]
        switch pin.kind {
        case .certificateSHA256:
            let data = SecCertificateCopyData(certificate) as Data
            digest = Array(SHA256.hash(data: data))
        case .spkiSHA256:
            guard let spkiDER = try? canonicalP256SubjectPublicKeyInfoDER(certificate: certificate) else {
                return false
            }
            digest = Array(SHA256.hash(data: Data(spkiDER)))
        }
        guard pin.prefixBytes.count <= digest.count else {
            return false
        }
        return Array(digest.prefix(pin.prefixBytes.count)) == pin.prefixBytes
    }

    static func pemBlocks(from pem: String, label: String) throws -> [[UInt8]] {
        let begin = "-----BEGIN \(label)-----"
        let end = "-----END \(label)-----"
        var cursor = pem.startIndex
        var blocks: [[UInt8]] = []

        while let beginRange = pem.range(of: begin, range: cursor..<pem.endIndex) {
            guard let endRange = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex) else {
                throw CertChainError.invalidPEM
            }

            let body = pem[beginRange.upperBound..<endRange.lowerBound]
                .filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: String(body)) else {
                throw CertChainError.invalidPEM
            }
            blocks.append(Array(data))
            cursor = endRange.upperBound
        }

        return blocks
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalP256SubjectPublicKeyInfoDER(certificate: SecCertificate) throws -> [UInt8] {
        guard let key = SecCertificateCopyKey(certificate) else {
            throw CertChainError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw CertChainError.invalidPublicKey
        }
        do {
            let publicKey = try P256.Signing.PublicKey(x963Representation: keyData)
            return Array(publicKey.derRepresentation)
        } catch {
            throw CertChainError.invalidPublicKey
        }
    }

    public static func jidFromSPKI(_ spkiDER: [UInt8]) -> String {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(spkiDER)),
            salt: Data("solstone/journal/v1".utf8),
            info: Data("solstone/jid/uuidv8/v1".utf8),
            outputByteCount: 16
        )
        var bytes = key.withUnsafeBytes { Array($0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }

}

public enum CertChainError: Error, Equatable, Sendable {
    case invalidPEM
    case emptyChain
    case invalidCertificate
    case invalidPublicKey
}
