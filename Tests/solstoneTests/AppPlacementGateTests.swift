// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("AppPlacementGate")
struct AppPlacementGateTests {
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

    @Test func nonApplicationsPathsRequireRepair() {
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let decision = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: URL(fileURLWithPath: "/Volumes/solstone/solstone.app", isDirectory: true),
            applicationsURL: applicationsURL
        ))

        guard case .repair(let context) = decision else {
            Issue.record("expected repair")
            return
        }
        #expect(context.canonicalBundleURL.path == "/Applications/solstone.app")
    }

    @Test func appTranslocationSegmentIsDiagnosticOnlyAndStillRepairs() {
        let logs = LockedArray<AppPlacementDiagnostic>([])
        let decision = AppPlacementGate.evaluate(dependencies: dependencies(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/zz/AppTranslocation/abc/d/solstone.app", isDirectory: true),
            applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true),
            log: { logs.append($0) }
        ))

        guard case .repair(let context) = decision else {
            Issue.record("expected repair")
            return
        }
        #expect(context.pathLooksTranslocated)
        #expect(logs.all == [.appTranslocationPathObserved("/private/var/folders/zz/AppTranslocation/abc/d/solstone.app")])
    }

    @Test func symlinkAtApplicationsDoesNotEarnPlacement() throws {
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

        guard case .repair(let context) = decision else {
            Issue.record("expected repair")
            return
        }
        #expect(context.canonicalStandardizedURL.path != context.canonicalResolvedURL.path)
    }

    @Test func runningThroughSymlinkDoesNotEarnPlacement() throws {
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

        guard case .repair(let context) = decision else {
            Issue.record("expected repair")
            return
        }
        #expect(context.runningResolvedURL.path == context.canonicalResolvedURL.path)
        #expect(context.runningStandardizedURL.path != context.canonicalStandardizedURL.path)
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
        #expect(AppPlacementAlertCopy.repairBody == "macOS is running sol from a temporary location, so it can't remember screen recording permission. install sol in Applications and it will reopen.")
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
        applicationsURL: URL,
        log: @escaping (AppPlacementDiagnostic) -> Void = { _ in }
    ) -> AppPlacementGate.Dependencies {
        AppPlacementGate.Dependencies(
            bundleURL: bundleURL,
            environment: environment,
            applicationsURL: applicationsURL,
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
