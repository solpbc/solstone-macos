// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security

final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let expectedFingerprintBytes: [UInt8]

    init(expectedFingerprintBytes: [UInt8]) {
        precondition(expectedFingerprintBytes.count == 16)
        self.expectedFingerprintBytes = expectedFingerprintBytes
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              Self.fingerprintMatchesPin(serverTrust: trust, expectedFingerprintBytes: expectedFingerprintBytes) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func fingerprintMatchesPin(serverTrust: SecTrust, expectedFingerprintBytes: [UInt8]) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        let data = SecCertificateCopyData(leaf) as Data
        return pinMatches(certificateDER: data, expectedFingerprintBytes: expectedFingerprintBytes)
    }

    static func pinMatches(certificateDER: Data, expectedFingerprintBytes: [UInt8]) -> Bool {
        guard expectedFingerprintBytes.count == 16 else {
            return false
        }
        let digest = Array(SHA256.hash(data: certificateDER))
        return Array(digest.prefix(16)) == expectedFingerprintBytes
    }
}
