// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security

/// Certificate helpers for pair-response storage and leaf-certificate pinning.
/// PairClient stores the issued client certificate SHA-256 fingerprint, while
/// PinningDelegate compares the first 16 bytes of the presented leaf DER hash.
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
}

public enum CertChainError: Error, Equatable, Sendable {
    case invalidPEM
    case emptyChain
    case invalidCertificate
}
