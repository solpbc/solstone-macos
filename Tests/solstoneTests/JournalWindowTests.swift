// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
import WebKit
@testable import solstone

@Suite("JournalWindow Composition")
@MainActor
struct JournalWindowCompositionTests {
    @Test func loadUsesResolvedBaseNotPersistedServerURL() async {
        let state = AppState.forSnapshot(config: AppConfig(
            serverURL: "http://127.0.0.1:11111",
            serverKey: "key"
        ))
        state.requestOpenJournal(.root)
        let session = JournalWindowSession(resolveHomeBase: {
            .url("http://127.0.0.1:54321")
        })

        let command = await session.open(destination: state.journalOpenIntent!.destination)

        #expect(state.config.serverURL == "http://127.0.0.1:11111")
        #expect(command?.url.absoluteString == "http://127.0.0.1:54321/")
    }

    @Test func heldBaseKeepsDestinationWithoutLoadAfterOpeningWindowIntent() async {
        let state = AppState.forSnapshot()
        state.dockMode = .alwaysAccessory
        var openedWindowID: String?
        let destination = JournalWindowDestination(path: "/app/chat/2026-05-09", fragment: "event-2")!
        let session = JournalWindowSession(resolveHomeBase: { .held })
        let observer = NotificationCenter.default.addObserver(
            forName: .openJournalWindow,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                routeOpenJournalWindow(
                    appState: state,
                    openWindow: { openedWindowID = $0 },
                    activate: {}
                )
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        state.requestOpenJournal(destination)
        let command = await session.open(destination: state.journalOpenIntent!.destination)

        #expect(openedWindowID == SolstoneSceneID.journal.rawValue)
        #expect(state.openSceneIds.contains(.journal))
        #expect(session.state == .held)
        #expect(session.destination == destination)
        #expect(command == nil)
    }

    @Test func rootDestinationLoadsResolvedBase() async {
        let session = JournalWindowSession(resolveHomeBase: {
            .url("https://journal.example")
        })

        let command = await session.open(destination: .root)

        #expect(session.state == .loading)
        #expect(command?.url.absoluteString == "https://journal.example/")
        #expect(command?.baseURL.absoluteString == "https://journal.example/")
    }

    @Test func chatDestinationComposesPathQueryAndFragmentAgainstResolvedBase() {
        let destination = JournalWindowDestination(
            path: "/app/chat/2026-05-09",
            query: "pane=owner",
            fragment: "event-99"
        )!

        let command = JournalWindowComposition.composeLoadCommand(
            base: "http://127.0.0.1:54321/base/",
            destination: destination,
            generation: 7
        )

        #expect(command?.url.absoluteString == "http://127.0.0.1:54321/base/app/chat/2026-05-09?pane=owner#event-99")
        #expect(command?.generation == 7)
    }

    @Test func repeatedIntentForSameOpenWindowProducesMonotonicIDAndNewDeepLinkLoad() async {
        let state = AppState.forSnapshot()
        let resolver = JournalWindowResolvedBaseSequence([
            .url("https://journal.example"),
            .url("https://journal.example")
        ])
        let session = JournalWindowSession(resolveHomeBase: {
            await resolver.next()
        })

        state.requestOpenJournal(.root)
        let firstIntent = state.journalOpenIntent!
        let first = await session.open(destination: firstIntent.destination)
        state.requestOpenJournal(.chat(day: "2026-05-09", eventIndex: 5))
        let secondIntent = state.journalOpenIntent!
        let second = await session.open(destination: secondIntent.destination)

        #expect(secondIntent.id > firstIntent.id)
        #expect(first?.url.absoluteString == "https://journal.example/")
        #expect(second?.url.absoluteString == "https://journal.example/app/chat/2026-05-09#event-5")
        #expect(second?.generation == 2)
    }

    @Test func programmaticLoadThenOwnerSameURLNavigationGetsNewGeneration() {
        var composition = JournalWindowComposition()
        let command = composition.open(destination: .root, resolvedBase: .url("https://journal.example"))!

        composition.continueCurrentNavigation(url: command.url, baseURL: command.baseURL)
        #expect(composition.loadCommand == command)
        let userGeneration = composition.beginUserInitiatedNavigation(url: command.url, baseURL: command.baseURL)

        #expect(userGeneration == command.generation + 1)
        #expect(composition.generation == userGeneration)
        #expect(composition.state == .loading)
    }

    @Test func successiveProgrammaticLoadsToSameURLGetDistinctGenerations() {
        var composition = JournalWindowComposition()
        let first = composition.open(destination: .root, resolvedBase: .url("https://journal.example"))!
        let second = composition.open(destination: .root, resolvedBase: .url("https://journal.example"))!

        #expect(first.url == second.url)
        #expect(second.generation == first.generation + 1)
        #expect(composition.generation == second.generation)
        #expect(composition.loadCommand == second)
    }

    @Test func conveyRootRedirectOtherContinuationFinishesOriginalProgrammaticGeneration() {
        var composition = JournalWindowComposition()
        let command = composition.open(destination: .root, resolvedBase: .url("https://journal.example"))!
        let redirectURL = URL(string: "https://journal.example/app/home/")!

        // Models convey 302 "/" -> "/app/home/": WebKit reports both policy callbacks as .other, so they must ride generation N.
        composition.continueCurrentNavigation(url: command.url, baseURL: command.baseURL)
        composition.continueCurrentNavigation(url: redirectURL, baseURL: command.baseURL)
        composition.handle(.finished(generation: command.generation))

        #expect(composition.state == .loaded)
        #expect(composition.generation == command.generation)
    }

    @Test func baseChangeAfterConveyRootRedirectReloadsHomeDestination() {
        var composition = JournalWindowComposition()
        let command = composition.open(destination: .root, resolvedBase: .url("https://journal.example"))!
        let redirectURL = URL(string: "https://journal.example/app/home/")!

        composition.continueCurrentNavigation(url: command.url, baseURL: command.baseURL)
        composition.continueCurrentNavigation(url: redirectURL, baseURL: command.baseURL)
        composition.handle(.finished(generation: command.generation))
        let reloaded = composition.reload(resolvedBase: .url("https://journal-new.example"))!

        #expect(reloaded.url.absoluteString == "https://journal-new.example/app/home/")
        #expect(reloaded.generation == command.generation + 1)
    }

    @Test func userInitiatedSameOriginNavigationBumpsGenerationAndRetainsDestination() {
        var composition = JournalWindowComposition()
        let command = composition.open(destination: .root, resolvedBase: .url("https://journal.example"))!
        let linkURL = URL(string: "https://journal.example/app/home/")!
        let expectedDestination = JournalWindowDestination(path: "/app/home/")!

        let userGeneration = composition.beginUserInitiatedNavigation(url: linkURL, baseURL: command.baseURL)

        #expect(userGeneration == command.generation + 1)
        #expect(composition.generation == userGeneration)
        #expect(composition.destination == expectedDestination)
        #expect(composition.state == .loading)
    }

    @Test func baseChangesReloadRetainedDestinationAndHeldRetainsIt() async {
        let registrar = FakeObserverRegistrar()
        let state = AppState.forSnapshot(
            observerRegister: registrar.register,
            triggerTunnelConnectedSync: { _ in }
        )
        let destination = JournalWindowDestination(
            path: "/app/chat/2026-05-09",
            query: "pane=owner",
            fragment: "event-5"
        )!
        let resolver = JournalWindowResolvedBaseSequence([
            .url("http://127.0.0.1:41000"),
            .held,
            .url("http://127.0.0.1:42000")
        ])
        let session = JournalWindowSession(resolveHomeBase: {
            await resolver.next()
        })

        state.handleTunnelLifecycleState(TunnelLifecycleState.connected(localPort: 41000, via: TunnelConnectionRoute.relay))
        let first = await session.open(destination: destination)
        let tokenAfterA = state.journalHomeBaseChangeToken
        state.handleTunnelLifecycleState(TunnelLifecycleState.disconnected)
        let held = await session.reloadRetainedDestination()
        let tokenAfterHeld = state.journalHomeBaseChangeToken
        state.handleTunnelLifecycleState(TunnelLifecycleState.connected(localPort: 42000, via: TunnelConnectionRoute.relay))
        let second = await session.reloadRetainedDestination()

        #expect(first?.url.absoluteString == "http://127.0.0.1:41000/app/chat/2026-05-09?pane=owner#event-5")
        #expect(held == nil)
        #expect(session.destination == destination)
        #expect(tokenAfterHeld == tokenAfterA + 1)
        #expect(state.journalHomeBaseChangeToken == tokenAfterHeld + 1)
        #expect(second?.url.absoluteString == "http://127.0.0.1:42000/app/chat/2026-05-09?pane=owner#event-5")
    }

    @Test func unchangedBaseOnTokenBumpDoesNotReloadOrBumpGeneration() {
        var composition = JournalWindowComposition()
        let destination = JournalWindowDestination(path: "/app/chat/2026-05-09", fragment: "event-5")!
        let command = composition.open(destination: destination, resolvedBase: .url("https://journal.example"))!
        composition.handle(.finished(generation: command.generation))
        let generation = composition.generation

        let reloaded = composition.reload(resolvedBase: .url("https://journal.example"))

        #expect(reloaded == nil)
        #expect(composition.generation == generation)
        #expect(composition.state == .loaded)
    }

    @Test func unchangedBaseOnTokenBumpWhileLoadingDoesNotReloadOrBumpGeneration() {
        var composition = JournalWindowComposition()
        let destination = JournalWindowDestination(path: "/app/chat/2026-05-09", fragment: "event-5")!
        _ = composition.open(destination: destination, resolvedBase: .url("https://journal.example"))!
        let generation = composition.generation

        let reloaded = composition.reload(resolvedBase: .url("https://journal.example"))

        #expect(reloaded == nil)
        #expect(composition.generation == generation)
        #expect(composition.state == .loading)
    }

    @Test func unchangedBaseOnTokenBumpWhileErroredDoesReload() {
        var composition = JournalWindowComposition()
        let destination = JournalWindowDestination(path: "/app/chat/2026-05-09", fragment: "event-5")!
        let command = composition.open(destination: destination, resolvedBase: .url("https://journal.example"))!
        composition.handle(.failed(generation: command.generation, failure: .other))
        let generation = composition.generation

        let reloaded = composition.reload(resolvedBase: .url("https://journal.example"))

        #expect(reloaded != nil)
        #expect(reloaded?.generation == generation + 1)
        #expect(composition.state == .loading)
    }

    @Test func staleFailuresAndSelfInflictedCancellationsDoNotReplaceCurrentState() {
        var composition = JournalWindowComposition()
        let destination = JournalWindowDestination(path: "/app/chat/2026-05-09", fragment: "event-5")!
        let first = composition.open(destination: destination, resolvedBase: .url("https://a.example"))!
        let second = composition.reload(resolvedBase: .url("https://b.example"))!

        composition.handle(.failed(generation: first.generation, failure: .other))
        #expect(composition.state == .loading)
        #expect(composition.loadCommand?.url == second.url)

        composition.handle(.failed(generation: second.generation, failure: .selfInflictedCancellation))
        #expect(composition.state == .loading)
    }

    @Test func processTerminationEntersErrorState() {
        var composition = JournalWindowComposition()
        let command = composition.open(destination: .root, resolvedBase: .url("https://journal.example"))!

        composition.handle(.contentProcessTerminated(generation: command.generation))

        #expect(composition.state == .error)
    }

    @Test func retryReResolvesBaseAfterError() async {
        let resolver = JournalWindowResolvedBaseSequence([
            .url("https://first.example"),
            .url("https://second.example")
        ])
        let session = JournalWindowSession(resolveHomeBase: {
            await resolver.next()
        })
        let first = await session.open(destination: .chat(day: "2026-05-09", eventIndex: 3))
        session.handle(.failed(generation: first!.generation, failure: .other))

        let retried = await session.retry()

        #expect(await resolver.callCount == 2)
        #expect(session.state == .loading)
        #expect(retried?.url.absoluteString == "https://second.example/app/chat/2026-05-09#event-3")
    }

    @Test func selfInflictedCancellationErrorsAreRecognizedByDomainAndCode() {
        #expect(JournalWindowPolicy.isSelfInflictedCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
        #expect(JournalWindowPolicy.isSelfInflictedCancellation(
            NSError(domain: "WebKitErrorDomain", code: 102)
        ))
        #expect(!JournalWindowPolicy.isSelfInflictedCancellation(
            NSError(domain: "WebKitErrorDomain", code: 101)
        ))
    }
}

