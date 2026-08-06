// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
@testable import SolstoneCore
@testable import solstone_watchdog

@Suite("Watchdog identity and eligibility", .serialized)
struct WatchdogIdentityEligibilityTests {
    @Test func criterion1JournalBundleWithEmptyEnvironmentResolvesJournalRow() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, named: "journal.app", bundleIdentifier: "app.solstone.journal")
        let savedEnvironment = legacyWatchdogEnvironment()
        defer { restoreLegacyWatchdogEnvironment(savedEnvironment) }
        unsetLegacyWatchdogEnvironment()

        guard case .resolved(let identity) = resolve(app.executableURL, root: root) else {
            Issue.record("expected journal identity resolution")
            return
        }

        #expect(identity.product.targetBundleID == "app.solstone.journal")
        #expect(identity.product.loggerSubsystem == "app.solstone.journal.watchdog")
        #expect(identity.product.markerDiscriminator == ExpectedExitMarker.journalMarkerDiscriminator)
    }

    @Test func criterion2ObserverBundleWithEmptyEnvironmentResolvesObserverRow() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, named: "observer.app", bundleIdentifier: "app.solstone.observer")
        let savedEnvironment = legacyWatchdogEnvironment()
        defer { restoreLegacyWatchdogEnvironment(savedEnvironment) }
        unsetLegacyWatchdogEnvironment()

        guard case .resolved(let identity) = resolve(app.executableURL, root: root) else {
            Issue.record("expected observer identity resolution")
            return
        }

        #expect(identity.product.targetBundleID == "app.solstone.observer")
        #expect(identity.product.loggerSubsystem == "app.solstone.observer.watchdog")
        #expect(identity.product.markerDiscriminator == ExpectedExitMarker.solMarkerDiscriminator)
    }

    @Test func criterion5ProductIdentityIsAtomic() {
        #expect(WatchdogProduct(enclosingBundleIdentifier: "app.solstone.observer") == .observer)
        #expect(WatchdogProduct(enclosingBundleIdentifier: "app.solstone.journal") == .journal)
        #expect(WatchdogProduct(enclosingBundleIdentifier: "com.example.other") == nil)
        #expect(WatchdogProduct.observer.markerDiscriminator == ExpectedExitMarker.solMarkerDiscriminator)
        #expect(WatchdogProduct.journal.markerDiscriminator == ExpectedExitMarker.journalMarkerDiscriminator)
    }

    @Test func criterion3LegacyEnvironmentCannotOverrideEnclosingObserverIdentity() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, named: "observer.app", bundleIdentifier: "app.solstone.observer")
        let savedEnvironment = legacyWatchdogEnvironment()
        defer { restoreLegacyWatchdogEnvironment(savedEnvironment) }
        unsetLegacyWatchdogEnvironment()
        // These keys survive only as inert plist entries; no Swift code reads them. Mutate them solely to prove identity resolution ignores them.
        setenv("SOLSTONE_WATCHDOG_TARGET_BUNDLE_ID", "app.solstone.journal", 1)
        setenv("SOLSTONE_WATCHDOG_LOGGER_SUBSYSTEM", "app.solstone.journal.watchdog", 1)
        setenv("SOLSTONE_WATCHDOG_MARKER_DISCRIMINATOR", "SolstoneJournal", 1)

        let result = resolve(app.executableURL, root: root)

        #expect(result == .resolved(WatchdogIdentity(
            product: .observer,
            enclosingBundleURL: app.bundleURL,
            enclosingBundleIdentifier: "app.solstone.observer",
            writerExecutableURL: app.executableURL
        )))
    }

    @Test func criterion8UnsupportedBundleIdentifierIsPermanentRefusal() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, named: "other.app", bundleIdentifier: "com.example.other")

        guard case .permanentRefusal(let refusal) = resolve(app.executableURL, root: root) else {
            Issue.record("expected permanent refusal")
            return
        }
        #expect(refusal.cause == .unsupportedBundleIdentifier)
        #expect(refusal.enclosingBundleIdentifier == "com.example.other")
    }

    @Test func criterion4UnrecognizedOrUnreadableNeverDefaultsToObserver() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrecognized = try makeApp(at: root, named: "other.app", bundleIdentifier: "com.example.other")
        let unreadable = root.appendingPathComponent("missing.app/Contents/MacOS/solstone-watchdog")
        try FileManager.default.createDirectory(at: unreadable.deletingLastPathComponent(), withIntermediateDirectories: true)

        #expect(resolvedProduct(resolve(unrecognized.executableURL, root: root)) != .observer)
        #expect(resolvedProduct(resolve(unreadable, root: root)) != .observer)
    }

    @Test func criterion14TransientInfoPlistFailuresAreDistinct() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.app/Contents/MacOS/solstone-watchdog")
        try FileManager.default.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = try makeApp(at: root, named: "malformed.app", bundleIdentifier: nil)

        guard case .transientRefusal(let missingRefusal) = resolve(missing, root: root),
              case .transientRefusal(let malformedRefusal) = resolve(malformed.executableURL, root: root) else {
            Issue.record("expected transient refusals")
            return
        }
        #expect(missingRefusal.cause == .infoPlistUnreadable)
        #expect(malformedRefusal.cause == .infoPlistMalformed)
    }

    @Test func criterion14NonLocalVolumeIsTransient() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, named: "observer.app", bundleIdentifier: "app.solstone.observer")

        guard case .transientRefusal(let refusal) = WatchdogIdentityResolver.resolve(
            writerExecutableURL: app.executableURL,
            cachesURL: root.appendingPathComponent("Caches", isDirectory: true),
            temporaryDirectoryURL: root.appendingPathComponent("Temporary", isDirectory: true),
            volumeIsLocal: { _ in false }
        ) else {
            Issue.record("expected transient refusal")
            return
        }
        #expect(refusal.cause == .nonLocalVolume)
    }

    @Test func criterion9CommonInstalledLocationsAreEligible() {
        let caches = URL(fileURLWithPath: "/Users/test/Library/Caches", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/var/folders/test/T", isDirectory: true)
        let paths = [
            "/Applications/solstone.app",
            "/Users/test/Applications/solstone.app",
            "/Applications/sol-renamed.app",
            "/Library/Managed Applications/solstone.app"
        ]

        for path in paths {
            #expect(WatchdogAppLocationEligibility.isEligible(
                enclosingAppURL: URL(fileURLWithPath: path, isDirectory: true),
                cachesURL: caches,
                temporaryDirectoryURL: temporary
            ))
        }
    }

    @Test func criterion10CachesPrefixSiblingIsEligibleOnDisk() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
        let sibling = root.appendingPathComponent("Library/CachesFoo/x.app", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        #expect(WatchdogAppLocationEligibility.isEligible(
            enclosingAppURL: sibling,
            cachesURL: caches,
            temporaryDirectoryURL: root.appendingPathComponent("Temporary", isDirectory: true)
        ))
    }

    @Test func criterion10SymlinkedContainerAncestorIsIneligibleOnDisk() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual/Caches", isDirectory: true)
        let link = root.appendingPathComponent("linked-caches", isDirectory: true)
        let app = actual.appendingPathComponent("nested/solstone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        let appThroughLink = link.appendingPathComponent("nested/solstone.app", isDirectory: true)

        #expect(!WatchdogAppLocationEligibility.isEligible(
            enclosingAppURL: appThroughLink,
            cachesURL: actual,
            temporaryDirectoryURL: root.appendingPathComponent("Temporary", isDirectory: true)
        ))
    }

    @Test func criterion10FirmlinkNormalizationIsDirect() {
        let dataPath = URL(fileURLWithPath: "/System/Volumes/Data/Users/jer/Library/Caches", isDirectory: true)
        #expect(WatchdogAppLocationEligibility.normalized(dataPath).path == "/Users/jer/Library/Caches")
    }

    @Test func criterion11TemporaryAndTranslocationComponentsAreIneligible() {
        let temporary = URL(fileURLWithPath: "/var/folders/test/T", isDirectory: true)
        #expect(!WatchdogAppLocationEligibility.isEligible(
            enclosingAppURL: temporary.appendingPathComponent("build/solstone.app", isDirectory: true),
            cachesURL: URL(fileURLWithPath: "/Users/test/Library/Caches", isDirectory: true),
            temporaryDirectoryURL: temporary
        ))
        #expect(!WatchdogAppLocationEligibility.isEligible(
            enclosingAppURL: URL(fileURLWithPath: "/Volumes/shared/AppTranslocation/id/d/solstone.app", isDirectory: true),
            cachesURL: URL(fileURLWithPath: "/Users/test/Library/Caches", isDirectory: true),
            temporaryDirectoryURL: temporary
        ))
    }

    @Test func criterion16And17AdoptionRequiresAllTerms() {
        let owner = URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true)
        let adopted = watchdogAdoptionDecision(product: .observer, ownerBundleURL: owner, candidates: [
            WatchdogRunningCandidate(bundleIdentifier: "app.solstone.observer", processIdentifier: 41, bundleURL: owner)
        ])
        let missingURL = watchdogAdoptionDecision(product: .observer, ownerBundleURL: owner, candidates: [
            WatchdogRunningCandidate(bundleIdentifier: "app.solstone.observer", processIdentifier: 41, bundleURL: nil)
        ])

        #expect(adopted == .adopt(pid: 41))
        #expect(missingURL == .conflictingCopy(bundleURL: nil, shortVersion: nil, buildVersion: nil))
    }

    @Test func criterion18ConflictingCopyCarriesRawVersionFields() {
        let decision = watchdogAdoptionDecision(
            product: .observer,
            ownerBundleURL: URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true),
            candidates: [WatchdogRunningCandidate(
                bundleIdentifier: "app.solstone.observer",
                processIdentifier: 41,
                bundleURL: URL(fileURLWithPath: "/Applications/copy.app", isDirectory: true),
                shortVersion: "1.2.3",
                buildVersion: "44"
            )]
        )

        #expect(decision == .conflictingCopy(
            bundleURL: URL(fileURLWithPath: "/Applications/copy.app", isDirectory: true),
            shortVersion: "1.2.3",
            buildVersion: "44"
        ))
    }

    @Test func criterion19PathNormalizationMatchesEquivalentURLs() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("Applications/solstone.app", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Applications", isDirectory: true))
        let owner = actual
        let throughLink = link.appendingPathComponent("solstone.app", isDirectory: true)
        let dotDot = root.appendingPathComponent("Applications/unused/../solstone.app", isDirectory: true)
        let trailingSlash = URL(fileURLWithPath: owner.path + "/", isDirectory: true)

        #expect(WatchdogAppLocationEligibility.normalized(owner) == WatchdogAppLocationEligibility.normalized(throughLink))
        #expect(WatchdogAppLocationEligibility.normalized(owner) == WatchdogAppLocationEligibility.normalized(dotDot))
        #expect(WatchdogAppLocationEligibility.normalized(owner) == WatchdogAppLocationEligibility.normalized(trailingSlash))
        #expect(WatchdogAppLocationEligibility.normalized(owner) != WatchdogAppLocationEligibility.normalized(root.appendingPathComponent("other.app", isDirectory: true)))
    }

    @Test func criterion21And22RecordsRemainAttributablePerBundle() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundle = root.appendingPathComponent("first.app", isDirectory: true)
        let secondBundle = root.appendingPathComponent("second.app", isDirectory: true)
        let first = WatchdogStateRecord(
            cause: .ineligibleLocation,
            enclosingBundleURL: firstBundle,
            enclosingBundleIdentifier: "app.solstone.observer",
            writerExecutableURL: firstBundle.appendingPathComponent("Contents/MacOS/solstone-watchdog")
        )
        let second = WatchdogStateRecord(
            cause: .ineligibleLocation,
            enclosingBundleURL: secondBundle,
            enclosingBundleIdentifier: "app.solstone.journal",
            writerExecutableURL: secondBundle.appendingPathComponent("Contents/MacOS/solstone-watchdog")
        )
        try WatchdogStateRecordStore.write(first, applicationSupportBaseURL: root)
        try WatchdogStateRecordStore.write(second, applicationSupportBaseURL: root)
        let firstURL = WatchdogStateRecordStore.fileURL(for: first, applicationSupportBaseURL: root)
        let secondURL = WatchdogStateRecordStore.fileURL(for: second, applicationSupportBaseURL: root)

        #expect(firstURL != secondURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        let decodedFirst = try JSONDecoder().decode(WatchdogStateRecord.self, from: Data(contentsOf: firstURL))
        let decodedSecond = try JSONDecoder().decode(WatchdogStateRecord.self, from: Data(contentsOf: secondURL))
        #expect(decodedFirst.cause == first.cause)
        #expect(decodedFirst.enclosingBundleURL == first.enclosingBundleURL)
        #expect(decodedFirst.enclosingBundleIdentifier == first.enclosingBundleIdentifier)
        #expect(decodedFirst.writerExecutableURL == first.writerExecutableURL)
        #expect(decodedSecond.cause == second.cause)
        #expect(decodedSecond.enclosingBundleURL == second.enclosingBundleURL)
        #expect(decodedSecond.enclosingBundleIdentifier == second.enclosingBundleIdentifier)
        #expect(decodedSecond.writerExecutableURL == second.writerExecutableURL)
    }

    @Test @MainActor func criterion12PermanentRefusalTerminatesBeforePollScheduling() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let app = try makeApp(at: caches, named: "observer.app", bundleIdentifier: "app.solstone.observer")
        let statuses = LockedArray<Int32>([])
        let pollCalls = LockedArray<Bool>([])
        var dependencies = watchdogDependencies(writerExecutableURL: app.executableURL)
        dependencies.cachesURL = { caches }
        dependencies.temporaryDirectoryURL = { root.appendingPathComponent("Temporary", isDirectory: true) }
        dependencies.terminator = { statuses.append($0) }
        dependencies.schedulePollTimer = { _ in
            pollCalls.append(true)
            return Timer(timeInterval: 1, repeats: false) { _ in }
        }
        let coordinator = WatchdogCoordinator(dependencies: dependencies)

        _ = coordinator.start()

        #expect(statuses.all == [0])
        #expect(pollCalls.all.isEmpty)
    }

    @Test @MainActor func criterion13UnrecognizedIdentifierTerminatesBeforePollScheduling() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, named: "other.app", bundleIdentifier: "com.example.other")
        let statuses = LockedArray<Int32>([])
        let pollCalls = LockedArray<Bool>([])
        var dependencies = watchdogDependencies(writerExecutableURL: app.executableURL)
        dependencies.cachesURL = { root.appendingPathComponent("Caches", isDirectory: true) }
        dependencies.temporaryDirectoryURL = { root.appendingPathComponent("Temporary", isDirectory: true) }
        dependencies.terminator = { statuses.append($0) }
        dependencies.schedulePollTimer = { _ in
            pollCalls.append(true)
            return Timer(timeInterval: 1, repeats: false) { _ in }
        }
        let coordinator = WatchdogCoordinator(dependencies: dependencies)

        _ = coordinator.start()

        #expect(statuses.all == [0])
        #expect(pollCalls.all.isEmpty)
    }

    @Test @MainActor func criterion15RecordWriteFailureKeepsPermanentDisposition() {
        let statuses = LockedArray<Int32>([])
        let faults = LockedArray<String>([])
        var dependencies = watchdogDependencies(writerExecutableURL: URL(fileURLWithPath: "/usr/local/bin/solstone-watchdog"))
        dependencies.writeStateRecord = { _ in throw TestError.writeFailed }
        dependencies.logBootstrapFault = { faults.append($0) }
        dependencies.terminator = { statuses.append($0) }
        let coordinator = WatchdogCoordinator(dependencies: dependencies)

        _ = coordinator.start()

        #expect(statuses.all == [0])
        #expect(faults.all.count == 1)
        #expect(faults.all[0].contains("no-enclosing-app"))
    }

    @Test @MainActor func criterion18And20ConflictingStartupDoesNotLaunchOverCopy() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root, named: "observer.app", bundleIdentifier: "app.solstone.observer")
        let launches = LockedArray<Bool>([])
        let records = LockedArray<WatchdogStateRecord>([])
        let polls = LockedArray<Bool>([])
        var dependencies = watchdogDependencies(writerExecutableURL: app.executableURL)
        dependencies.cachesURL = { root.appendingPathComponent("Caches", isDirectory: true) }
        dependencies.temporaryDirectoryURL = { root.appendingPathComponent("Temporary", isDirectory: true) }
        dependencies.runningCandidates = {
            [WatchdogRunningCandidate(
                bundleIdentifier: "app.solstone.observer",
                processIdentifier: 77,
                bundleURL: root.appendingPathComponent("other.app", isDirectory: true),
                shortVersion: "1.0",
                buildVersion: "7"
            )]
        }
        dependencies.openApplication = { _, _ in launches.append(true) }
        dependencies.writeStateRecord = { records.append($0) }
        dependencies.schedulePollTimer = { _ in
            polls.append(true)
            return Timer(timeInterval: 1, repeats: false) { _ in }
        }
        let coordinator = WatchdogCoordinator(dependencies: dependencies)

        #expect(coordinator.start() == .polling)
        #expect(launches.all.isEmpty)
        #expect(polls.all == [true])
        #expect(records.all.count == 1)
        #expect(records.all[0].cause == .conflictingCopy)
        #expect(records.all[0].conflictingBundleURL == root.appendingPathComponent("other.app", isDirectory: true))
        #expect(records.all[0].conflictingBundleShortVersion == "1.0")
        #expect(records.all[0].conflictingBundleBuild == "7")
    }

    @Test func criterion6And7SourceScansPinCleanBreak() throws {
        let root = repositoryRoot()
        let sourceURLs = swiftFiles(under: root.appendingPathComponent("Sources"))
        let legacyKeys = [
            "SOLSTONE_WATCHDOG_TARGET_BUNDLE_ID",
            "SOLSTONE_WATCHDOG_LOGGER_SUBSYSTEM",
            "SOLSTONE_WATCHDOG_MARKER_DISCRIMINATOR"
        ]
        let swiftContents = try sourceURLs.map { try String(contentsOf: $0, encoding: .utf8) }

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/SolstoneCore/WatchdogConfiguration.swift").path))
        #expect(!swiftContents.contains { content in legacyKeys.contains { content.contains($0) } })
        let identitySources = ["WatchdogIdentity.swift", "WatchdogBundleInfo.swift", "WatchdogProduct.swift"]
        for name in identitySources {
            let content = try String(contentsOf: root.appendingPathComponent("Sources/SolstoneCore/\(name)"), encoding: .utf8)
            #expect(!content.contains("ProcessInfo.processInfo.environment"))
        }
    }

    @Test func criterion11And25SourceScansPinImplementationBoundaries() throws {
        let root = repositoryRoot()
        let sources = swiftFiles(under: root.appendingPathComponent("Sources"))
        for url in sources where url.path != root.appendingPathComponent("Sources/solstone/AppPlacementGate.swift").path {
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(!content.contains("/private/var/folders/"))
            #expect(!content.contains("/var/folders/"))
            #expect(!content.contains("$TMPDIR"))
        }
        let watchdogURLs = swiftFiles(under: root.appendingPathComponent("Sources/solstone-watchdog"))
            + swiftFiles(under: root.appendingPathComponent("Sources/SolstoneCore")).filter { $0.lastPathComponent.hasPrefix("Watchdog") }
        for url in watchdogURLs {
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(!content.contains("terminate("))
            #expect(!content.contains("forceTerminate("))
            #expect(!content.contains("kill("))
            #expect(!content.contains("SIGTERM"))
        }
    }

    private func resolve(_ executableURL: URL, root: URL) -> WatchdogIdentityResolution {
        WatchdogIdentityResolver.resolve(
            writerExecutableURL: executableURL,
            cachesURL: root.appendingPathComponent("Caches", isDirectory: true),
            temporaryDirectoryURL: root.appendingPathComponent("Temporary", isDirectory: true),
            volumeIsLocal: { _ in true }
        )
    }
}

