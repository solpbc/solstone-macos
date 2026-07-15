// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("AppPlacementRepair")
struct AppPlacementRepairTests {
    @Test func sameOrNewerValidInstallReopensUntouched() throws {
        let world = FakePlacementRepairWorld()
        world.installSource(build: 57, token: "source")
        world.installCanonical(build: 58, token: "installed")
        world.applicationsWritable = false

        let outcome = try world.service.repair(context: world.context)

        #expect(outcome == .reopenedExisting(world.canonicalURL))
        #expect(world.record(at: world.canonicalURL)?.token == "installed")
        #expect(world.copyCount == 0)
        #expect(world.markers == [FakeMarkerCall(reason: AppPlacementRepairService.expectedExitReason, pid: world.pid)])
        #expect(world.launches == [world.canonicalURL])
        world.expectSourceUntouched()
        world.expectNoAttemptBytes()
    }

    @Test func newerRunningBuildReplacesOlderValidInstallAfterStagedVerification() throws {
        let world = FakePlacementRepairWorld()
        world.installSource(build: 59, token: "source", quarantined: true)
        world.installCanonical(build: 58, token: "installed")

        let outcome = try world.service.repair(context: world.context)

        #expect(outcome == .reopenedInstalled(world.canonicalURL))
        #expect(world.record(at: world.canonicalURL)?.token == "source")
        #expect(world.record(at: world.canonicalURL)?.quarantined == false)
        #expect(world.copyCount == 1)
        #expect(world.trustCheckedPaths.count == 2)
        #expect(world.markers == [FakeMarkerCall(reason: AppPlacementRepairService.expectedExitReason, pid: world.pid)])
        #expect(world.launches == [world.canonicalURL])
        world.expectSourceUntouched()
        world.expectNoAttemptBytes()
    }

    @Test func liveReplaceItemRetainsBackupForRollback() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let originalURL = tempDirectory.appendingPathComponent("solstone.app", isDirectory: true)
        let replacementURL = tempDirectory.appendingPathComponent("staged-solstone.app", isDirectory: true)
        let backupName = ".solstone-placement-backup-\(UUID().uuidString).app"
        try FileManager.default.createDirectory(at: originalURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementURL, withIntermediateDirectories: true)
        try "original".write(
            to: originalURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "replacement".write(
            to: replacementURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )

        let dependencies = AppPlacementRepairDependencies.live(applicationsURL: tempDirectory)
        let backupURL = try dependencies.replaceItemAt(originalURL, replacementURL, backupName)

        #expect(backupURL == tempDirectory.appendingPathComponent(backupName, isDirectory: true))
        #expect(try String(contentsOf: originalURL.appendingPathComponent("payload.txt"), encoding: .utf8) == "replacement")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try String(contentsOf: backupURL.appendingPathComponent("payload.txt"), encoding: .utf8) == "original")
    }

    @Test func unrelatedOrUnversionableExistingDestinationIsNeverOverwritten() throws {
        let untrusted = FakePlacementRepairWorld()
        untrusted.installSource(build: 59, token: "source")
        untrusted.installCanonical(build: 58, token: "installed", trusted: false)

        let untrustedFailure = captureFailure {
            _ = try untrusted.service.repair(context: untrusted.context)
        }
        #expect(isExistingUntrusted(untrustedFailure))
        #expect(untrusted.record(at: untrusted.canonicalURL)?.token == "installed")
        #expect(untrusted.copyCount == 0)
        #expect(untrusted.launches.isEmpty)
        untrusted.expectSourceUntouched()
        untrusted.expectNoAttemptBytes()

        let unversionable = FakePlacementRepairWorld()
        unversionable.installSource(build: 59, token: "source")
        unversionable.installCanonical(version: nil, token: "installed")

        let unversionableFailure = captureFailure {
            _ = try unversionable.service.repair(context: unversionable.context)
        }
        #expect(isExistingUnversionable(unversionableFailure))
        #expect(unversionable.record(at: unversionable.canonicalURL)?.token == "installed")
        #expect(unversionable.copyCount == 0)
        #expect(unversionable.launches.isEmpty)
        unversionable.expectSourceUntouched()
        unversionable.expectNoAttemptBytes()
    }