@Suite("JournalWindow Containment")
@MainActor
struct JournalWindowContainmentTests {
    @Test func navigationPolicyContainsMainFrameAndLeavesSubframesAlone() {
        let base = URL(string: "https://journal.example/root")!
        let onOrigin = JournalWindowNavigationPolicyInput(
            requestURL: URL(string: "https://journal.example/root/app/chat")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            currentBaseURL: base
        )
        let offOrigin = JournalWindowNavigationPolicyInput(
            requestURL: URL(string: "https://outside.example/")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            currentBaseURL: base
        )
        let nonHTTP = JournalWindowNavigationPolicyInput(
            requestURL: URL(string: "mailto:owner@example.com")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            currentBaseURL: base
        )
        let nilTargetOffOrigin = JournalWindowNavigationPolicyInput(
            requestURL: URL(string: "https://outside.example/blank")!,
            targetFrameIsMainFrame: nil,
            targetFrameIsNil: true,
            shouldPerformDownload: false,
            currentBaseURL: base
        )
        let nilTargetOnOrigin = JournalWindowNavigationPolicyInput(
            requestURL: URL(string: "https://journal.example/root/popout")!,
            targetFrameIsMainFrame: nil,
            targetFrameIsNil: true,
            shouldPerformDownload: false,
            currentBaseURL: base
        )
        let offOriginSubframe = JournalWindowNavigationPolicyInput(
            requestURL: URL(string: "https://outside.example/embed")!,
            targetFrameIsMainFrame: false,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            currentBaseURL: base
        )

        #expect(JournalWindowPolicy.decideNavigationAction(onOrigin) == .allow)
        #expect(JournalWindowPolicy.decideNavigationAction(offOrigin) == .cancelAndOpenExternal(URL(string: "https://outside.example/")!))
        #expect(JournalWindowPolicy.decideNavigationAction(nonHTTP) == .cancelAndOpenExternal(URL(string: "mailto:owner@example.com")!))
        #expect(JournalWindowPolicy.decideNavigationAction(nilTargetOffOrigin) == .cancelAndOpenExternal(URL(string: "https://outside.example/blank")!))
        #expect(JournalWindowPolicy.decideNavigationAction(nilTargetOnOrigin) == .cancelAndLoadInWindow(URL(string: "https://journal.example/root/popout")!))
        #expect(JournalWindowPolicy.decideNavigationAction(offOriginSubframe) == .allow)
    }

