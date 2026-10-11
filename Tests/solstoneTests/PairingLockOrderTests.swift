// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
@Suite("Pairing lock ordering")
struct PairingLockOrderTests {
    @Test func reloadAndSyncAdmissionCompleteConcurrently() throws {
        let stored = pairing()
        let credentials = PairingCredentialStore(store: InMemoryPairingStore(pairing: stored))
        _ = try credentials.load()
        let identity = TunnelPairingIdentity(instanceID: stored.instanceID, fingerprint: stored.fingerprint)
        let context = try #require(JournalUploadContext(
            pairing: identity,
            suppliedFingerprint: tunnelJournalConnectionFingerprint(for: identity),
            credentialRevision: PairingCredentialRevision(from: stored).revision
        ))
        #expect(credentials.ordinarySyncIsCurrent(context))
        let workers = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        DispatchQueue.global().async(group: workers) {
            start.wait()
            for _ in 0..<2_000 { _ = try? credentials.load() }
        }
        DispatchQueue.global().async(group: workers) {
            start.wait()
            for _ in 0..<2_000 { _ = credentials.ordinarySyncIsCurrent(context) }
        }
        start.signal()
        start.signal()
        #expect(workers.wait(timeout: .now() + 20) == .success)
    }
}
#endif
