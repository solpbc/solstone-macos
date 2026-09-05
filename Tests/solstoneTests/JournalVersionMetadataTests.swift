// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone

final class JournalVersionMetadataTests: XCTestCase {
    @MainActor
    func testRefreshRecoveryFailureAndOfflineRestore() async throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let owner = JournalVersionMetadata(defaults: defaults) { port in
            switch port {
            case 1: return "2.0.0"
            case 2: return "2.0.1"
            default: return nil
            }
        }
        owner.setIdentity("journal-a")
        await owner.connected(localPort: 1)?.value
        XCTAssertEqual(owner.version, "2.0.0")
        XCTAssertTrue(owner.isCurrent)
        owner.disconnected()
        XCTAssertFalse(owner.isCurrent)
        await owner.connected(localPort: 2)?.value
        XCTAssertEqual(owner.version, "2.0.1")
        XCTAssertTrue(owner.isCurrent)
        owner.disconnected()
        await owner.connected(localPort: 3)?.value
        XCTAssertEqual(owner.version, "2.0.1")
        XCTAssertFalse(owner.isCurrent)
        let restored = JournalVersionMetadata(defaults: defaults)
        restored.setIdentity("journal-a")
        XCTAssertEqual(restored.version, "2.0.1")
        XCTAssertFalse(restored.isCurrent)
        restored.setIdentity("journal-b")
        XCTAssertNil(restored.version)
        XCTAssertNil(sanitizedJournalVersion("2.0\n"))
        XCTAssertNil(sanitizedJournalVersion("  "))
    }

    @MainActor
    func testObsoleteCompletionCannotOverwriteReconnectOrSameIdentityPairing() async throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let (results, continuation) = AsyncStream<String>.makeStream()
        let owner = JournalVersionMetadata(defaults: defaults) { port in
            if port == 2 { return "2.0.2" }
            for await result in results { return result }
            return nil
        }
        owner.setIdentity("journal-a")
        let old = owner.connected(localPort: 1)
        owner.disconnected()
        await owner.connected(localPort: 2)?.value
        continuation.yield("2.0.0")
        continuation.finish()
        await old?.value
        XCTAssertEqual(owner.version, "2.0.2")
        XCTAssertTrue(owner.isCurrent)
        owner.clear()
        owner.setIdentity("journal-a")
        XCTAssertNil(owner.version)
        XCTAssertFalse(owner.isCurrent)
        await owner.connected(localPort: 2)?.value
        XCTAssertEqual(owner.version, "2.0.2")
        XCTAssertTrue(owner.isCurrent)
    }
}