    @Test func applicationsUnavailableOrUnwritableFailsBeforeCopying() throws {
        let unavailable = FakePlacementRepairWorld()
        unavailable.installSource(build: 59, token: "source")
        unavailable.installCanonical(build: 58, token: "installed")
        unavailable.applicationsDirectoryExists = false

        #expect(captureFailure {
            _ = try unavailable.service.repair(context: unavailable.context)
        } == .applicationsDirectoryUnavailable)
        #expect(unavailable.copyCount == 0)
        #expect(unavailable.record(at: unavailable.canonicalURL)?.token == "installed")
        unavailable.expectSourceUntouched()

        let unwritable = FakePlacementRepairWorld()
        unwritable.installSource(build: 59, token: "source")
        unwritable.installCanonical(build: 58, token: "installed")
        unwritable.applicationsWritable = false

        #expect(captureFailure {
            _ = try unwritable.service.repair(context: unwritable.context)
        } == .applicationsDirectoryUnwritable)
        #expect(unwritable.copyCount == 0)
        #expect(unwritable.record(at: unwritable.canonicalURL)?.token == "installed")
        unwritable.expectSourceUntouched()
    }

    @Test(arguments: InjectedRepairFailure.allCases)
    func replacementRollbackPreservesExistingDestination(failure: InjectedRepairFailure) throws {
        let world = FakePlacementRepairWorld()
        world.installSource(build: 59, token: "source")
        world.installCanonical(build: 58, token: "installed")
        world.inject(failure)

        let repairFailure = captureFailure {
            _ = try world.service.repair(context: world.context)
        }

        #expect(matchesInjectedFailure(repairFailure, failure))
        #expect(world.record(at: world.canonicalURL)?.token == "installed")
        #expect(world.launches.isEmpty)
        world.expectSourceUntouched()
        world.expectNoAttemptBytes()
    }

    @Test func freshInstallRollbackRemovesCanonicalOnMarkerOrSpawnFailure() throws {
        for failure in [InjectedRepairFailure.marker, InjectedRepairFailure.spawn] {
            let world = FakePlacementRepairWorld()
            world.installSource(build: 59, token: "source")
            world.inject(failure)

            let repairFailure = captureFailure {
                _ = try world.service.repair(context: world.context)
            }

            #expect(matchesInjectedFailure(repairFailure, failure))
            #expect(world.record(at: world.canonicalURL) == nil)
            world.expectSourceUntouched()
            world.expectNoAttemptBytes()
        }
    }

    private func captureFailure(_ body: () throws -> Void) -> AppPlacementRepairFailure? {
        do {
            try body()
            Issue.record("expected repair to fail")
            return nil
        } catch let failure as AppPlacementRepairFailure {
            return failure
        } catch {
            Issue.record("unexpected error: \(String(describing: error))")
            return nil
        }
    }

    private func isExistingUntrusted(_ failure: AppPlacementRepairFailure?) -> Bool {
        guard case .existingDestinationUntrusted = failure else { return false }
        return true
    }

    private func isExistingUnversionable(_ failure: AppPlacementRepairFailure?) -> Bool {
        guard case .existingDestinationUnversionable = failure else { return false }
        return true
    }

    private func matchesInjectedFailure(
        _ repairFailure: AppPlacementRepairFailure?,
        _ injectedFailure: InjectedRepairFailure
    ) -> Bool {
        switch (repairFailure, injectedFailure) {
        case (.copyFailed, .copy),
             (.trustFailed, .trust),
             (.quarantineClearFailed, .quarantine),
             (.atomicReplaceFailed, .replace),
             (.markerFailed, .marker),
             (.spawnFailed, .spawn):
            return true
        default:
            return false
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-placement-repair-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum InjectedRepairFailure: CaseIterable {
    case copy
    case trust
    case quarantine
    case replace
    case marker
    case spawn
}

private enum FakePlacementRepairError: Error {
    case copy
    case trust
    case quarantine
    case replace
    case marker
    case spawn
    case missingRecord
}

private struct FakeBundleRecord: Equatable {
    var token: String
    var trusted: Bool
    var version: SolstoneBundleVersion?
    var quarantined: Bool
}

private struct FakeMarkerCall: Equatable {
    let reason: String
    let pid: Int32
}

private final class FakePlacementRepairWorld {
    let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let sourceURL = URL(fileURLWithPath: "/Volumes/solstone/solstone.app", isDirectory: true)
    let pid: Int32 = 42_424
    var files: [String: FakeBundleRecord] = [:]
    var applicationsDirectoryExists = true
    var applicationsWritable = true
    var copyCount = 0
    var trustCheckedPaths: [String] = []
    var markers: [FakeMarkerCall] = []
    var launches: [URL] = []
    var failCopy = false
    var failTrust = false
    var failQuarantine = false
    var failReplace = false
    var failMarker = false
    var failSpawn = false
    private var uuidIndex = 0
    private let uuids = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    ]

    var canonicalURL: URL {
        applicationsURL.appendingPathComponent("solstone.app", isDirectory: true)
    }

    var context: AppPlacementContext {
        AppPlacementContext(
            runningBundleURL: sourceURL,
            canonicalBundleURL: canonicalURL,
            applicationsURL: applicationsURL,
            runningStandardizedURL: sourceURL.standardizedFileURL,
            runningResolvedURL: sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
            canonicalStandardizedURL: canonicalURL.standardizedFileURL,
            canonicalResolvedURL: canonicalURL.standardizedFileURL.resolvingSymlinksInPath(),
            pathLooksTranslocated: false
        )
    }

    var service: AppPlacementRepairService {
        AppPlacementRepairService(dependencies: dependencies)
    }

    var dependencies: AppPlacementRepairDependencies {
        AppPlacementRepairDependencies(
            applicationsURL: applicationsURL,
            processID: { [pid] in pid },
            uuid: { [self] in nextUUID() },
            directoryExists: { [self] url in
                url.path == applicationsURL.path && applicationsDirectoryExists
            },
            isWritableDirectory: { [self] url in
                url.path == applicationsURL.path && applicationsWritable
            },
            fileExists: { [self] url in
                files[url.path] != nil
            },
            removeItem: { [self] url in
                files[url.path] = nil
            },
            moveItem: { [self] source, destination in
                guard let record = files.removeValue(forKey: source.path) else {
                    throw FakePlacementRepairError.missingRecord
                }
                files[destination.path] = record
            },
            replaceItemAt: { [self] original, replacement, backupName in
                if failReplace { throw FakePlacementRepairError.replace }
                guard let originalRecord = files.removeValue(forKey: original.path),
                      let replacementRecord = files.removeValue(forKey: replacement.path)
                else {
                    throw FakePlacementRepairError.missingRecord
                }
                let backupURL = original
                    .deletingLastPathComponent()
                    .appendingPathComponent(backupName, isDirectory: true)
                files[backupURL.path] = originalRecord
                files[original.path] = replacementRecord
                return backupURL
            },
            restoreBackup: { [self] backupURL, destinationURL in
                guard let backupRecord = files.removeValue(forKey: backupURL.path) else {
                    throw FakePlacementRepairError.missingRecord
                }
                files[destinationURL.path] = backupRecord
            },
            copyBundle: { [self] source, destination in
                copyCount += 1
                guard let sourceRecord = files[source.path] else {
                    throw FakePlacementRepairError.missingRecord
                }
                files[destination.path] = sourceRecord
                if failCopy { throw FakePlacementRepairError.copy }
            },
            trustVerifier: { [self] url in
                trustCheckedPaths.append(url.path)
                if failTrust, url.path.contains(".solstone-placement-") {
                    throw FakePlacementRepairError.trust
                }
                guard files[url.path]?.trusted == true else {
                    throw FakePlacementRepairError.trust
                }
            },
            versionReader: { [self] url in
                guard let version = files[url.path]?.version else {
                    throw FakePlacementRepairError.missingRecord
                }
                return version
            },
            quarantineCleaner: { [self] url in
                if failQuarantine { throw FakePlacementRepairError.quarantine }
                guard var record = files[url.path] else {
                    throw FakePlacementRepairError.missingRecord
                }
                record.quarantined = false
                files[url.path] = record
            },
            markerWriter: { [self] reason, pid in
                if failMarker { throw FakePlacementRepairError.marker }
                markers.append(FakeMarkerCall(reason: reason, pid: pid))
                return ExpectedExitMarker(pid: pid, timestamp: Date(timeIntervalSinceReferenceDate: 1), reason: reason)
            },
            reopenLauncher: { [self] _, targetBundleURL in
                if failSpawn { throw FakePlacementRepairError.spawn }
                launches.append(targetBundleURL)
            },
            openApplicationsFolder: { _ in },
            logger: { _ in }
        )
    }

    func installSource(
        build: Int,
        token: String,
        trusted: Bool = true,
        quarantined: Bool = false
    ) {
        files[sourceURL.path] = FakeBundleRecord(
            token: token,
            trusted: trusted,
            version: SolstoneBundleVersion(shortVersion: "1.0.0", build: build),
            quarantined: quarantined
        )
    }

    func installCanonical(
        build: Int,
        token: String,
        trusted: Bool = true,
        quarantined: Bool = false
    ) {
        installCanonical(
            version: SolstoneBundleVersion(shortVersion: "1.0.0", build: build),
            token: token,
            trusted: trusted,
            quarantined: quarantined
        )
    }

    func installCanonical(
        version: SolstoneBundleVersion?,
        token: String,
        trusted: Bool = true,
        quarantined: Bool = false
    ) {
        files[canonicalURL.path] = FakeBundleRecord(
            token: token,
            trusted: trusted,
            version: version,
            quarantined: quarantined
        )
    }

    func inject(_ failure: InjectedRepairFailure) {
        switch failure {
        case .copy:
            failCopy = true
        case .trust:
            failTrust = true
        case .quarantine:
            failQuarantine = true
        case .replace:
            failReplace = true
        case .marker:
            failMarker = true
        case .spawn:
            failSpawn = true
        }
    }

    func record(at url: URL) -> FakeBundleRecord? {
        files[url.path]
    }

    func expectSourceUntouched() {
        #expect(files[sourceURL.path]?.token == "source")
    }

    func expectNoAttemptBytes() {
        #expect(!files.keys.contains { $0.contains(".solstone-placement-") })
    }

    private func nextUUID() -> UUID {
        defer { uuidIndex += 1 }
        return uuids[min(uuidIndex, uuids.count - 1)]
    }
}
