// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing
import UpdateKit
@testable import solstone

@Suite("AXID registry")
struct AXIDTests {
    @Test func enumerableIDsMatchGrammar() {
        for id in AXContract.enumerableIDs {
            #expect(matchesIDGrammar(id))
        }
    }

    @Test func idGrammarRejectsInvalidSegments() {
        #expect(!matchesIDGrammar("settings.ScreenRecording.state"))
        #expect(!matchesIDGrammar("settings.screen_recording.state"))
        #expect(!matchesIDGrammar("settings..state"))
        #expect(!matchesIDGrammar("settings.permissions.1screenRecording.state"))
    }

    @Test func enumerableIDsAreGloballyUnique() {
        #expect(Set(AXContract.enumerableIDs).count == AXContract.enumerableIDs.count)
    }

    @Test func journalMarkPairingIDsAreStable() {
        #expect(AXID.Settings.Service.pairingMarkConfirm == "settings.service.pairing.markConfirm")
        #expect(AXID.Settings.Service.pairingMarkMismatch == "settings.service.pairing.markMismatch")
        #expect(AXID.Settings.Service.pairingMismatchFreshLink == "settings.service.pairing.mismatchFreshLink")
        #expect(AXID.Settings.Service.pairingMismatchSupport == "settings.service.pairing.mismatchSupport")
    }

    @Test func journalClientPanelIDsAreStable() {
        #expect(AXID.Menubar.journalMigrationNeededButton == "menubar.status.journalMigrationNeeded")
        #expect(AXID.Settings.Service.journalNameState == "settings.service.journal.name.state")
        #expect(AXID.Settings.Service.journalMarkState == "settings.service.journal.mark.state")
        #expect(AXID.Settings.Service.journalConnectionState == "settings.service.journal.connection.state")
        #expect(AXID.Settings.Service.journalRelink == "settings.service.journal.relink")
        #expect(AXID.Settings.Service.localJournalDiscoveryState == "settings.service.localJournal.discovery.state")
        #expect(AXID.Settings.Service.localJournalConfirm == "settings.service.localJournal.confirm")
        #expect(AXID.Settings.Service.createJournalThisMac == "settings.service.journal.createThisMac")
        #expect(AXID.Settings.Service.createJournalState == "settings.service.journal.create.state")
        #expect(AXID.Settings.Service.pairJournalAnotherDevice == "settings.service.journal.pairAnotherDevice")
        #expect(AXID.Settings.Service.journalHandoffBanner == "settings.service.journal.handoff.banner")
        #expect(AXID.Settings.Service.journalHandoffStart == "settings.service.journal.handoff.start")
        #expect(AXID.Settings.Service.journalHandoffState == "settings.service.journal.handoff.state")
    }

    @Test func runtimeKeysArePrefixStableAndInjective() {
        let firstUID = "AppleHDAEngineInput:1B,0,1,0:1"
        let secondUID = "com.EXAMPLE.Device.2"
        #expect(AXID.Settings.Microphones.device(firstUID).hasPrefix("settings.microphones.priority.device."))
        #expect(AXID.Settings.Microphones.deviceToggle(firstUID).hasPrefix("settings.microphones.priority.toggle."))
        #expect(AXID.Settings.Microphones.deviceRemove(firstUID).hasPrefix("settings.microphones.priority.remove."))
        #expect(AXID.Settings.Microphones.device(firstUID) != AXID.Settings.Microphones.device(secondUID))
        #expect(AXID.Settings.Microphones.deviceToggle(firstUID) != AXID.Settings.Microphones.deviceToggle(secondUID))
        #expect(AXID.Settings.Microphones.deviceRemove(firstUID) != AXID.Settings.Microphones.deviceRemove(secondUID))

        let firstApp = "Safari.app"
        let secondApp = "com.EXAMPLE.Editor"
        #expect(AXID.Settings.Privacy.excludedApp(firstApp).hasPrefix("settings.privacy.excludedApps.app."))
        #expect(AXID.Settings.Privacy.excludedAppRemove(firstApp).hasPrefix("settings.privacy.excludedApps.remove."))
        #expect(AXID.Settings.Privacy.excludedApp(firstApp) != AXID.Settings.Privacy.excludedApp(secondApp))
        #expect(AXID.Settings.Privacy.excludedAppRemove(firstApp) != AXID.Settings.Privacy.excludedAppRemove(secondApp))

        let firstPattern = "Private Window"
        let secondPattern = "*secret.example"
        #expect(AXID.Settings.Privacy.titlePattern(firstPattern).hasPrefix("settings.privacy.titlePatterns.pattern."))
        #expect(AXID.Settings.Privacy.titlePatternRemove(firstPattern).hasPrefix("settings.privacy.titlePatterns.remove."))
        #expect(AXID.Settings.Privacy.titlePattern(firstPattern) != AXID.Settings.Privacy.titlePattern(secondPattern))
        #expect(AXID.Settings.Privacy.titlePatternRemove(firstPattern) != AXID.Settings.Privacy.titlePatternRemove(secondPattern))
    }

