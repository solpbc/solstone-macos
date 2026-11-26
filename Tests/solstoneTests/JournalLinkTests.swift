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
            for address in [
                "solstone://open",
                "solstone://open/",
                "https://go.solstone.app/j",
                "https://go.solstone.app/j?utm_source=chatgpt.com",
                "https://go.solstone.app/j?",
            ] {
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
            #expect(JournalLink("https://go.solstone.app/j#" + value) == .invalid)
            #expect(JournalLink("https://go.solstone.app/j?utm_source=chatgpt.com#" + value) == .invalid)
        }
        for address in [
            "solstone://open",
            "solstone://open?x=1#a",
            "solstone://open/?x=1#a",
            "solstone://open?#a",
            "solstone://open/extra#a",
            "solstone://open//#a",
            "solstone://user@open#a",
            "solstone://open:80#a",
            "https://go.solstone.app/j",
            "https://go.solstone.app/j?utm_source=chatgpt.com",
            "https://go.solstone.app/j/#a",
            "https://go.solstone.app/j/extra#a",
            "https://go.solstone.app/%6a#a",
            "https://go.solstone.app:443/j#a",
            "https://user@go.solstone.app/j#a",
        ] {
            #expect(JournalLink(address) == .invalid)
        }
        #expect(JournalLink("solstone://pair#a") == .unrelated)
        #expect(JournalLink("https://go.solstone.app/p#a") == .unrelated)
        #expect(JournalLink("https://go.solstone.app/journal#a") == .unrelated)
        #expect(JournalLink("http://go.solstone.app/j#a") == .unrelated)
        #expect(JournalLink("https://example.com/j#a") == .unrelated)
        #expect(JournalLink("") == .unrelated)
    }

    @Test func universalLinkUserActivityRoutesValidAndQueryJournalLinksAndQueuesColdLaunch() throws {
        let delegate = AppDelegate()
        let state = AppState.forSnapshot(initialTunnelPairing: pairing())

        // Cold-launch arrival before AppState.shared exists queues and returns true.
        let coldActivity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        coldActivity.webpageURL = URL(string: "https://go.solstone.app/j?utm_source=chatgpt.com#" + token)
        #expect(delegate.handleIncomingUserActivity(coldActivity, state: nil))
        #expect(state.journalOpenIntent == nil)

        delegate.drainPendingExternalIngress(into: state)
        let first = try #require(state.journalOpenIntent)
        #expect(first.destination.path == "/app/open/" + token)
        #expect(state.pendingJournalWindowOpen)
        #expect(state.pendingPairingLink == nil)
        #expect(state.pendingPairingLinkError == nil)

        // Routing the journal window clears the cold-launch pending flag.
        var openedWindowID: String?
        routeOpenJournalWindow(
            appState: state,
            openWindow: { openedWindowID = $0 },
            bringFront: {},
            activate: {}
        )
        #expect(openedWindowID == SolstoneSceneID.journal.rawValue)
        #expect(!state.pendingJournalWindowOpen)

        // Warm universal link updates the intent directly.
        let warmActivity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        warmActivity.webpageURL = URL(string: "https://go.solstone.app/j#" + token)
        #expect(delegate.handleIncomingUserActivity(warmActivity, state: state))
        #expect(state.journalOpenIntent?.id != first.id)
        #expect(state.journalOpenIntent?.destination == first.destination)
    }

    @Test func universalLinkUserActivityIgnoresNonJournalLinksWithoutTouchingPairing() throws {
        let delegate = AppDelegate()
        let state = AppState.forSnapshot()
        var notices = 0
        state.showInvalidJournalLinkNotice = { notices += 1 }

        for raw in [
            "https://go.solstone.app/p#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00",
            "https://go.solstone.app/",
            "https://example.com/j#" + token,
            "http://go.solstone.app/j#" + token,
        ] {
            let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            activity.webpageURL = URL(string: raw)
            #expect(!delegate.handleIncomingUserActivity(activity, state: state))
        }

        // Custom-scheme URLs are refused on the universal-link path (they belong on open(_:)).
        #expect(!state.handleJournalUniversalLinkURL(try #require(URL(string: "solstone://open#" + token))))

        let missingURL = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        #expect(!delegate.handleIncomingUserActivity(missingURL, state: state))

        let otherType = NSUserActivity(activityType: "app.solstone.observer.unrelated")
        otherType.webpageURL = URL(string: "https://go.solstone.app/j#" + token)
        #expect(!delegate.handleIncomingUserActivity(otherType, state: state))

        #expect(notices == 0)
        #expect(state.journalOpenIntent == nil)
        #expect(state.pendingPairingLink == nil)
        #expect(state.pendingPairingLinkError == nil)

        // Malformed /j universal link surfaces the shared notice and leaves pairing untouched.
        let malformed = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        malformed.webpageURL = URL(string: "https://go.solstone.app/j#bad~0900")
        #expect(delegate.handleIncomingUserActivity(malformed, state: state))
        #expect(notices == 1)
        #expect(state.pendingPairingLink == nil)
        #expect(state.pendingPairingLinkError == nil)
        #expect(state.journalOpenIntent == nil)
    }

    @Test func appEntitlementsClaimGoSolstoneAssociatedDomainAndHelpersDoNot() throws {
        let appEntitlements = try loadEntitlementsPlist(relativePath: "Sources/solstone/entitlements-app.plist")
        let domains = try #require(appEntitlements["com.apple.developer.associated-domains"] as? [String])
        #expect(domains == ["applinks:go.solstone.app"])

        let helperEntitlements = try loadEntitlementsPlist(relativePath: "Sources/solstone/entitlements.plist")
        #expect(helperEntitlements["com.apple.developer.associated-domains"] == nil)
    }

    @Test func embeddedProvisioningProfileAuthorizesAssociatedDomainsAndKeychain() throws {
        let profileData = try loadRepoData(relativePath: "Sources/solstone/embedded.provisionprofile")
        let startMarker = Data("<?xml".utf8)
        let endMarker = Data("</plist>".utf8)
        let start = try #require(profileData.range(of: startMarker))
        let end = try #require(profileData.range(of: endMarker))
        let xmlData = profileData.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try #require(PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil) as? [String: Any])
        #expect(plist["ProvisionsAllDevices"] as? Bool == true)
        let entitlements = try #require(plist["Entitlements"] as? [String: Any])
        #expect(entitlements["com.apple.application-identifier"] as? String == "7QCG8V4M6H.app.solstone.observer")
        #expect(entitlements["com.apple.developer.associated-domains"] as? String == "*")
        let groups = try #require(entitlements["keychain-access-groups"] as? [String])
        #expect(groups.contains("7QCG8V4M6H.*"))
    }

    private func loadRepoData(relativePath: String) throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            directory.deleteLastPathComponent()
        }
        Issue.record("missing file \(relativePath)")
        return Data()
    }

    private func loadEntitlementsPlist(relativePath: String) throws -> [String: Any] {
        let data = try loadRepoData(relativePath: relativePath)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(plist as? [String: Any])
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