    @Test func downloadPoliciesCancelWithoutExternalHandoff() {
        let base = URL(string: "https://journal.example")!
        let actionDownload = JournalWindowNavigationPolicyInput(
            requestURL: URL(string: "https://journal.example/file")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: true,
            currentBaseURL: base
        )

        #expect(JournalWindowPolicy.decideNavigationAction(actionDownload) == .cancel)
        #expect(JournalWindowPolicy.allowsNavigationResponse(canShowMIMEType: true))
        #expect(!JournalWindowPolicy.allowsNavigationResponse(canShowMIMEType: false))
    }

    @Test func originComparisonDefaultsPortsAndLowercasesSchemeAndHost() {
        #expect(JournalWindowOrigin(url: URL(string: "HTTPS://JOURNAL.EXAMPLE/path")!)
            == JournalWindowOrigin(url: URL(string: "https://journal.example:443/other")!))
        #expect(JournalWindowOrigin(url: URL(string: "http://journal.example/path")!)
            == JournalWindowOrigin(url: URL(string: "http://journal.example:80/other")!))
    }
}

@Suite("JournalWindow Routing")
@MainActor
struct JournalWindowRoutingTests {
    @Test func journalSceneGateTracksOpenSceneMembershipWithoutLatch() {
        let state = AppState.forSnapshot()

        #expect(!shouldRenderJournalContent(journalWindowOpen: state.openSceneIds.contains(.journal)))

        state.openSceneIds.insert(.journal)
        #expect(shouldRenderJournalContent(journalWindowOpen: state.openSceneIds.contains(.journal)))

        state.openSceneIds.remove(.journal)
        #expect(!shouldRenderJournalContent(journalWindowOpen: state.openSceneIds.contains(.journal)))
    }