    @Test func enumTokensAreExactAndMatchTokenGrammar() {
        expectTokens(uploadStatusRepresentatives.map(\.axToken), UploadCoordinator.Status.axTokens)
        expectTokens(connectionTestStateRepresentatives.map(\.axToken), ConnectionTestState.axTokens)
        expectTokens(pairingFlowStateRepresentatives.map(\.axToken), PairingFlowState.axTokens)
        expectTokens(pairingFailureRepresentatives.map(\.axToken), PairingFailure.axTokens)
        expectTokens(updateActivityRepresentatives.map(\.axToken), UpdateActivity.axTokens)

        expectTokensMatchGrammar(SettingsView.SidebarBadgeState.allCases.map(\.axToken))
        expectTokensMatchGrammar(AXPermissionState.allCases.map(\.axToken))
        expectTokensMatchGrammar(MenubarIconState.allCases.map(\.axToken))
        expectTokensMatchGrammar(MenubarStatusRowState.allCases.map(\.axToken))
        expectTokensMatchGrammar(SettingsObservationAXState.allCases.map(\.axToken))
        expectTokensMatchGrammar(PairingConnectionAXState.allCases.map(\.axToken))
        expectTokensMatchGrammar(PairingRelayAccessAXState.allCases.map(\.axToken))
        expectTokensMatchGrammar(JournalHandoffAXState.allCases.map(\.axToken))
        expectTokensMatchGrammar(FreshJournalAXState.allCases.map(\.axToken))
    }

    @Test func menubarIconStateOwnsIconNames() {
        #expect(MenubarIconState.recording.iconName == "sol-ring-template")
        #expect(MenubarIconState.offline.iconName == "sol-ring-icon-half-template")
        #expect(MenubarIconState.paused.iconName == "sol-ring-icon-paused-template")
        #expect(MenubarIconState.error.iconName == "sol-ring-icon-error-template")
    }

    @Test func numericValueHelpersPublishRawIntegers() {
        #expect(axIntegerString(42) == "42")
        #expect(axPercentString(-0.5) == "0")
        #expect(axPercentString(0.5) == "50")
        #expect(axPercentString(1.5) == "100")
        #expect(axDownloadPercentString(receivedBytes: 25, totalBytes: 100) == "25")
        #expect(axDownloadPercentString(receivedBytes: 25, totalBytes: nil) == "0")
    }

    @Test func viewsDoNotUseInlineIdentifierOrValueLiterals() throws {
        let root = URL(fileURLWithPath: "Sources/solstone", isDirectory: true)
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)!
        var matches: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "AXID.swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for pattern in forbiddenLiteralPatterns where containsForbiddenAccessibilityLiteral(in: source, pattern: pattern) {
                matches.append("\(url.path): \(pattern)")
            }
        }

        #expect(matches.isEmpty)
    }

    @Test func literalGuardPatternsCatchExpectedViolations() {
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityIdentifier("foo")"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityIdentifier ( "foo" )"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityValue("ok")"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityValue ( "ok" )"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityValue(Text("ok"))"#))
        #expect(containsForbiddenAccessibilityLiteral(in: #".accessibilityValue ( Text ( "ok" ) )"#))
        #expect(!containsForbiddenAccessibilityLiteral(in: ".accessibilityIdentifier(AXID.Settings.Status.uploadState)"))
        #expect(!containsForbiddenAccessibilityLiteral(in: ".accessibilityValue(status.axToken)"))
    }

    private func expectTokens(_ tokens: [String], _ expected: [String]) {
        #expect(tokens == expected)
        expectTokensMatchGrammar(tokens)
    }

    private func expectTokensMatchGrammar(_ tokens: [String]) {
        for token in tokens {
            #expect(token.range(of: AXContract.tokenPattern, options: .regularExpression) != nil)
        }
    }

    private func matchesIDGrammar(_ id: String) -> Bool {
        id.range(of: AXContract.idPattern, options: .regularExpression) != nil
    }

    private var forbiddenLiteralPatterns: [String] {
        [
            #"\.accessibilityIdentifier\s*\(\s*""#,
            #"\.accessibilityValue\s*\(\s*""#,
            #"\.accessibilityValue\s*\(\s*Text\s*\(\s*""#
        ]
    }

    private func containsForbiddenAccessibilityLiteral(in source: String) -> Bool {
        forbiddenLiteralPatterns.contains { containsForbiddenAccessibilityLiteral(in: source, pattern: $0) }
    }

    private func containsForbiddenAccessibilityLiteral(in source: String, pattern: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    // Associated-value representatives are the one hand-maintained AX token surface.
    private var uploadStatusRepresentatives: [UploadCoordinator.Status] {
        [
            .notSynced,
            .syncing(checked: 1, total: 2),
            .synced,
            .uploading(segment: "segment"),
            .retrying(segment: "segment", attempts: 2),
            .awaitingTunnel,
            .offline("offline")
        ]
    }

    private var connectionTestStateRepresentatives: [ConnectionTestState] {
        [
            .idle,
            .testing,
            .success,
            .failure("boom")
        ]
    }

    private var pairingFlowStateRepresentatives: [PairingFlowState] {
        [
            .idle,
            .pairing,
            .switchConfirmPending(newInstanceID: "instance-2"),
            .paired,
            .alreadyConnected,
            .switched,
            .saveFailed,
            .failed(.network)
        ]
    }

    private var pairingFailureRepresentatives: [PairingFailure] {
        [
            .staleLink,
            .homeUnreachable,
            .relayUnauthorized,
            .instanceMismatch,
            .network,
            .invalidLink("bad"),
            .localSetup
        ]
    }

    private var updateActivityRepresentatives: [UpdateActivity] {
        [
            .idle,
            .checking,
            .downloading(version: "1.0.0", receivedBytes: 1, totalBytes: 2),
            .extracting(version: "1.0.0", progress: 0.5),
            .readyToInstall(version: "1.0.0", releaseNotes: nil),
            .installing(version: "1.0.0")
        ]
    }

}
