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
            guard let spkiDER = subjectPublicKeyInfoDER(certificate: certificate) else {
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

    private static func subjectPublicKeyInfoDER(certificate: SecCertificate) -> [UInt8]? {
        guard let key = SecCertificateCopyKey(certificate) else {
            return nil
        }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            return nil
        }
        let algorithmIdentifier = DER.sequence([
            DER.objectIdentifier([1, 2, 840, 10045, 2, 1]),
            DER.objectIdentifier([1, 2, 840, 10045, 3, 1, 7])
        ])
        return DER.sequence([
            algorithmIdentifier,
            DER.bitString(Array(keyData))
        ])
    }
}

public enum CertChainError: Error, Equatable, Sendable {
    case invalidPEM
    case emptyChain
    case invalidCertificate
}