    @Test func openJournalWindowRoutesOpenThenDidOpenThenActivate() {
        let state = AppState.forSnapshot()
        state.dockMode = .alwaysAccessory
        var events: [String] = []

        routeOpenJournalWindow(
            appState: state,
            openWindow: { id in
                events.append("open:\(id)")
                #expect(!state.openSceneIds.contains(.journal))
            },
            activate: {
                events.append("activate")
                #expect(state.openSceneIds.contains(.journal))
            }
        )

        #expect(events == ["open:journal", "activate"])
        #expect(state.openSceneIds == [.journal])

        routeOpenJournalWindow(
            appState: state,
            openWindow: { id in events.append("open-again:\(id)") },
            activate: { events.append("activate-again") }
        )

        #expect(state.openSceneIds == [.journal])
        #expect(events.suffix(2) == ["open-again:journal", "activate-again"])
    }

    @Test func journalSceneIDDoesNotCollideWithExistingTrackedWindows() {
        #expect(SolstoneSceneID.journal.rawValue == "journal")
        #expect(!SolstoneSceneID.journal.rawValue.contains(SolstoneSceneID.settings.rawValue))
        #expect(!SolstoneSceneID.journal.rawValue.contains(SolstoneSceneID.about.rawValue))
        #expect(!SolstoneSceneID.settings.rawValue.contains(SolstoneSceneID.journal.rawValue))
        #expect(!SolstoneSceneID.about.rawValue.contains(SolstoneSceneID.journal.rawValue))
    }

