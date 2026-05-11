// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security

final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              Self.fingerprintMatchesPin(serverTrust: trust, expected: expectedFingerprint) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func fingerprintMatchesPin(serverTrust: SecTrust, expected: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first else {
            return false
        }
        let data = SecCertificateCopyData(leaf) as Data
        let fingerprint = CertChain.hex(SHA256.hash(data: data))
        return CertChain.fingerprintsMatch(fingerprint, expected)
    }
}
