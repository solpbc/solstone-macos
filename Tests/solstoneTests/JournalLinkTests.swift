// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

@Suite("Journal links")
@MainActor
struct JournalLinkTests {
    private let token = "AZ_DXxmbV9s6MBxO_kTc9Fj2UaJ4a9IqvsmpKuk6fZ6r5i9R7sSEJdl4qzuMUg~090020"

    @Test func preservesOriginalBytesAndChecksOnlyTheGrammar() {
        for value in [token, "a", "a~256199", String(repeating: "_", count: 512),
                      String(repeating: "_", count: 512) + "~235959"] {
            for address in ["solstone://open", "solstone://open/", "https://go.solstone.app/j"] {
                #expect(JournalLink(address + "#" + value) == .destination(
                    JournalWindowDestination(path: "/app/open/" + value)!
                ))
            }
        }
    }

    @Test func rejectsMalformedLinksWithoutRepairingThem() {
        for value in ["", "a~0900", "a~090020~090021", "a~", "~090020", "a%2Db", "a/b",
                      "a#b", "a=", "é", "a~٠٩٠٠٢٠", String(repeating: "A", count: 513)] {
            #expect(JournalLink("solstone://open#" + value) == .invalid)
        }
        for address in ["solstone://open", "solstone://open?x=1#a", "solstone://open/extra#a",
                        "solstone://user@open#a", "solstone://open:80#a"] {
            #expect(JournalLink(address) == .invalid)
        }
        #expect(JournalLink("solstone://pair#a") == .unrelated)
        #expect(JournalLink("https://go.solstone.app/p#a") == .unrelated)
        #expect(JournalLink("") == .unrelated)
    }

    @Test func pairedSameMacAndRemoteLinksUseTheWindowAndRepeatWithANewIntent() {
        for held in [pairing(), pairing(localEndpoints: [LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")])] {
            let state = AppState.forSnapshot(initialTunnelPairing: held)
            state.handleIngressURLString("solstone://open#" + token)
            let first = state.journalOpenIntent
            #expect(first?.destination.path == "/app/open/" + token)
            #expect(state.pendingPairingLinkError == nil)
            #expect(state.currentDurablePairing == held)
            state.handleIngressURLString("solstone://open#" + token)
            #expect(state.journalOpenIntent?.id != first?.id)
            #expect(state.journalOpenIntent?.destination == first?.destination)
        }
    }

    @Test func malformedLinkIsANoticeAndLeavesPairingUntouched() {
        let state = AppState.forSnapshot()
        var notices = 0
        state.showInvalidJournalLinkNotice = { notices += 1 }
        state.pendingPairingLink = "existing pairing draft"
        state.handleIngressURLString("solstone://open#bad~0900")
        #expect(notices == 1)
        #expect(state.pendingPairingLink == "existing pairing draft")
        #expect(state.pendingPairingLinkError == nil)
        #expect(state.journalOpenIntent == nil)
    }

    @Test func savedSameMacAddressWithoutPairingUsesOneTimeBrowserLinkAtThePath() async {
        let probe = BrowserProbe()
        let state = AppState.forSnapshot(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: ""),
            journalURLOpener: { url in probe.url = url; return true }
        )
        let oneTime = URL(string: "http://localhost:15915/?auth=one-time")!
        state.sameMacBrowserLink = { path, _ in probe.target = path; return oneTime }
        state.handleIngressURLString("solstone://open#" + token)
        for _ in 0..<100 where probe.url == nil { await Task.yield() }
        #expect(probe.target == "/app/open/" + token)
        #expect(probe.url == oneTime)
        #expect(state.journalOpenIntent == nil)
    }

    @Test func repeatOpenReloadsAndRetryKeepsTheSealedPath() async {
        let destination = JournalWindowDestination(path: "/app/open/" + token)!
        let session = JournalWindowSession(resolveHomeBase: { .url("http://localhost:45678") })
        let first = await session.open(destination: destination)!
        #expect(first.url.absoluteString == "http://localhost:45678/app/open/" + token)
        session.handle(.finished(generation: first.generation))
        let repeated = await session.open(destination: destination)!
        #expect(repeated.generation > first.generation)
        #expect(repeated.url == first.url)
        session.handle(.failed(generation: repeated.generation, failure: .other))
        let retried = await session.retry()
        #expect(retried?.url == first.url)
        #expect(retried!.generation > repeated.generation)
    }

    @Test func explicitRepeatOpenReloadsEvenWhenAnExistingPageCouldRecoverWithoutALoad() {
        let destination = JournalWindowDestination(path: "/app/open/" + token)!
        var composition = JournalWindowComposition()
        let first = composition.open(destination: destination, resolvedBase: .url("http://localhost:45678"))!
        composition.noteMainFrameCommit(committedURL: first.url)
        composition.handle(.finished(generation: first.generation))
        _ = composition.reload(resolvedBase: .held)
        #expect(composition.state == .linkDown)

        let repeated = composition.open(destination: destination, resolvedBase: .url("http://localhost:45678"))
        #expect(repeated?.url == first.url)
        #expect(repeated!.generation > first.generation)
        #expect(composition.state == .loading)
    }
}

@MainActor
private final class BrowserProbe: @unchecked Sendable {
    var target: String?
    var url: URL?
}
