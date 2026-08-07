// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin
import Testing
import SolstoneCore
@testable import solstone

@Suite("AppPlacementRepair")
struct AppPlacementRepairTests {
    private static let quarantineAttributeName = "com.apple.quarantine"
    private static let unrelatedAttributeName = "com.solstone.test.unrelated"

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

    @Test func liveReplaceAndRestoreBackupPreservesOriginalForRollback() throws {
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

        try dependencies.restoreBackup(backupURL, originalURL)

        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        #expect(try String(contentsOf: originalURL.appendingPathComponent("payload.txt"), encoding: .utf8) == "original")
    }

    @Test func liveQuarantineCleanerClearsRootDirectoryFileAndSymlinkOnly() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let rootURL = tempDirectory.appendingPathComponent("solstone.app", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("Contents", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("payload.txt")
        let outsideTargetURL = tempDirectory.appendingPathComponent("outside-target.txt")
        let symlinkURL = directoryURL.appendingPathComponent("outside-link")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "payload".write(to: fileURL, atomically: true, encoding: .utf8)
        try "outside".write(to: outsideTargetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideTargetURL)

        let nodes: [(url: URL, label: String)] = [
            (rootURL, "root"),
            (directoryURL, "directory"),
            (fileURL, "file"),
            (symlinkURL, "symlink")
        ]
        let expectedUnrelatedValues = Dictionary(
            uniqueKeysWithValues: nodes.map { node in
                (node.url, Data("unrelated-\(node.label)".utf8))
            }
        )

        for node in nodes {
            try setExtendedAttribute(
                Self.quarantineAttributeName,
                value: Data("quarantine-\(node.label)".utf8),
                at: node.url
            )
            try setExtendedAttribute(
                Self.unrelatedAttributeName,
                value: expectedUnrelatedValues[node.url]!,
                at: node.url
            )
        }

        let outsideQuarantineValue = Data("outside-quarantine".utf8)
        let outsideUnrelatedValue = Data("outside-unrelated".utf8)
        try setExtendedAttribute(Self.quarantineAttributeName, value: outsideQuarantineValue, at: outsideTargetURL)
        try setExtendedAttribute(Self.unrelatedAttributeName, value: outsideUnrelatedValue, at: outsideTargetURL)

        try LivePlacementQuarantineCleaner.clearRecursively(at: rootURL, fileManager: .default)

        for node in nodes {
            #expect(try extendedAttributeValue(Self.quarantineAttributeName, at: node.url) == nil)
            #expect(try extendedAttributeValue(Self.unrelatedAttributeName, at: node.url) == expectedUnrelatedValues[node.url])
        }
        #expect(try extendedAttributeValue(Self.quarantineAttributeName, at: outsideTargetURL) == outsideQuarantineValue)
        #expect(try extendedAttributeValue(Self.unrelatedAttributeName, at: outsideTargetURL) == outsideUnrelatedValue)
    }

    @Test func liveQuarantineCleanerClearsDescendantWhenRootIsClean() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let rootURL = tempDirectory.appendingPathComponent("solstone.app", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("Contents", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("payload.txt")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "payload".write(to: fileURL, atomically: true, encoding: .utf8)
        try setExtendedAttribute(Self.quarantineAttributeName, value: Data("descendant-quarantine".utf8), at: fileURL)

        try LivePlacementQuarantineCleaner.clearRecursively(at: rootURL, fileManager: .default)

        #expect(try extendedAttributeValue(Self.quarantineAttributeName, at: rootURL) == nil)
        #expect(try extendedAttributeValue(Self.quarantineAttributeName, at: fileURL) == nil)
    }

    @Test func liveQuarantineCleanerIsIdempotentWhenTreeIsClean() throws {
        let tempDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let rootURL = tempDirectory.appendingPathComponent("solstone.app", isDirectory: true)
        let directoryURL = rootURL.appendingPathComponent("Contents", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("payload.txt")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "payload".write(to: fileURL, atomically: true, encoding: .utf8)
        let unrelatedValue = Data("kept-clean".utf8)
        try setExtendedAttribute(Self.unrelatedAttributeName, value: unrelatedValue, at: fileURL)

        try LivePlacementQuarantineCleaner.clearRecursively(at: rootURL, fileManager: .default)
        try LivePlacementQuarantineCleaner.clearRecursively(at: rootURL, fileManager: .default)

        #expect(try extendedAttributeValue(Self.quarantineAttributeName, at: rootURL) == nil)
        #expect(try extendedAttributeValue(Self.quarantineAttributeName, at: directoryURL) == nil)
        #expect(try extendedAttributeValue(Self.quarantineAttributeName, at: fileURL) == nil)
        #expect(try extendedAttributeValue(Self.unrelatedAttributeName, at: fileURL) == unrelatedValue)
    }

    @Test func injectedNonENOATTRRemovalFailureMapsToQuarantineClearFailed() throws {
        let world = FakePlacementRepairWorld()
        world.installSource(build: 59, token: "source")
        world.installCanonical(build: 58, token: "installed")
        var dependencies = world.dependencies
        dependencies.quarantineCleaner = { url in
            try LivePlacementQuarantineCleaner.clearRecursively(
                at: url,
                fileManager: .default,
                removeQuarantine: { _ in throw InjectedQuarantineCleanerError.removal },
                makeEnumerator: { _, _, _ in nil }
            )
        }

        let repairFailure = captureFailure {
            _ = try AppPlacementRepairService(dependencies: dependencies).repair(context: world.context)
        }

        #expect(isQuarantineClearFailed(repairFailure))
        #expect(world.record(at: world.canonicalURL)?.token == "installed")
        #expect(world.launches.isEmpty)
        world.expectSourceUntouched()
        world.expectNoAttemptBytes()
    }

    @Test func injectedTraversalFailureMapsToQuarantineClearFailed() throws {
        let world = FakePlacementRepairWorld()
        world.installSource(build: 59, token: "source")
        world.installCanonical(build: 58, token: "installed")
        var dependencies = world.dependencies
        dependencies.quarantineCleaner = { url in
            try LivePlacementQuarantineCleaner.clearRecursively(
                at: url,
                fileManager: .default,
                removeQuarantine: { _ in },
                makeEnumerator: { _, _, errorHandler in
                    _ = errorHandler(url, InjectedQuarantineCleanerError.traversal)
                    return nil
                }
            )
        }

        let repairFailure = captureFailure {
            _ = try AppPlacementRepairService(dependencies: dependencies).repair(context: world.context)
        }

        #expect(isQuarantineClearFailed(repairFailure))
        #expect(world.record(at: world.canonicalURL)?.token == "installed")
        #expect(world.launches.isEmpty)
        world.expectSourceUntouched()
        world.expectNoAttemptBytes()
    }

    @Test func injectedNilEnumeratorWithoutHandlerMapsToQuarantineClearFailed() throws {
        let world = FakePlacementRepairWorld()
        world.installSource(build: 59, token: "source")
        world.installCanonical(build: 58, token: "installed")
        var dependencies = world.dependencies
        dependencies.quarantineCleaner = { url in
            try LivePlacementQuarantineCleaner.clearRecursively(
                at: url,
                fileManager: .default,
                removeQuarantine: { _ in },
                makeEnumerator: { _, _, _ in nil }
            )
        }

        let repairFailure = captureFailure {
            _ = try AppPlacementRepairService(dependencies: dependencies).repair(context: world.context)
        }

        #expect(isQuarantineClearFailed(repairFailure))
        #expect(world.record(at: world.canonicalURL)?.token == "installed")
        #expect(world.launches.isEmpty)
        world.expectSourceUntouched()
        world.expectNoAttemptBytes()
    }

    @Test func terminalPlanCoversRepairChoices() {
        #expect(AppPlacementRepairTerminal.plan(userChoseInstall: false, repairSucceeded: false) == .quitWithoutRepair)
        #expect(AppPlacementRepairTerminal.plan(userChoseInstall: false, repairSucceeded: true) == .quitWithoutRepair)
        #expect(AppPlacementRepairTerminal.plan(userChoseInstall: true, repairSucceeded: true) == .exitSuccess)
        #expect(AppPlacementRepairTerminal.plan(userChoseInstall: true, repairSucceeded: false) == .presentFallback)
    }

    @Test func terminalPlanMapsMarkerAndSpawnFailureToFallback() {
        for failure in [InjectedRepairFailure.marker, InjectedRepairFailure.spawn] {
            let world = FakePlacementRepairWorld()
            world.installSource(build: 59, token: "source")
            world.installCanonical(build: 58, token: "installed")
            world.inject(failure)

            let repairSucceeded = (try? world.service.repair(context: world.context)) != nil

            #expect(!repairSucceeded)
            #expect(AppPlacementRepairTerminal.plan(userChoseInstall: true, repairSucceeded: repairSucceeded) == .presentFallback)
        }
    }

    @Test @MainActor func terminalResolveQuitDoesNotRunRepairAndMarksFallbackExit() {
        let world = FakePlacementRepairWorld()
        var events: [String] = []
        var runRepairCount = 0
        var fallbackAlertCount = 0
        var openApplicationsCount = 0

        let action = AppPlacementRepairTerminal.resolve(
            context: world.context,
            dependencies: AppPlacementRepairTerminalDependencies(
                activate: { events.append("activate") },
                presentRepairAlert: {
                    events.append("repairAlert")
                    return false
                },
                runRepair: { context in
                    runRepairCount += 1
                    return (try? world.service.repair(context: context)) != nil
                },
                presentFallbackAlert: {
                    fallbackAlertCount += 1
                    events.append("fallbackAlert")
                    return true
                },
                openApplicationsFolder: { _ in
                    openApplicationsCount += 1
                    events.append("openApplications")
                },
                markFallbackExit: {
                    events.append("markFallbackExit")
                }
            )
        )

        #expect(action == .quitWithoutRepair)
        #expect(runRepairCount == 0)
        #expect(fallbackAlertCount == 0)
        #expect(openApplicationsCount == 0)
        #expect(world.markers.isEmpty)
        #expect(world.launches.isEmpty)
        #expect(world.copyCount == 0)
        #expect(events == ["activate", "repairAlert", "markFallbackExit"])
    }

    @Test @MainActor func terminalResolveInstallFailurePresentsFallbackOnce() {
        for userChoseOpenApplications in [false, true] {
            let world = FakePlacementRepairWorld()
            world.applicationsDirectoryExists = false
            var events: [String] = []
            var runRepairCount = 0
            var fallbackAlertCount = 0
            var openApplicationsCount = 0

            let action = AppPlacementRepairTerminal.resolve(
                context: world.context,
                dependencies: AppPlacementRepairTerminalDependencies(
                    activate: { events.append("activate") },
                    presentRepairAlert: {
                        events.append("repairAlert")
                        return true
                    },
                    runRepair: { context in
                        runRepairCount += 1
                        events.append("runRepair")
                        return (try? world.service.repair(context: context)) != nil
                    },
                    presentFallbackAlert: {
                        fallbackAlertCount += 1
                        events.append("fallbackAlert")
                        return userChoseOpenApplications
                    },
                    openApplicationsFolder: { _ in
                        openApplicationsCount += 1
                        events.append("openApplications")
                    },
                    markFallbackExit: {
                        events.append("markFallbackExit")
                    }
                )
            )

            #expect(action == .presentFallback)
            #expect(action != .exitSuccess)
            #expect(runRepairCount == 1)
            #expect(fallbackAlertCount == 1)
            #expect(openApplicationsCount == (userChoseOpenApplications ? 1 : 0))
            #expect(world.markers.isEmpty)
            #expect(world.launches.isEmpty)
            #expect(world.copyCount == 0)
            if userChoseOpenApplications {
                #expect(events == ["activate", "repairAlert", "runRepair", "fallbackAlert", "openApplications", "markFallbackExit"])
            } else {
                #expect(events == ["activate", "repairAlert", "runRepair", "fallbackAlert", "markFallbackExit"])
            }
        }
    }

    @Test @MainActor func terminalResolveInstallSuccessReturnsExitSuccessWithoutFallback() {
        let world = FakePlacementRepairWorld()
        var events: [String] = []
        var fallbackAlertCount = 0
        var openApplicationsCount = 0
        var markFallbackExitCount = 0

        let action = AppPlacementRepairTerminal.resolve(
            context: world.context,
            dependencies: AppPlacementRepairTerminalDependencies(
                activate: { events.append("activate") },
                presentRepairAlert: {
                    events.append("repairAlert")
                    return true
                },
                runRepair: { _ in
                    events.append("runRepair")
                    return true
                },
                presentFallbackAlert: {
                    fallbackAlertCount += 1
                    events.append("fallbackAlert")
                    return true
                },
                openApplicationsFolder: { _ in
                    openApplicationsCount += 1
                    events.append("openApplications")
                },
                markFallbackExit: {
                    markFallbackExitCount += 1
                    events.append("markFallbackExit")
                }
            )
        )

        #expect(action == .exitSuccess)
        #expect(fallbackAlertCount == 0)
        #expect(openApplicationsCount == 0)
        #expect(markFallbackExitCount == 0)
        #expect(events == ["activate", "repairAlert", "runRepair"])
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

    private func isQuarantineClearFailed(_ failure: AppPlacementRepairFailure?) -> Bool {
        guard case .quarantineClearFailed = failure else { return false }
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

    private func setExtendedAttribute(_ name: String, value: Data, at url: URL) throws {
        try value.withUnsafeBytes { buffer in
            let result = url.path.withCString { fileSystemPath in
                name.withCString { attributeName in
                    setxattr(fileSystemPath, attributeName, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
                }
            }
            if result != 0 {
                throw posixError(errno, url: url)
            }
        }
    }

    private func extendedAttributeValue(_ name: String, at url: URL) throws -> Data? {
        let length = url.path.withCString { fileSystemPath in
            name.withCString { attributeName in
                getxattr(fileSystemPath, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }

        if length < 0 {
            let errorCode = errno
            if errorCode == ENOATTR {
                return nil
            }
            throw posixError(errorCode, url: url)
        }

        var value = Data(count: length)
        let readLength = value.withUnsafeMutableBytes { buffer in
            url.path.withCString { fileSystemPath in
                name.withCString { attributeName in
                    getxattr(fileSystemPath, attributeName, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
                }
            }
        }

        if readLength < 0 {
            let errorCode = errno
            if errorCode == ENOATTR {
                return nil
            }
            throw posixError(errorCode, url: url)
        }

        return readLength == length ? value : Data(value.prefix(readLength))
    }

    private func posixError(_ code: Int32, url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: url.path]
        )
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

private enum InjectedQuarantineCleanerError: Error {
    case removal
    case traversal
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
            applicationsURL: applicationsURL
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
