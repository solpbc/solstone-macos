// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Testing
@testable import UpdateKit
@testable import solstone

@Suite("AXContract", .serialized)
@MainActor
struct AXContractTests {
    private let contractPath = "ax-contract.json"
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
    private let isolatedDefaults = IsolatedUserDefaults()

    @Test func contractMatchesCommittedFileOrRegenerates() throws {
        let generated = AXContract.generate()
        if ProcessInfo.processInfo.environment["AX_CONTRACT_REGEN"] == "1" {
            try generated.write(
                to: URL(fileURLWithPath: contractPath),
                atomically: true,
                encoding: .utf8
            )
            return
        }

        guard let committed = try? String(contentsOfFile: contractPath, encoding: .utf8) else {
            Issue.record("ax-contract.json is missing or unreadable; run `make ax-contract` and commit.")
            return
        }

        if committed != generated {
            Issue.record("ax-contract.json is stale vs the Swift SoT; run `make ax-contract` and commit.")
        }
        #expect(committed == generated)
    }

    @Test func generateIsIdempotent() {
        #expect(AXContract.generate() == AXContract.generate())
    }

    @Test func stateMapKeysMatchEnumerableStateIDs() {
        let actual = Set(AXContract.states.keys)
        let expected = AXContract.requiredStateKeys
        let missing = expected.subtracting(actual).sorted()
        let extra = actual.subtracting(expected).sorted()

        if !missing.isEmpty {
            Issue.record("missing state bindings: \(missing.joined(separator: ", "))")
        }
        if !extra.isEmpty {
            Issue.record("extra state bindings: \(extra.joined(separator: ", "))")
        }

        #expect(missing.isEmpty)
        #expect(extra.isEmpty)
    }

    @Test func staticAXIDLeavesAreRegisteredInContract() throws {
        let root = URL(fileURLWithPath: "Sources/solstone", isDirectory: true)
        let axidURL = root.appendingPathComponent("AXID.swift")
        let source = try String(contentsOf: axidURL, encoding: .utf8)
        let registered = Set(AXContract.enumerableIDs)
        let missing = staticAXIDLeaves(in: source)
            .filter { !registered.contains($0.literal) }

        if !missing.isEmpty {
            let message = missing
                .map { "\($0.literal) (\($0.name))" }
                .joined(separator: ", ")
            Issue.record("AXID static identifiers missing from AXContract.enumerableIDs: \(message)")
        }
        #expect(missing.isEmpty)
    }

    @Test func enumStateVocabulariesExist() {
        let vocabularyNames = Set(AXContract.vocabularies.keys)
        var missing: [String] = []

        for (stateID, binding) in AXContract.states where binding.kind == .enum {
            guard let vocabulary = binding.vocabulary else {
                missing.append("\(stateID): <nil>")
                continue
            }
            if !vocabularyNames.contains(vocabulary) {
                missing.append("\(stateID): \(vocabulary)")
            }
        }

        if !missing.isEmpty {
            Issue.record("missing vocabularies: \(missing.joined(separator: ", "))")
        }
        #expect(missing.isEmpty)
    }

    private func staticAXIDLeaves(in source: String) -> [(name: String, literal: String)] {
        let pattern = #"static\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let literalRange = Range(match.range(at: 2), in: source)
            else {
                return nil
            }
            let literal = String(source[literalRange])
            guard literal.range(of: AXContract.idPattern, options: .regularExpression) != nil else {
                return nil
            }
            return (name: String(source[nameRange]), literal: literal)
        }
    }

    @Test func updateStatusCompositeTokensAreBranchExhaustive() {
        clearUpdateDefaults()
        defer { clearUpdateDefaults() }

        let controller = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: isolatedDefaults.defaults
        ) { _, _ in AXContractStartedUpdater() }
        let failedArmController = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: isolatedDefaults.defaults
        ) { _, _ in nil }
        let now = Date()

        let emitted = [
            statusToken(controller, activity: .idle),
            statusToken(controller, activity: .checking),
            statusToken(controller, activity: .downloading(version: "1.3.9", receivedBytes: 1, totalBytes: 2)),
            statusToken(controller, activity: .extracting(version: "1.3.9", progress: 0.5)),
            statusToken(controller, activity: .readyToInstall(version: "1.3.9", releaseNotes: nil)),
            statusToken(controller, activity: .installing(version: "1.3.9")),
            statusToken(
                controller,
                activity: .idle,
                availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
                lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
                backgroundDownload: .downloading(version: "1.3.9")
            ),
            statusToken(
                controller,
                activity: .idle,
                deferredInstallIntent: DeferredInstallIntent(version: "1.3.9", requestedAt: now)
            ),
            statusToken(
                controller,
                activity: .idle,
                availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
                lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
            ),
            statusToken(
                controller,
                activity: .idle,
                lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .upToDate)
            ),
            statusToken(
                controller,
                activity: .idle,
                lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .failed)
            ),
            statusToken(
                controller,
                activity: .idle,
                availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
                lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .staged)
            ),
            statusToken(failedArmController, activity: .idle)
        ]

        #expect(emitted == UpdateStatus.axTokens)
        #expect(Set(emitted) == Set(UpdateStatus.axTokens))
    }

    private func statusToken(
        _ controller: UpdateController,
        activity: UpdateActivity,
        availableUpdate: AvailableUpdate? = nil,
        lastCheck: ReconciledUpdateStatus.LastCheck? = nil,
        deferredInstallIntent: DeferredInstallIntent? = nil,
        backgroundDownload: BackgroundDownloadPhase? = nil
    ) -> String {
        controller.applyDebugFixture(
            activity: activity,
            availableUpdate: availableUpdate,
            lastCheck: lastCheck,
            deferredInstallIntent: deferredInstallIntent,
            backgroundDownload: backgroundDownload
        )
        return controller.statusAXToken
    }

    private func clearUpdateDefaults() {
        isolatedDefaults.clear()
    }
}

@MainActor
private final class AXContractStartedUpdater: SparkleUpdating {
    var automaticallyChecksForUpdates = true
    var updateCheckInterval: TimeInterval = 86_400
    var automaticallyDownloadsUpdates = false
    var sessionInProgress = false

    func checkForUpdates() {}
    func start() throws {}
}