private enum TestError: Error { case writeFailed }

private let legacyWatchdogEnvironmentKeys = [
    "SOLSTONE_WATCHDOG_TARGET_BUNDLE_ID",
    "SOLSTONE_WATCHDOG_LOGGER_SUBSYSTEM",
    "SOLSTONE_WATCHDOG_MARKER_DISCRIMINATOR"
]

private func legacyWatchdogEnvironment() -> [String: String] {
    Dictionary(uniqueKeysWithValues: legacyWatchdogEnvironmentKeys.compactMap { key in
        getenv(key).map { (key, String(cString: $0)) }
    })
}

private func unsetLegacyWatchdogEnvironment() {
    for key in legacyWatchdogEnvironmentKeys {
        unsetenv(key)
    }
}

private func restoreLegacyWatchdogEnvironment(_ environment: [String: String]) {
    unsetLegacyWatchdogEnvironment()
    for (key, value) in environment {
        setenv(key, value, 1)
    }
}

private func resolvedProduct(_ resolution: WatchdogIdentityResolution) -> WatchdogProduct? {
    guard case .resolved(let identity) = resolution else { return nil }
    return identity.product
}

@MainActor
private func watchdogDependencies(writerExecutableURL: URL) -> WatchdogCoordinator.Dependencies {
    WatchdogCoordinator.Dependencies(
        writerExecutableURL: { writerExecutableURL },
        cachesURL: { URL(fileURLWithPath: "/Users/test/Library/Caches", isDirectory: true) },
        temporaryDirectoryURL: { URL(fileURLWithPath: "/var/folders/test/T", isDirectory: true) },
        volumeIsLocal: { _ in true },
        runningCandidates: { [] },
        openApplication: { _, _ in },
        writeStateRecord: { _ in },
        logBootstrapFault: { _ in },
        terminator: { _ in },
        schedulePollTimer: { _ in Timer(timeInterval: 1, repeats: false) { _ in } }
    )
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-identity-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeApp(at root: URL, named name: String, bundleIdentifier: String?) throws -> (bundleURL: URL, executableURL: URL) {
    let bundleURL = root.appendingPathComponent(name, isDirectory: true)
    let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/solstone-watchdog")
    try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var plist: [String: Any] = ["CFBundleExecutable": "solstone-watchdog"]
    if let bundleIdentifier { plist["CFBundleIdentifier"] = bundleIdentifier }
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    return (bundleURL, executableURL)
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func swiftFiles(under directory: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
}
