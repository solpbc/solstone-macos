// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("AppPlacementGate")
struct AppPlacementGateTests {
    @Test func userApplicationsPathIsAllowedWhenItIsNotCanonical() throws {
        let fixtureRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/solstone-placement-gate-tests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = fixtureRoot.appendingPathComponent("solstone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let decision = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: bundleURL,
            applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
        ))

        #expect(decision == .allowed(.stableLocation))
    }

    @Test func canonicalApplicationsPathIsAllowed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationsURL = root.appendingPathComponent("Applications", isDirectory: true)
        let canonicalURL = applicationsURL.appendingPathComponent("solstone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalURL, withIntermediateDirectories: true)

        let decision = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: canonicalURL,
            applicationsURL: applicationsURL
        ))

        #expect(decision == .allowed(.canonical))
    }

    @Test func unreadableVolumeFactsRequireRepair() {
        let decision = AppPlacementGate.evaluate(dependencies: AppPlacementGate.Dependencies(
            bundleURL: URL(fileURLWithPath: "/Volumes/does-not-exist/solstone.app", isDirectory: true),
            environment: [:]
        ))

        guard case .repair(let context) = decision else {
            Issue.record("expected repair")
            return
        }
        #expect(context.canonicalBundleURL.path == "/Applications/solstone.app")
    }

    @Test func appTranslocationStillRepairsAndLogsRawPath() {
        let logs = LockedArray<AppPlacementDiagnostic>([])
        let decision = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/zz/AppTranslocation/abc/d/solstone.app", isDirectory: true),
            applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true),
            log: { logs.append($0) }
        ))

        guard case .repair = decision else {
            Issue.record("expected repair")
            return
        }
        #expect(logs.all == [.appTranslocationPathObserved("/private/var/folders/zz/AppTranslocation/abc/d/solstone.app")])
    }

    @Test func symlinkAtApplicationsResolvesToCanonicalPlacement() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationsURL = root.appendingPathComponent("Applications", isDirectory: true)
        let externalURL = root.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("solstone.app", isDirectory: true)
        let canonicalURL = applicationsURL.appendingPathComponent("solstone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applicationsURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: canonicalURL, withDestinationURL: externalURL)

        let decision = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: canonicalURL,
            applicationsURL: applicationsURL
        ))

        #expect(decision == .allowed(.canonical))
    }

    @Test func runningThroughSymlinkResolvesToCanonicalPlacement() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationsURL = root.appendingPathComponent("Applications", isDirectory: true)
        let canonicalURL = applicationsURL.appendingPathComponent("solstone.app", isDirectory: true)
        let symlinkURL = root.appendingPathComponent("linked-solstone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: canonicalURL)

        let decision = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: symlinkURL,
            applicationsURL: applicationsURL
        ))

        #expect(decision == .allowed(.canonical))
    }

    @Test func everyEphemeralRootRequiresRepair() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cachesURL = root.appendingPathComponent("Caches", isDirectory: true)
        let temporaryURL = root.appendingPathComponent("Temporary", isDirectory: true)
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp/solstone-placement-gate-tests-\(UUID().uuidString)", isDirectory: true)
        let privateVarTemporaryRoot = URL(fileURLWithPath: "/private/var/tmp/solstone-placement-gate-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: privateTemporaryRoot)
            try? FileManager.default.removeItem(at: privateVarTemporaryRoot)
        }
        let fixtureURLs = [
            cachesURL.appendingPathComponent("nested/solstone.app", isDirectory: true),
            temporaryURL.appendingPathComponent("nested/solstone.app", isDirectory: true),
            privateTemporaryRoot.appendingPathComponent("solstone.app", isDirectory: true),
            privateVarTemporaryRoot.appendingPathComponent("solstone.app", isDirectory: true)
        ]

        for bundleURL in fixtureURLs {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            let decision = AppPlacementGate.evaluate(dependencies: dependencies(
                bundleURL: bundleURL,
                cachesURL: cachesURL,
                temporaryDirectoryURL: temporaryURL
            ))
            guard case .repair = decision else {
                Issue.record("expected repair for \(bundleURL.path)")
                continue
            }
        }
    }

    @Test func stablePathsAndRenamedBundlesAreAllowed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stableURL = root.appendingPathComponent("Downloads/solstone.app", isDirectory: true)
        let renamedURL = root.appendingPathComponent("Downloads/renamed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stableURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: renamedURL, withIntermediateDirectories: true)

        for bundleURL in [stableURL, renamedURL] {
            #expect(AppPlacementGate.evaluate(dependencies: dependencies(bundleURL: bundleURL)) == .allowed(.stableLocation))
        }
    }

    @Test func missingOrNegativeVolumeFactsRequireRepair() throws {
        let stableURL = URL(fileURLWithPath: "/Users/test/Applications/solstone.app", isDirectory: true)
        let facts: [AppPlacementVolumeFacts?] = [
            nil,
            AppPlacementVolumeFacts(isInternal: nil, isLocal: true),
            AppPlacementVolumeFacts(isInternal: true, isLocal: nil),
            AppPlacementVolumeFacts(isInternal: false, isLocal: true),
            AppPlacementVolumeFacts(isInternal: true, isLocal: false)
        ]

        for fact in facts {
            let decision = AppPlacementGate.evaluate(dependencies: dependencies(
                bundleURL: stableURL,
                volumeFacts: { _ in fact }
            ))
            guard case .repair = decision else {
                Issue.record("expected repair for \(String(describing: fact))")
                continue
            }
        }
    }

    @Test func userCachesDefaultRepairsAndInjectedDifferentRootAllows() throws {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleURL = cachesURL
            .appendingPathComponent("solstone-placement-gate-tests-\(UUID().uuidString)/solstone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let defaultDecision = AppPlacementGate.evaluate(dependencies: AppPlacementGate.Dependencies(
            bundleURL: bundleURL,
            environment: [:]
        ))
        guard case .repair = defaultDecision else {
            Issue.record("expected repair under the user caches root")
            return
        }

        let allowedDecision = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: bundleURL,
            cachesURL: URL(fileURLWithPath: "/different/Caches", isDirectory: true),
            temporaryDirectoryURL: URL(fileURLWithPath: "/different/Temporary", isDirectory: true)
        ))
        #expect(allowedDecision == .allowed(.stableLocation))
    }

    @Test func injectedPositiveVolumeFactsAllowOtherwiseUnreadableLocation() {
        let bundleURL = URL(fileURLWithPath: "/Volumes/does-not-exist/solstone.app", isDirectory: true)
        let decision = AppPlacementGate.evaluate(dependencies: AppPlacementGate.Dependencies(
            bundleURL: bundleURL,
            environment: [:],
            volumeFacts: { _ in AppPlacementVolumeFacts(isInternal: true, isLocal: true) }
        ))

        #expect(decision == .allowed(.stableLocation))
    }

    @Test func developerBypassIsExplicitEnvironmentOnly() {
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let bundleURL = URL(fileURLWithPath: "/tmp/build/solstone.app", isDirectory: true)

        let bypass = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: bundleURL,
            environment: ["SOLSTONE_DEV_LAUNCH": "1"],
            applicationsURL: applicationsURL
        ))
        let noBypass = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: bundleURL,
            environment: ["SOLSTONE_DEV_LAUNCH": "true"],
            applicationsURL: applicationsURL
        ))

        #expect(bypass == .allowed(.developerBypass))
        guard case .repair = noBypass else {
            Issue.record("expected repair without exact dev launch opt-in")
            return
        }
    }

    @Test func lockedAlertCopyIsStable() {
        #expect(AppPlacementAlertCopy.repairTitle == "install sol in Applications")
        #expect(AppPlacementAlertCopy.repairBody == "sol is running from a location it might not find again next launch, so macOS may not remember its screen recording permission. install sol in Applications, a reliable spot, and it will reopen.")
        #expect(AppPlacementAlertCopy.repairPrimaryButton == "install and reopen")
        #expect(AppPlacementAlertCopy.repairSecondaryButton == "quit sol")
        #expect(AppPlacementAlertCopy.fallbackTitle == "sol couldn't move itself")
        #expect(AppPlacementAlertCopy.fallbackBody == "move solstone.app to Applications in Finder, then open it there.")
        #expect(AppPlacementAlertCopy.fallbackPrimaryButton == "open Applications")
        #expect(AppPlacementAlertCopy.fallbackSecondaryButton == "quit sol")
    }

    private func dependencies(
        bundleURL: URL,
        environment: [String: String] = [:],
        applicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        cachesURL: URL = URL(fileURLWithPath: "/different/Caches", isDirectory: true),
        temporaryDirectoryURL: URL = URL(fileURLWithPath: "/different/Temporary", isDirectory: true),
        volumeFacts: @escaping (URL) -> AppPlacementVolumeFacts? = { _ in
            AppPlacementVolumeFacts(isInternal: true, isLocal: true)
        },
        log: @escaping (AppPlacementDiagnostic) -> Void = { _ in }
    ) -> AppPlacementGate.Dependencies {
        AppPlacementGate.Dependencies(
            bundleURL: bundleURL,
            environment: environment,
            applicationsURL: applicationsURL,
            cachesURL: cachesURL,
            temporaryDirectoryURL: temporaryDirectoryURL,
            volumeFacts: volumeFacts,
            log: log
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-placement-gate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
