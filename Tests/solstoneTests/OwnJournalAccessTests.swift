// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalLocalAccess
import JournalMarkKit
import Testing
@testable import solstone

private struct ConfigReader: SolstoneUserConfigReading {
    let raw: String?
    func readConfigToml() async -> String? { raw }
}

@Suite("The journal on this Mac is checked before it is used")
struct OwnJournalAccessTests {
    @Test func rootsComeFromConfigHomeAndTheSavedPath() async {
        let roots = await OwnJournalAccess.ownJournalRoots(
            configReader: ConfigReader(raw: #"journal = "/Volumes/Mine/journal""#),
            savedPath: "/Users/owner/elsewhere"
        )
        #expect(roots.first == "/Volumes/Mine/journal")
        #expect(roots.last == "/Users/owner/elsewhere")
        #expect(roots.count == 3)
    }

    @Test(arguments: [JournalLocalHTTPError.notOwnJournal, .refused])
    func aRefusedAnswerIsNeverReadAsAbsent(error: JournalLocalHTTPError) {
        #expect(OwnJournalAccess.identityResolution(for: error) == .failed(.instanceMismatch))
    }

    @Test func nothingListeningIsAbsent() {
        #expect(OwnJournalAccess.identityResolution(for: URLError(.cannotConnectToHost)) == .absent)
        #expect(OwnJournalAccess.identityResolution(for: JournalLocalHTTPError.unavailable) == .absent)
    }

    @MainActor
    @Test func discoveryNeverOffersAnotherAccountsJournal() async {
        var onDiskAsked = false
        let model = await discoverLocalJournalPanelModel(
            fetchIdentity: { _ in .failed(.instanceMismatch) },
            onDiskDiscovery: { onDiskAsked = true; return .found(path: "/Users/owner/journal") }
        )
        #expect(model == .notOwnJournal)
        #expect(!onDiskAsked)
    }

    @Test func thePlainMessageClearsOnceNothingElseAnswers() {
        #expect(reprobedLocalJournalPanelModel(current: .notOwnJournal, probeResult: .none) == .none)
        #expect(reprobedLocalJournalPanelModel(current: .none, probeResult: .notOwnJournal) == .notOwnJournal)
    }

    @Test func aRefusedPairStartSaysSoPlainly() {
        let outcome = sameMachineLinkOutcome(for: .failed(.pairStart(.notOwnJournal)), failedAddress: nil)
        #expect(outcome.message == UICopy.LOCAL_JOURNAL_NOT_YOURS)
        #expect(!outcome.offersPairingLink)
        #expect(outcome.evidence == .pairingSameMachineNotOwnJournal)
    }

    @Test func aPairStartLoaderRefusalNeverPairs() async {
        let client = SameMachinePairStartClient(loader: { _ in throw JournalLocalHTTPError.notOwnJournal })
        let result = await client.start(baseURL: "http://localhost", deviceLabel: "test mac")
        guard case .failure(let failure) = result else {
            Issue.record("expected a refusal")
            return
        }
        #expect(failure.kind == .notOwnJournal)
    }

    @Test func aSavedAddressIsTheBundledJournalOnItsOwnPortNotOnlyTheDefault() {
        #expect(BundledJournalEndpoint.isBundledServiceURL("http://localhost:15915", runtimePort: 15915))
        #expect(BundledJournalEndpoint.isBundledServiceURL("http://127.0.0.1:5015", runtimePort: 15915))
        #expect(BundledJournalEndpoint.isBundledServiceURL("http://127.0.0.1:5015", runtimePort: nil))
        #expect(!BundledJournalEndpoint.isBundledServiceURL("http://localhost:15915", runtimePort: nil))
        #expect(!BundledJournalEndpoint.isBundledServiceURL("http://journal.local:15915", runtimePort: 15915))
    }

    @MainActor
    @Test func refusalsWordedForTheOwner() {
        #expect(AppState.sameMacOpenRefusal(for: JournalLocalHTTPError.notOwnJournal) == UICopy.LOCAL_JOURNAL_NOT_YOURS)
        #expect(AppState.sameMacOpenRefusal(for: URLError(.cannotConnectToHost)) == UICopy.SAME_MACHINE_LINK_UNREACHABLE)
    }
}
