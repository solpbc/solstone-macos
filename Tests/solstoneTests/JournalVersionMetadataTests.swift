// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Synchronization
import XCTest
@testable import solstone

final class JournalVersionMetadataTests: XCTestCase {
    @MainActor
    func testRefreshRecoveryFailureAndOfflineRestore() async throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let owner = JournalVersionMetadata(defaults: defaults, now: { Date() }, fetch: { port in
            switch port {
            case 1: return "2.0.0"
            case 2: return "2.0.1"
            default: return nil
        }
        })
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
        let owner = JournalVersionMetadata(defaults: defaults, now: { Date() }, fetch: { port in
            if port == 2 { return "2.0.2" }
            for await result in results { return result }
            return nil
        })
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

    @MainActor
    func testLegacyAndCorruptOptionalRecordFieldsRestoreCoreMetadata() throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data(#"{"identity":"journal-a","version":"v2.0.0","name":"home base"}"#.utf8), forKey: "journalVersionMetadata")

        let legacy = JournalVersionMetadata(defaults: defaults)
        legacy.setIdentity("journal-a")
        XCTAssertEqual(legacy.version, "v2.0.0")
        XCTAssertEqual(legacy.journalName, "home base")
        XCTAssertNil(legacy.hostOS)
        XCTAssertNil(legacy.versionObservedAt)
        XCTAssertEqual(legacy.ownerFacingJournalLine(now: Date(timeIntervalSince1970: 1_700_000_000)), "journal 2.0.0")

        let corruptOptionals: [String: Any] = [
            "identity": "journal-a",
            "version": "v2.0.1",
            "name": "restored name",
            "host_build": 42,
            "host_os": "linux",
            "host_os_version": "6.11.0",
            "host_arch": true,
            "version_observed_at": Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate,
            "host_facts_accepted_at": "bad timestamp"
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: corruptOptionals), forKey: "journalVersionMetadata")
        let recovered = JournalVersionMetadata(defaults: defaults)
        recovered.setIdentity("journal-a")
        XCTAssertEqual(recovered.version, "v2.0.1")
        XCTAssertEqual(recovered.journalName, "restored name")
        XCTAssertNil(recovered.hostBuild)
        XCTAssertEqual(recovered.hostOS, "linux")
        XCTAssertEqual(recovered.hostOSVersion, "6.11.0")
        XCTAssertNil(recovered.hostArch)
        XCTAssertEqual(recovered.versionObservedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(recovered.hostFactsAcceptedAt)
    }

    @MainActor
    func testFactAcceptDoesNotRenewVersionObservationAndDisconnectKeepsAgeFacts() throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let times = Mutex([
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_030),
            Date(timeIntervalSince1970: 1_700_000_100)
        ])
        let owner = JournalVersionMetadata(defaults: defaults, now: { times.withLock { $0.removeFirst() } })
        owner.setIdentity("journal-a")
        owner.applyDirectly(identity: "journal-a", version: "vv2.0.0", name: "home base")
        let versionObservedAt = owner.versionObservedAt

        let about = #"{"protocol_version":1,"version":"v2.0.0","os":"ubuntu","os_version":"24.04","arch":"amd64","about":"journal 2.0.0 · ubuntu 24.04 · x86_64"}"#
        let resource = try XCTUnwrap(SolstoneCoreAbout.decodeResource(Data(about.utf8)))
        XCTAssertEqual(owner.receiveAbout(resource, identity: "journal-a", generation: owner.currentGeneration()), .accepted)
        XCTAssertEqual(owner.versionObservedAt, versionObservedAt)
        XCTAssertNotNil(owner.hostFactsAcceptedAt)

        owner.disconnected()
        XCTAssertFalse(owner.isCurrent)
        XCTAssertEqual(owner.versionObservedAt, versionObservedAt)
        XCTAssertNotNil(owner.hostFactsAcceptedAt)
        XCTAssertEqual(
            owner.ownerFacingJournalLine(now: Date(timeIntervalSince1970: 1_700_172_800)),
            "journal 2.0.0 · ubuntu 24.04 · x86_64 · last seen 2d ago"
        )

        owner.applyDirectly(identity: "journal-a", version: "vv2.0.0", name: nil, preserveName: true)
        XCTAssertEqual(owner.versionObservedAt, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(owner.hostFactsAcceptedAt, Date(timeIntervalSince1970: 1_700_000_030))
    }

    @MainActor
    func testIdentitySwitchPublishesOnlyTheNewIdentitySnapshot() throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let owner = JournalVersionMetadata(defaults: defaults, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        owner.setIdentity("journal-a")
        owner.applyDirectly(identity: "journal-a", version: "8.7.6", name: "Journal A")
        let resource = try XCTUnwrap(SolstoneCoreAbout.decodeResource(Data(
            #"{"protocol_version":1,"version":"8.7.6","build":"42","os":"macos","os_version":"15.6","arch":"arm64","about":"journal 8.7.6 (42) · macos 15.6 · arm64"}"#.utf8
        )))
        XCTAssertEqual(owner.receiveAbout(resource, identity: "journal-a", generation: owner.currentGeneration()), .accepted)

        let recordedSnapshots = Mutex<[SolstoneCoreAbout.NativeSnapshot]>([])
        owner.onAboutChanged = { [weak owner] _ in
            guard let owner else { return }
            let snapshot = owner.nativeAboutSnapshot(os: "macos", osVersion: "15.6", arch: "arm64")
            recordedSnapshots.withLock { $0.append(snapshot) }
        }

        owner.setIdentity("journal-b")

        let snapshots = recordedSnapshots.withLock { $0 }
        let lines = snapshots.map(\.journalLine)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(lines.allSatisfy { !$0.contains("8.7.6") })
        XCTAssertEqual(lines.first, "journal unknown")
    }

    @MainActor
    func testNewVersionClearsFactsAndCorruptNameStillRejectsWholeRecord() throws {
        let name = "JournalVersionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let owner = JournalVersionMetadata(defaults: defaults, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        owner.setIdentity("journal-a")
        owner.applyDirectly(identity: "journal-a", version: "2.0.0", name: "home base")
        let resource = try XCTUnwrap(SolstoneCoreAbout.decodeResource(Data(#"{"protocol_version":1,"version":"2.0.0","os":"linux","os_version":"6.11.0","arch":"x64","about":"journal 2.0.0 · linux 6.11.0 · x86_64"}"#.utf8)))
        XCTAssertEqual(owner.receiveAbout(resource, identity: "journal-a", generation: owner.currentGeneration()), .accepted)
        owner.applyDirectly(identity: "journal-a", version: "2.0.1", name: "home base")
        XCTAssertNil(owner.hostOS)
        XCTAssertNil(owner.hostFactsAcceptedAt)
        XCTAssertEqual(owner.version, "2.0.1")

        let corruptName: [String: Any] = ["identity": "journal-a", "version": "2.0.1", "name": 42]
        defaults.set(try JSONSerialization.data(withJSONObject: corruptName), forKey: "journalVersionMetadata")
        let restored = JournalVersionMetadata(defaults: defaults)
        restored.setIdentity("journal-a")
        XCTAssertNil(restored.version)
        XCTAssertNil(defaults.data(forKey: "journalVersionMetadata"))
    }
}
