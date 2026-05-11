// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SPLTunnel

@Suite("CertChain")
struct CertChainTests {
    private let cert1 = """
    -----BEGIN CERTIFICATE-----
    MIIBdTCCARugAwIBAgIUVMEtHY4txnB9yvPieVZOPQb8B/swCgYIKoZIzj0EAwIw
    EDEOMAwGA1UEAwwFdGVzdDEwHhcNMjYwNTExMDU0OTI4WhcNMzYwNTA4MDU0OTI4
    WjAQMQ4wDAYDVQQDDAV0ZXN0MTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPih
    dGj0TbzBAXX6uLTt/rKpwd7t8DohOFLZ44i9KlffKSrMHvo2DufP/oUVB+V/jJy9
    0PQuCc+/j2NrTtHOh3yjUzBRMB0GA1UdDgQWBBQrAyo4k6cTcZB56UCx7ZcJPWxH
    ezAfBgNVHSMEGDAWgBQrAyo4k6cTcZB56UCx7ZcJPWxHezAPBgNVHRMBAf8EBTAD
    AQH/MAoGCCqGSM49BAMCA0gAMEUCIA0cayl/grfqS8xzPnv3+A6Wqb7NL8QvfgPu
    ZBXoDWAEAiEAgCfoRUL0QMRHSW4FKBCyqn63nZBYfgcl2q4I+kYz0y4=
    -----END CERTIFICATE-----
    """

    private let cert2 = """
    -----BEGIN CERTIFICATE-----
    MIIBdjCCARugAwIBAgIUPmc8qjlLPIA4EFu09uWC+SpZMBAwCgYIKoZIzj0EAwIw
    EDEOMAwGA1UEAwwFdGVzdDIwHhcNMjYwNTExMDU0OTI4WhcNMzYwNTA4MDU0OTI4
    WjAQMQ4wDAYDVQQDDAV0ZXN0MjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABE34
    z7zq08sFkDWZCydwYPbUZ0p6axn7HVfFfMvoBSJI1sx0ugGzsO20gUKvQkS1f82o
    wPZALFfM/2QhFxaXibajUzBRMB0GA1UdDgQWBBS0hMPoitOyZ9HNf6Jn9N62yCtN
    yzAfBgNVHSMEGDAWgBS0hMPoitOyZ9HNf6Jn9N62yCtNyzAPBgNVHRMBAf8EBTAD
    AQH/MAoGCCqGSM49BAMCA0kAMEYCIQCp2/epKon4CeHgWUTFJT7SjTpDODpJONYu
    C+oCUlJiOQIhAPO48QBJMB7pJ3gRqUFTGg5j2lBpky934j0CPQvU/w8V
    -----END CERTIFICATE-----
    """

    private let cert1Fingerprint = "005a64c08d69da268c62971466aca5324eaba7ead27e3d4e33ddaa244535e168"

    @Test func parseSingleCertificate() throws {
        let certificates = try CertChain.certificates(fromPEM: cert1)
        #expect(certificates.count == 1)
    }

    @Test func parseTwoCertificateChainPreservesOrder() throws {
        let certificates = try CertChain.certificates(fromPEM: cert1 + "\n" + cert2)
        #expect(certificates.count == 2)
        #expect(CertChain.sha256Fingerprint(of: certificates[0]) == cert1Fingerprint)
        #expect(CertChain.sha256Fingerprint(of: certificates[1]) == "98cbe01d5f20637053f0ec7a33c672d3747d20c1ce52ca53e76bea7c1fdeac98")
    }

    @Test func fingerprintMatchesOpenSSLFixture() throws {
        let certificate = try #require(try CertChain.certificates(fromPEM: cert1).first)
        #expect(CertChain.sha256Fingerprint(of: certificate) == cert1Fingerprint)
    }

    @Test func fingerprintsMatchAcceptsPrefixOnEitherSide() {
        #expect(CertChain.fingerprintsMatch("sha256:\(cert1Fingerprint)", cert1Fingerprint))
        #expect(CertChain.fingerprintsMatch(cert1Fingerprint, "sha256:\(cert1Fingerprint)"))
    }

    @Test func fingerprintsMatchIsCaseInsensitive() {
        #expect(CertChain.fingerprintsMatch(cert1Fingerprint.uppercased(), cert1Fingerprint))
    }

    @Test func invalidPEMThrows() {
        expectThrows(.emptyChain) {
            _ = try CertChain.certificates(fromPEM: "")
        }
        expectThrows(.invalidPEM) {
            _ = try CertChain.certificates(fromPEM: """
            -----BEGIN CERTIFICATE-----
            not base64
            -----END CERTIFICATE-----
            """)
        }
        expectThrows(.invalidCertificate) {
            let bytes = Data([0x01, 0x02, 0x03]).base64EncodedString()
            _ = try CertChain.certificates(fromPEM: """
            -----BEGIN CERTIFICATE-----
            \(bytes)
            -----END CERTIFICATE-----
            """)
        }
    }

    private func expectThrows(_ expected: CertChainError, _ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected \(expected)")
        } catch let error as CertChainError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error)")
        }
    }
}