    @Test func appStateRequestOpenJournalPublishesFreshIntentAndNotification() {
        let state = AppState.forSnapshot()
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .openJournalWindow,
            object: nil,
            queue: nil
        ) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        state.requestOpenJournal(.root)
        let first = state.journalOpenIntent
        state.requestOpenJournal(.root)
        let second = state.journalOpenIntent

        #expect(first?.destination == .root)
        #expect(second?.destination == .root)
        #expect((second?.id ?? 0) > (first?.id ?? 0))
        #expect(notifications == 2)
    }

    @Test func appStateWindowCloseRemovesJournalSceneID() {
        let state = AppState.forSnapshot()
        state.openSceneIds.insert(.journal)

        state.handleWindowWillClose(identifier: "journal-AppWindow-1")

        #expect(!state.openSceneIds.contains(.journal))
    }
}

@Suite("JournalWindow WebKit")
@MainActor
struct JournalWindowWebKitTests {
    @Test func sharedWebsiteDataStoreIsNonPersistentAndReused() {
        let first = JournalWindowWebsiteDataStore.sharedNonPersistent
        let second = JournalWindowWebsiteDataStore.sharedNonPersistent

        #expect(!first.isPersistent)
        #expect(first === second)
    }

    @Test func journalWindowSourceDefinesTeardownAndTrustSettings() throws {
        let source = try readWireUpSource("Sources/solstone/JournalWindow.swift")

        #expect(wireUpContains(source, "webView.stopLoading()"))
        #expect(wireUpContains(source, "configuration.websiteDataStore = dataStore"))
        #expect(wireUpContains(source, "configuration.userContentController.removeAllUserScripts()"))
        #expect(wireUpContains(source, "configuration.preferences.javaScriptCanOpenWindowsAutomatically = false"))
        #expect(wireUpContains(source, "configuration.defaultWebpagePreferences.allowsContentJavaScript = true"))
        #expect(wireUpContains(source, "configuration.allowsAirPlayForMediaPlayback = false"))
        #expect(wireUpContains(source, "configuration.mediaTypesRequiringUserActionForPlayback = .all"))
        #expect(wireUpContains(source, "webView.isInspectable = true"))
        #expect(wireUpContains(source, "webView.isInspectable = false"))
        #expect(wireUpContains(source, "decisionHandler(.deny)"))
        #expect(wireUpContains(source, "createWebViewWith configuration"))
        #expect(wireUpContains(source, "decidePolicyFor navigationResponse"))
    }
}

