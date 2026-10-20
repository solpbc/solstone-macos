// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MacTestSupport
import SPLTunnel
import Testing
@testable import solstone

/// The pairing device label is this Mac's host name, and reading it can wait on macOS's
/// local network prompt. Walked on minnie, 2026-10-20: read on the main thread at the setup
/// hand-back, it froze the solstone app for the 14 s the prompt was up.
@Suite("Pairing reads the device label off the main thread")
@MainActor
struct PairingDeviceLabelThreadTests {
    private func fingerprint(_ pem: String = testCACertPEM) throws -> String {
        CertChain.sha256Fingerprint(of: try #require(CertChain.certificates(fromPEM: pem).first))
    }

    @Test func aPairingLinkReadsTheLabelOffTheMainThread() async throws {
        let sent = SentLabels()
        let coordinator = PairingCoordinator(
            pair: { _, label, _ in sent.record(label); return pairing() },
            keychainStore: PairingStore(pairing: nil),
            deviceLabel: { Thread.isMainThread ? "read on main" : "read off main" }
        )

        await coordinator.submitPairingLink(try relayPairLink(caPEM: testCACertPEM))

        #expect(sent.labels == ["read off main"])
    }

    @Test func theSetupHandBackPairingReadsTheLabelOffTheMainThread() async throws {
        let sent = SentLabels()
        let saved = pairing()
        let store = PairingStore(pairing: nil)
        let coordinator = PairingCoordinator(
            pair: { _, label, _ in sent.record(label); return saved },
            keychainStore: store,
            credentialStore: PairingCredentialStore(store: store),
            deviceLabel: { Thread.isMainThread ? "read on main" : "read off main" }
        )

        await coordinator.submitSupportingPairingLink(
            try relayPairLink(caPEM: testCACertPEM), handoffID: UUID(),
            expectedInstanceID: saved.instanceID, expectedCAFingerprint: try fingerprint(),
            while: { true }
        )

        #expect(sent.labels == ["read off main"])
    }
}

final class SentLabels: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var labels: [String] { lock.withLock { recorded } }

    func record(_ label: String) {
        lock.withLock { recorded.append(label) }
    }
}