@Suite("JournalWindow WireUp")
struct JournalWindowWireUpTests {
    @Test func journalWindowReferencesExpectedAXIDsAndCopy() throws {
        let source = try readWireUpSource("Sources/solstone/JournalWindow.swift")
        let appSource = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let references = [
            "AXID.Journal.Browser.webView",
            "AXID.Journal.Browser.navigationState",
            "AXID.Journal.Browser.retry",
            "UICopy.JOURNAL_WINDOW_HELD",
            "UICopy.JOURNAL_WINDOW_LOADING",
            "UICopy.JOURNAL_WINDOW_ERROR",
            "UICopy.JOURNAL_WINDOW_RETRY"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
        #expect(wireUpContains(appSource, "Window(UICopy.JOURNAL_WINDOW_TITLE, id: SolstoneSceneID.journal.rawValue)"))
        #expect(wireUpContains(appSource, ".onReceive(NotificationCenter.default.publisher(for: .openJournalWindow))"))
    }

    @Test func formerJournalCallSitesDoNotUseNSWorkspaceOpen() throws {
        let menuSource = try readWireUpSource("Sources/solstone/MenuContent.swift")
        let bridgeSource = try readWireUpSource("Sources/solstone/SolChatBridge.swift")

        #expect(!menuSource.contains("NSWorkspace.shared.open"))
        #expect(!bridgeSource.contains("NSWorkspace.shared.open"))
        #expect(!bridgeSource.contains("postOpenChatIfConfigured"))
        #expect(!bridgeSource.contains("/app/chat/\\("))
        #expect(wireUpContains(menuSource, "appState.requestOpenJournal(.root)"))
        #expect(wireUpContains(bridgeSource, "await postOpenJournalDestination(Self.destination(summary: summary))"))
    }

    @Test func legitimateNonJournalNSWorkspaceOpenSitesRemain() throws {
        let settingsSource = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let repairSource = try readWireUpSource("Sources/solstone/AppPlacementRepair.swift")

        #expect(settingsSource.components(separatedBy: "NSWorkspace.shared.open").count - 1 == 6)
        #expect(repairSource.components(separatedBy: "NSWorkspace.shared.open").count - 1 == 1)
    }
}

private actor JournalWindowResolvedBaseSequence {
    private var values: [ResolvedHomeBase]
    private(set) var callCount = 0

    init(_ values: [ResolvedHomeBase]) {
        self.values = values
    }

    func next() -> ResolvedHomeBase {
        callCount += 1
        if values.count > 1 {
            return values.removeFirst()
        }
        return values.first ?? .held
    }
}
