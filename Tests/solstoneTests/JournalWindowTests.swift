// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import SPLTunnel
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

    @Test func sameMacDisconnectedOpenJournalUsesBrowserNotWindow() {
        let probe = JournalURLOpenProbe()
        let state = AppState.forSnapshot(
            initialTunnelPairing: pairing(),
            journalURLOpener: { url in
                probe.opened.append(url)
                return true
            }
        )
        let observer = observeOpenJournalWindow(probe)
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(state.journalOpenIntent == nil)
        state.requestOpenJournal(.root)
        #expect(probe.opened.map(\.absoluteString) == ["http://127.0.0.1:5015/"])
        #expect(state.journalOpenIntent == nil)
        #expect(!probe.posted)

        // Door does not read ingest-ready / tunnel connectedness.
        state.requestOpenJournal(.root)
        #expect(probe.opened.map(\.absoluteString) == [
            "http://127.0.0.1:5015/",
            "http://127.0.0.1:5015/"
        ])
        #expect(state.journalOpenIntent == nil)
        #expect(!probe.posted)
    }

    @Test func elsewhereOpenJournalUsesWindowNotOpener() {
        let probe = JournalURLOpenProbe()
        let remote = pairing(
            localEndpoints: [LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")]
        )
        let state = AppState.forSnapshot(
            initialTunnelPairing: remote,
            journalURLOpener: { url in
                probe.opened.append(url)
                return true
            }
        )
        let observer = observeOpenJournalWindow(probe)
        defer { NotificationCenter.default.removeObserver(observer) }

        state.requestOpenJournal(.root)
        #expect(probe.opened.isEmpty)
        #expect(state.journalOpenIntent?.destination == .root)
        #expect(probe.posted)

        probe.posted = false
        let firstID = state.journalOpenIntent?.id
        state.requestOpenJournal(.root)
        #expect(probe.opened.isEmpty)
        #expect(state.journalOpenIntent?.id != firstID)
        #expect(probe.posted)
    }

    @Test func sameMacNonRootOpenJournalComposesOntoConveyBase() {
        let probe = JournalURLOpenProbe()
        let state = AppState.forSnapshot(
            initialTunnelPairing: pairing(),
            journalURLOpener: { url in
                probe.opened.append(url)
                return true
            }
        )
        let destination = JournalWindowDestination(
            path: "/app/chat/2026-05-09",
            query: "pane=owner",
            fragment: "event-99"
        )!
        let expected = JournalWindowComposition.composeLoadCommand(
            base: "http://127.0.0.1:5015/",
            destination: destination,
            generation: 0
        )

        state.requestOpenJournal(destination)
        #expect(probe.opened == [expected!.url])
        #expect(state.journalOpenIntent == nil)
    }

    @Test func sameMacOpenerFalseDoesNotFallThroughToWindow() {
        let probe = JournalURLOpenProbe()
        let state = AppState.forSnapshot(
            initialTunnelPairing: pairing(),
            journalURLOpener: { url in
                probe.opened.append(url)
                return false
            }
        )
        let observer = observeOpenJournalWindow(probe)
        defer { NotificationCenter.default.removeObserver(observer) }

        state.requestOpenJournal(.root)
        #expect(probe.opened.map(\.absoluteString) == ["http://127.0.0.1:5015/"])
        #expect(state.journalOpenIntent == nil)
        #expect(!probe.posted)
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
        state.requestOpenJournal(JournalWindowDestination(path: "/app/home", fragment: "section")!)
        let secondIntent = state.journalOpenIntent!
        let second = await session.open(destination: secondIntent.destination)

        #expect(secondIntent.id > firstIntent.id)
        #expect(first?.url.absoluteString == "https://journal.example/")
        #expect(second?.url.absoluteString == "https://journal.example/app/home#section")
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

    @Test func sameDocumentNavigationClassificationUsesFragmentPresenceAndStableURLParts() {
        let rows: [(current: String?, target: String, expected: Bool)] = [
            ("http://h/a", "http://h/a#s", true),
            ("http://h/a#s", "http://h/a#t", true),
            ("http://h/a#s", "http://h/a#s", true),
            ("http://h/a", "http://h/a#", true),
            ("http://h/a#s", "http://h/a", false),
            ("http://h/a", "http://h/a", false),
            ("http://h/a", "http://h/a?q=1#s", false),
            ("http://h/a?q=1", "http://h/a#s", false),
            ("http://h/a", "http://h/b#s", false),
            ("http://h/a", "http://other/a#s", false),
            (nil, "http://h/a#s", false),
            ("http://h:80/a", "http://h/a#s", true)
        ]

        for row in rows {
            let current = row.current.map { URL(string: $0)! }
            let target = URL(string: row.target)!

            #expect(JournalWindowPolicy.isSameDocumentNavigation(from: current, to: target) == row.expected)
        }
    }

    @Test func applySameDocumentNavigationUpdatesDestinationAndBaseWithoutStateOrGeneration() {
        var composition = JournalWindowComposition()
        let command = composition.open(destination: .root, resolvedBase: .url("https://journal.example"))!
        composition.handle(.finished(generation: command.generation))
        let generation = composition.generation

        composition.applySameDocumentNavigation(
            url: URL(string: "https://journal.example/app/chat/2026-05-09#event-6")!,
            baseURL: command.baseURL
        )

        #expect(composition.state == .loaded)
        #expect(composition.generation == generation)
        #expect(composition.destination == JournalWindowDestination(
            path: "/app/chat/2026-05-09",
            fragment: "event-6"
        )!)
        #expect(composition.currentBaseURL == command.baseURL)
    }

    @Test func seamSameDocumentLinkNavigationDoesNotTouchStateOrGeneration() async {
        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let seam = makeJournalWindowSeam(session: session)
        let command = await session.open(destination: .root)!
        completeJournalWindowLoad(command, seam: seam)
        let generation = session.generation

        let result = seam.decideNavigationAction(
            requestURL: URL(string: "https://journal.example/#section")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            isUserInitiated: true
        )

        #expect(result == .allow)
        #expect(session.state == .loaded)
        #expect(session.generation == generation)
        #expect(session.destination == JournalWindowDestination(path: "/", fragment: "section")!)
    }

    @Test func seamSameDocumentOtherNavigationDoesNotTouchStateOrGeneration() async {
        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let seam = makeJournalWindowSeam(session: session)
        let command = await session.open(destination: .root)!
        completeJournalWindowLoad(command, seam: seam)
        let generation = session.generation

        let result = seam.decideNavigationAction(
            requestURL: URL(string: "https://journal.example/#section")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            isUserInitiated: false
        )

        #expect(result == .allow)
        #expect(session.state == .loaded)
        #expect(session.generation == generation)
        #expect(session.destination == JournalWindowDestination(path: "/", fragment: "section")!)
    }

    @Test func seamCrossDocumentLinkNavigationStillBumpsGenerationAndLoads() async {
        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let seam = makeJournalWindowSeam(session: session)
        let command = await session.open(destination: .root)!
        completeJournalWindowLoad(command, seam: seam)
        let generation = session.generation

        let result = seam.decideNavigationAction(
            requestURL: URL(string: "https://journal.example/app/home#section")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            isUserInitiated: true
        )

        #expect(result == .allow)
        #expect(session.state == .loading)
        #expect(session.generation == generation + 1)
        #expect(session.destination == JournalWindowDestination(path: "/app/home", fragment: "section")!)
    }

    @Test func seamRecycledNavigationIdentityRebindsAfterTerminalRelease() async {
        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let seam = makeJournalWindowSeam(session: session)
        let command = await session.open(destination: .root)!
        let navigation = NSObject()

        seam.didStartProvisionalNavigation(navigation)
        seam.didFinish(navigation: navigation)
        #expect(session.state == .loaded)
        #expect(seam.bindingCount == 0)

        let result = seam.decideNavigationAction(
            requestURL: URL(string: "https://journal.example/app/home")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            isUserInitiated: true
        )
        #expect(result == .allow)
        #expect(session.generation == command.generation + 1)
        #expect(session.state == .loading)

        seam.didStartProvisionalNavigation(navigation)
        seam.didFinish(navigation: navigation)

        #expect(session.state == .loaded)
        #expect(seam.bindingCount == 0)
    }

    @Test func seamTerminalCallbacksReleaseBindingsAfterSettlingSession() async {
        let finishedSession = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let finishedSeam = makeJournalWindowSeam(session: finishedSession)
        _ = await finishedSession.open(destination: .root)!
        let finishedNavigation = NSObject()
        finishedSeam.didStartProvisionalNavigation(finishedNavigation)
        finishedSeam.didFinish(navigation: finishedNavigation)
        #expect(finishedSession.state == .loaded)
        #expect(finishedSeam.bindingCount == 0)

        let failedSession = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let failedSeam = makeJournalWindowSeam(session: failedSession)
        _ = await failedSession.open(destination: .root)!
        let failedNavigation = NSObject()
        failedSeam.didStartProvisionalNavigation(failedNavigation)
        failedSeam.didFail(navigation: failedNavigation, isSelfInflictedCancellation: false)
        #expect(failedSession.state == .error)
        #expect(failedSeam.bindingCount == 0)

        let cancelledSession = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let cancelledSeam = makeJournalWindowSeam(session: cancelledSession)
        _ = await cancelledSession.open(destination: .root)!
        let cancelledNavigation = NSObject()
        cancelledSeam.didStartProvisionalNavigation(cancelledNavigation)
        cancelledSeam.didFail(navigation: cancelledNavigation, isSelfInflictedCancellation: true)
        #expect(cancelledSession.state == .error)
        #expect(cancelledSeam.bindingCount == 0)
    }

    @Test func seamCommitWithoutBindingStillLatchesDisplayedContentBeforeFailure() async {
        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let seam = makeJournalWindowSeam(session: session)
        let command = await session.open(destination: .root)!
        let boundNavigation = NSObject()
        seam.registerAppInitiatedLoad(navigation: boundNavigation, generation: command.generation)

        seam.didCommit(
            navigation: NSObject(),
            committedDocumentURL: URL(string: "https://journal.example/")!
        )
        seam.didFail(navigation: boundNavigation, isSelfInflictedCancellation: true)

        #expect(session.state == .loaded)
        #expect(session.hasDisplayedContent)
        #expect(seam.bindingCount == 0)
    }

    @Test func seamUpdateLoadRegistrationPreservesSwiftUIDedupe() async {
        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let seam = makeJournalWindowSeam(session: session)
        let command = await session.open(destination: .root)!

        #expect(seam.prepareLoadCommandForUpdate(command) == command)
        seam.registerAppInitiatedLoad(navigation: NSObject(), generation: command.generation)
        #expect(seam.prepareLoadCommandForUpdate(command) == nil)
    }

    @Test func seamDirectLoadInCurrentWindowRegistersGenerationForSwiftUIDedupe() async {
        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example/root") })
        let seam = makeJournalWindowSeam(session: session)
        _ = await session.open(destination: .root)!

        let result = seam.decideNewWindowNavigationAction(
            requestURL: URL(string: "https://journal.example/root/popout")!,
            targetFrameIsMainFrame: nil,
            targetFrameIsNil: true,
            shouldPerformDownload: false
        )

        let command: JournalWindowLoadCommand
        switch result {
        case .loadInCurrentWindow(let value):
            command = value
        case .allow, .cancel:
            Issue.record("expected load in current window")
            return
        }
        #expect(session.loadCommand == command)
        seam.registerAppInitiatedLoad(navigation: NSObject(), generation: command.generation)
        #expect(seam.prepareLoadCommandForUpdate(session.loadCommand) == nil)
    }

    @Test func newWindowAllowedActionDoesNotBeginNavigation() async {
        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let seam = makeJournalWindowSeam(session: session)
        let command = await session.open(destination: .root)!
        completeJournalWindowLoad(command, seam: seam)
        let generation = session.generation

        let result = seam.decideNewWindowNavigationAction(
            requestURL: URL(string: "https://outside.example/embed")!,
            targetFrameIsMainFrame: false,
            targetFrameIsNil: true,
            shouldPerformDownload: false
        )

        #expect(result == .allow)
        #expect(session.state == .loaded)
        #expect(session.generation == generation)
    }

    @Test func navigationBindingsRetainRegisteredNavigationWithWeakControl() {
        weak var control: NSObject?
        do {
            let navigation = NSObject()
            control = navigation
        }
        #expect(control == nil)

        var bindings = JournalWindowNavigationBindings()
        weak var retained: NSObject?
        do {
            let navigation = NSObject()
            retained = navigation
            bindings.register(navigation, generation: 1)
        }
        #expect(retained != nil)
        bindings.removeAll()
        #expect(retained == nil)
    }

    @Test func navigationBindingsReleaseAndPruneOlderGenerations() {
        var bindings = JournalWindowNavigationBindings()
        let navigation = NSObject()

        bindings.register(navigation, generation: 1)
        #expect(bindings.generation(for: navigation) == 1)
        #expect(bindings.count == 1)
        bindings.release(navigation)
        #expect(bindings.generation(for: navigation) == nil)
        #expect(bindings.count == 0)

        let firstOld = NSObject()
        let secondOld = NSObject()
        bindings.register(firstOld, generation: 2)
        bindings.register(secondOld, generation: 2)
        #expect(bindings.count == 2)

        let registeredNew = NSObject()
        bindings.register(registeredNew, generation: 3)
        #expect(bindings.generation(for: firstOld) == nil)
        #expect(bindings.generation(for: secondOld) == nil)
        #expect(bindings.generation(for: registeredNew) == 3)
        #expect(bindings.count == 1)

        let boundExisting = NSObject()
        #expect(bindings.bind(boundExisting, currentGeneration: 4) == 4)
        #expect(bindings.bind(boundExisting, currentGeneration: 5) == 4)

        let boundNew = NSObject()
        #expect(bindings.bind(boundNew, currentGeneration: 5) == 5)
        #expect(bindings.generation(for: registeredNew) == nil)
        #expect(bindings.generation(for: boundExisting) == nil)
        #expect(bindings.generation(for: boundNew) == 5)
        #expect(bindings.count == 1)
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
        let state = AppState.forSnapshot(
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

        composition.handle(.failed(
            generation: first.generation,
            failure: .selfInflictedCancellation
        ))
        #expect(composition.state == .loading)
        #expect(composition.loadCommand?.url == second.url)

        composition.handle(.failed(
            generation: first.generation,
            failure: .selfInflictedCancellation
        ))
        #expect(composition.state == .loading)
        #expect(composition.loadCommand?.url == second.url)

        composition.handle(.failed(
            generation: second.generation,
            failure: .selfInflictedCancellation
        ))
        #expect(composition.state == .error)

        let third = composition.reload(resolvedBase: .url("https://c.example"))!
        composition.noteMainFrameCommit(committedURL: third.url)
        composition.handle(.failed(
            generation: third.generation,
            failure: .selfInflictedCancellation
        ))
        #expect(composition.state == .loaded)
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
        let first = await session.open(destination: JournalWindowDestination(path: "/app/home", fragment: "section")!)
        session.handle(.failed(generation: first!.generation, failure: .other))

        let retried = await session.retry()

        #expect(await resolver.callCount == 2)
        #expect(session.state == .loading)
        #expect(retried?.url.absoluteString == "https://second.example/app/home#section")
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
            "AXID.Journal.Browser.openSettings",
            "AXID.Journal.Browser.connectJournal",
            "UICopy.JOURNAL_WINDOW_LOADING",
            "UICopy.JOURNAL_WINDOW_ERROR",
            "UICopy.JOURNAL_WINDOW_RETRY",
            "UICopy.SETTINGS_SETUP_JOURNAL_APP_ACTION",
            "UICopy.SETTINGS_SETUP_JOURNAL_LINK_ACTION"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
        #expect(wireUpContains(source, "appState.tunnelLifecycleOwner.connectionVerdict"))
        #expect(!source.contains("let connectionVerdict = appState.tunnelLifecycleOwner.connectionVerdict"))
        #expect(wireUpContains(appSource, "Window(UICopy.JOURNAL_WINDOW_TITLE, id: SolstoneSceneID.journal.rawValue)"))
        #expect(wireUpContains(appSource, ".onReceive(NotificationCenter.default.publisher(for: .openJournalWindow))"))
    }

    @Test func formerJournalCallSitesDoNotUseNSWorkspaceOpen() throws {
        let menuSource = try readWireUpSource("Sources/solstone/MenuContent.swift")

        #expect(!menuSource.contains("NSWorkspace.shared.open"))
        #expect(wireUpContains(menuSource, "appState.requestOpenJournal(.root)"))
    }

    @Test func legitimateNonJournalNSWorkspaceOpenSitesRemain() throws {
        let settingsSource = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let repairSource = try readWireUpSource("Sources/solstone/AppPlacementRepair.swift")

        #expect(settingsSource.components(separatedBy: "NSWorkspace.shared.open").count - 1 == 7)
        #expect(repairSource.components(separatedBy: "NSWorkspace.shared.open").count - 1 == 1)
    }
}

@Suite("JournalWindow Honesty")
@MainActor
struct JournalWindowHonestyTests {
    @Test func heldHeadlineAndCaptionMatchReducerVerdicts() {
        let rows: [(JournalConnectionVerdict, String, String?)] = [
            (journalWindowNoRouteVerdict(), journalWindowNoRouteVerdict().message, journalWindowNoRouteVerdict().caption),
            (journalWindowUnreachableVerdict(), journalWindowUnreachableVerdict().message, journalWindowUnreachableVerdict().caption),
            (journalWindowLoopbackVerdict(), journalWindowLoopbackVerdict().message, journalWindowLoopbackVerdict().caption),
            (journalWindowRevokedVerdict(), journalWindowRevokedVerdict().message, journalWindowRevokedVerdict().caption),
            (journalWindowKeychainVerdict(), journalWindowKeychainVerdict().message, journalWindowKeychainVerdict().caption),
            (journalWindowNotEntitledVerdict(), journalWindowNotEntitledVerdict().message, journalWindowNotEntitledVerdict().caption),
            (journalWindowConnectingVerdict(), journalWindowConnectingVerdict().message, journalWindowConnectingVerdict().caption),
            (journalWindowDisconnectedVerdict(), journalWindowDisconnectedVerdict().message, journalWindowDisconnectedVerdict().caption)
        ]

        for row in rows {
            let session = JournalWindowSession(
                resolveHomeBase: { .held },
                connectionVerdict: { row.0 }
            )
            #expect(session.headline == row.1)
            #expect(session.caption == row.2)
        }
    }

    @Test func overlayActionIsExhaustiveOverFailureCausesAndNilTokens() {
        func expectedAction(for cause: JournalConnectionFailureCause) -> JournalWindowOverlayAction {
            switch cause {
            case .noRoute, .unreachable, .loopbackUnavailable:
                return .retry
            case .revoked, .keychainUnavailable, .mismatch, .notServing:
                return .openSettings
            case .notEntitled:
                return .none
            }
        }

        func expectedTitle(_ action: JournalWindowOverlayAction) -> String? {
            switch action {
            case .none:
                return nil
            case .retry:
                return UICopy.JOURNAL_WINDOW_RETRY
            case .openSettings:
                return UICopy.SETTINGS_SETUP_JOURNAL_APP_ACTION
            case .connectJournal:
                return UICopy.SETTINGS_SETUP_JOURNAL_LINK_ACTION
            }
        }

        let causes: [JournalConnectionFailureCause] = [
            .noRoute,
            .unreachable(nil),
            .unreachable("timeout"),
            .loopbackUnavailable,
            .revoked,
            .keychainUnavailable,
            .mismatch,
            .notServing,
            .notEntitled
        ]

        for cause in causes {
            let verdict = journalWindowVerdict(for: cause)
            let session = JournalWindowSession(
                resolveHomeBase: { .held },
                connectionVerdict: { verdict }
            )
            let action = expectedAction(for: cause)
            #expect(session.overlayAction == action)
            #expect(session.overlayButtonTitle == expectedTitle(action))
        }

        let connecting = JournalWindowSession(
            resolveHomeBase: { .held },
            connectionVerdict: { journalWindowConnectingVerdict() }
        )
        #expect(connecting.overlayAction == .none)
        #expect(connecting.overlayButtonTitle == nil)

        let disconnected = JournalWindowSession(
            resolveHomeBase: { .held },
            connectionVerdict: { journalWindowDisconnectedVerdict() }
        )
        #expect(disconnected.overlayAction == .connectJournal)
        #expect(disconnected.overlayButtonTitle == UICopy.SETTINGS_SETUP_JOURNAL_LINK_ACTION)

        let gap = JournalWindowSession(
            resolveHomeBase: { .held },
            connectionVerdict: { journalWindowConnectedVerdict() }
        )
        #expect(gap.overlayAction == .none)
        #expect(gap.overlayButtonTitle == nil)
    }

    @Test func verdictClassIsExhaustiveOverFailureCausesAndNilTokens() {
        func expectedClass(for cause: JournalConnectionFailureCause) -> JournalWindowVerdictClass {
            switch cause {
            case .noRoute, .unreachable, .loopbackUnavailable:
                return .transient
            case .revoked, .keychainUnavailable, .mismatch, .notServing, .notEntitled:
                return .nonTransient
            }
        }

        let causes: [JournalConnectionFailureCause] = [
            .noRoute,
            .unreachable(nil),
            .unreachable("timeout"),
            .loopbackUnavailable,
            .revoked,
            .keychainUnavailable,
            .mismatch,
            .notServing,
            .notEntitled
        ]

        for cause in causes {
            let verdict = journalWindowVerdict(for: cause)
            #expect(
                journalWindowVerdictClass(failureCause: cause, axToken: verdict.axToken)
                    == expectedClass(for: cause)
            )
        }

        let connecting = journalWindowConnectingVerdict()
        #expect(
            journalWindowVerdictClass(failureCause: nil, axToken: connecting.axToken) == .transient
        )
        let connected = journalWindowConnectedVerdict()
        #expect(
            journalWindowVerdictClass(failureCause: nil, axToken: connected.axToken) == .transient
        )
        let disconnected = journalWindowDisconnectedVerdict()
        #expect(
            journalWindowVerdictClass(failureCause: nil, axToken: disconnected.axToken) == .nonTransient
        )
    }

    @Test func retryDispatchMatchesRecoveryActionAndRouteDoesNotDispatch() async {
        let retryCauses: [JournalConnectionFailureCause] = [
            .noRoute,
            .unreachable(nil),
            .loopbackUnavailable
        ]

        for cause in retryCauses {
            var recorded: [JournalConnectionRecoveryAction] = []
            var routed = 0
            let verdict = journalWindowVerdict(for: cause)
            let session = JournalWindowSession(
                resolveHomeBase: { .held },
                connectionVerdict: { verdict },
                recover: { recorded.append($0) },
                openSettings: { routed += 1 }
            )
            await session.performHonestyRetry()
            #expect(recorded == [journalConnectionRecoveryAction(for: cause)])
            #expect(routed == 0)
        }

        let routeCauses: [JournalConnectionFailureCause] = [
            .revoked,
            .keychainUnavailable,
            .mismatch,
            .notServing
        ]
        for cause in routeCauses {
            var recorded: [JournalConnectionRecoveryAction] = []
            var routed = 0
            let verdict = journalWindowVerdict(for: cause)
            let session = JournalWindowSession(
                resolveHomeBase: { .held },
                connectionVerdict: { verdict },
                recover: { recorded.append($0) },
                openSettings: { routed += 1 }
            )
            await session.performHonestyRetry()
            session.performHonestyRoute()
            #expect(recorded.isEmpty)
            #expect(routed == 1)
        }

        var recorded: [JournalConnectionRecoveryAction] = []
        var routed = 0
        let disconnected = JournalWindowSession(
            resolveHomeBase: { .held },
            connectionVerdict: { journalWindowDisconnectedVerdict() },
            recover: { recorded.append($0) },
            openSettings: { routed += 1 }
        )
        await disconnected.performHonestyRetry()
        disconnected.performHonestyRoute()
        #expect(recorded.isEmpty)
        #expect(routed == 1)
    }

    @Test func retryDisabledWhilePairingCoordinatorBusy() {
        var busy = true
        let session = JournalWindowSession(
            resolveHomeBase: { .held },
            connectionVerdict: { journalWindowUnreachableVerdict() },
            pairingBusy: { busy }
        )
        #expect(session.isPairingBusy)
        #expect(!session.retryEnabled)
        busy = false
        #expect(!session.isPairingBusy)
        #expect(session.retryEnabled)
    }

    @Test func connectingToUnreachableFollowsLiveVerdictWithoutTokenBump() async {
        let box = JournalWindowLiveVerdict(journalWindowConnectingVerdict())
        let session = JournalWindowSession(
            resolveHomeBase: { .held },
            connectionVerdict: { box.value }
        )
        _ = await session.open(destination: .root)
        #expect(session.state == .held)
        #expect(session.headline == journalWindowConnectingVerdict().message)
        #expect(session.overlayAction == .none)

        box.value = journalWindowUnreachableVerdict()
        #expect(session.headline == journalWindowUnreachableVerdict().message)
        #expect(session.caption == journalWindowUnreachableVerdict().caption)
        #expect(session.overlayAction == .retry)
        #expect(session.overlayButtonTitle == UICopy.JOURNAL_WINDOW_RETRY)
    }

    @Test func latchPlusTransientHeldResolveEntersLinkDownFromLoadedLoadingAndError() {
        for phase in ["loaded", "loading", "error"] {
            var composition = JournalWindowComposition()
            let command = composition.open(
                destination: .root,
                resolvedBase: .url("https://journal.example"),
                verdictClass: .transient
            )!
            composition.noteMainFrameCommit(committedURL: command.url)
            switch phase {
            case "loaded":
                composition.handle(.finished(generation: command.generation))
            case "error":
                composition.handle(.failed(generation: command.generation, failure: .other))
            default:
                break
            }
            let dropped = composition.reload(resolvedBase: .held, verdictClass: .transient)
            #expect(dropped == nil)
            #expect(composition.state == .linkDown)
            #expect(composition.showsWebView)
            #expect(composition.state.axToken == "link_down")
        }

        var noLatch = JournalWindowComposition()
        _ = noLatch.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )
        let held = noLatch.reload(resolvedBase: .held, verdictClass: .transient)
        #expect(held == nil)
        #expect(noLatch.state == .held)
        #expect(!noLatch.showsWebView)
    }

    @Test func nonTransientHeldResolveUnmountsFromLoadedLoadingErrorAndLinkDown() {
        for phase in ["loaded", "loading", "error", "linkDown"] {
            var composition = JournalWindowComposition()
            let command = composition.open(
                destination: .root,
                resolvedBase: .url("https://journal.example"),
                verdictClass: .transient
            )!
            composition.noteMainFrameCommit(committedURL: command.url)
            switch phase {
            case "loaded":
                composition.handle(.finished(generation: command.generation))
            case "error":
                composition.handle(.failed(generation: command.generation, failure: .other))
            case "linkDown":
                _ = composition.reload(resolvedBase: .held, verdictClass: .transient)
                #expect(composition.state == .linkDown)
            default:
                break
            }
            let dropped = composition.reload(resolvedBase: .held, verdictClass: .nonTransient)
            #expect(dropped == nil)
            #expect(composition.state == .held)
            #expect(!composition.showsWebView)
            #expect(!composition.hasDisplayedContent)
        }

        var composition = JournalWindowComposition()
        let command = composition.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        composition.noteMainFrameCommit(committedURL: command.url)
        _ = composition.reload(resolvedBase: .held, verdictClass: .transient)
        #expect(composition.state == .linkDown)
        let further = composition.reload(resolvedBase: .held, verdictClass: .transient)
        #expect(further == nil)
        #expect(composition.state == .linkDown)
        #expect(composition.showsWebView)
    }

    @Test func sessionNonTransientVerdictsUnmountFromLoadedAndFromLinkDown() async {
        let cases: [JournalConnectionVerdict] = [
            journalWindowRevokedVerdict(),
            journalWindowKeychainVerdict(),
            journalWindowDisconnectedVerdict(),
            journalWindowNotEntitledVerdict()
        ]

        for verdict in cases {
            let base = JournalWindowLiveBase(.url("https://journal.example"))
            let liveVerdict = JournalWindowLiveVerdict(verdict)
            let session = JournalWindowSession(
                resolveHomeBase: { base.value },
                connectionVerdict: { liveVerdict.value }
            )
            let seam = makeJournalWindowSeam(session: session)
            let command = await session.open(destination: .root)!
            completeJournalWindowLoad(command, seam: seam)
            #expect(session.state == .loaded)
            #expect(session.hasDisplayedContent)

            base.value = .held
            let dropped = await session.reloadRetainedDestination()
            #expect(dropped == nil)
            #expect(session.state == .held)
            #expect(!session.showsWebView)
            #expect(!session.hasDisplayedContent)
        }

        for verdict in cases {
            let base = JournalWindowLiveBase(.url("https://journal.example"))
            let liveVerdict = JournalWindowLiveVerdict(journalWindowUnreachableVerdict())
            let session = JournalWindowSession(
                resolveHomeBase: { base.value },
                connectionVerdict: { liveVerdict.value }
            )
            let seam = makeJournalWindowSeam(session: session)
            let command = await session.open(destination: .root)!
            completeJournalWindowLoad(command, seam: seam)
            base.value = .held
            let linkDown = await session.reloadRetainedDestination()
            #expect(linkDown == nil)
            #expect(session.state == .linkDown)
            #expect(session.showsWebView)
            #expect(session.hasDisplayedContent)

            liveVerdict.value = verdict
            let dropped = await session.reloadRetainedDestination()
            #expect(dropped == nil)
            #expect(session.state == .held)
            #expect(!session.showsWebView)
            #expect(!session.hasDisplayedContent)
        }
    }

    @Test func linkDownReturnComparesCommittedBaseAndDestination() {
        var composition = JournalWindowComposition()
        let destination = JournalWindowDestination(path: "/app/home", fragment: "event-1")!
        let command = composition.open(
            destination: destination,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        composition.noteMainFrameCommit(committedURL: command.url)
        composition.handle(.failed(generation: command.generation, failure: .other))
        #expect(composition.state == .error)
        _ = composition.reload(resolvedBase: .held, verdictClass: .transient)
        let preReturnGeneration = composition.generation
        let recovered = composition.reload(
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )
        #expect(recovered == nil)
        #expect(composition.state == .loaded)
        #expect(composition.generation == preReturnGeneration + 1)
        composition.handle(.failed(generation: command.generation, failure: .other))
        #expect(composition.state == .loaded)

        var fragmentComposition = JournalWindowComposition()
        let root = fragmentComposition.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        fragmentComposition.handle(.finished(generation: root.generation))
        fragmentComposition.noteMainFrameCommit(committedURL: root.url)
        fragmentComposition.applySameDocumentNavigation(
            url: URL(string: "https://journal.example/#section")!,
            baseURL: root.baseURL
        )
        _ = fragmentComposition.reload(resolvedBase: .held, verdictClass: .transient)
        let fragmentRecovered = fragmentComposition.reload(
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )
        #expect(fragmentRecovered == nil)
        #expect(fragmentComposition.state == .loaded)

        var destChange = JournalWindowComposition()
        let first = destChange.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        destChange.noteMainFrameCommit(committedURL: first.url)
        _ = destChange.reload(resolvedBase: .held, verdictClass: .transient)
        _ = destChange.open(
            destination: JournalWindowDestination(path: "/app/home")!,
            resolvedBase: .held,
            verdictClass: .transient
        )
        #expect(destChange.state == .linkDown)
        let loadedDifferentDest = destChange.reload(
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )
        #expect(loadedDifferentDest != nil)
        #expect(destChange.state == .loading)
        #expect(destChange.showsWebView)

        let furtherDrop = destChange.reload(resolvedBase: .held, verdictClass: .transient)
        #expect(furtherDrop == nil)
        #expect(destChange.state == .linkDown)
        #expect(destChange.state != .held)

        var differentBase = JournalWindowComposition()
        let original = differentBase.open(
            destination: .root,
            resolvedBase: .url("http://127.0.0.1:41000"),
            verdictClass: .transient
        )!
        differentBase.noteMainFrameCommit(committedURL: original.url)
        _ = differentBase.reload(resolvedBase: .held, verdictClass: .transient)
        let rebound = differentBase.reload(
            resolvedBase: .url("http://127.0.0.1:42000"),
            verdictClass: .transient
        )
        #expect(rebound != nil)
        #expect(differentBase.state == .loading)
        #expect(rebound?.url.absoluteString == "http://127.0.0.1:42000/")
    }

    @Test func linkDownPolicyCancelsMainFrameAndKeepsOffOriginExternal() async {
        var opened: [URL] = []
        var resolved: ResolvedHomeBase = .url("https://journal.example")
        let session = JournalWindowSession(
            resolveHomeBase: { resolved },
            connectionVerdict: { journalWindowUnreachableVerdict() }
        )
        let seam = JournalWindowWebViewSeam(session: session, openExternalURL: { opened.append($0) })
        let command = await session.open(destination: .root)!
        completeJournalWindowLoad(command, seam: seam)
        resolved = .held
        _ = await session.reloadRetainedDestination()
        #expect(session.state == .linkDown)
        let linkDownGeneration = session.generation

        let userInitiated = seam.decideNavigationAction(
            requestURL: URL(string: "https://journal.example/app/home")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            isUserInitiated: true
        )
        let continuation = seam.decideNavigationAction(
            requestURL: URL(string: "https://journal.example/app/home")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            isUserInitiated: false
        )
        let newWindow = seam.decideNewWindowNavigationAction(
            requestURL: URL(string: "https://journal.example/popout")!,
            targetFrameIsMainFrame: nil,
            targetFrameIsNil: true,
            shouldPerformDownload: false
        )
        let offOrigin = seam.decideNavigationAction(
            requestURL: URL(string: "https://outside.example/")!,
            targetFrameIsMainFrame: true,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            isUserInitiated: true
        )
        let subframe = seam.decideNavigationAction(
            requestURL: URL(string: "https://outside.example/embed")!,
            targetFrameIsMainFrame: false,
            targetFrameIsNil: false,
            shouldPerformDownload: false,
            isUserInitiated: false
        )

        #expect(userInitiated == .cancel)
        #expect(continuation == .cancel)
        #expect(newWindow == .cancel)
        #expect(offOrigin == .cancel)
        #expect(opened == [URL(string: "https://outside.example/")!])
        #expect(subframe == .allow)
        #expect(session.state == .linkDown)
        #expect(session.loadCommand == nil)

        session.handle(.started(generation: linkDownGeneration))
        session.handle(.finished(generation: linkDownGeneration))
        session.handle(.failed(generation: linkDownGeneration, failure: .other))
        session.handle(.failed(generation: linkDownGeneration, failure: .selfInflictedCancellation))
        session.noteMainFrameCommit(committedURL: command.url)
        #expect(session.state == .linkDown)
        #expect(session.committedBaseURL == command.baseURL)

        session.handle(.contentProcessTerminated(generation: linkDownGeneration))
        #expect(session.state == .held)
        #expect(!session.hasDisplayedContent)
        #expect(!session.showsWebView)

        resolved = .url("https://journal.example")
        let afterDeath = await session.reloadRetainedDestination()
        #expect(afterDeath != nil)
        #expect(session.state == .loading)
    }

    @Test func inFlightCrossDocumentClickReloadsClickTargetOnReturn() {
        var composition = JournalWindowComposition()
        let command = composition.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        composition.noteMainFrameCommit(committedURL: command.url)
        composition.handle(.finished(generation: command.generation))
        _ = composition.beginUserInitiatedNavigation(
            url: URL(string: "https://journal.example/app/home")!,
            baseURL: command.baseURL
        )
        _ = composition.reload(resolvedBase: .held, verdictClass: .transient)
        #expect(composition.state == .linkDown)
        #expect(composition.destination == JournalWindowDestination(path: "/app/home")!)
        let returned = composition.reload(
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )
        #expect(returned?.url.absoluteString == "https://journal.example/app/home")
        #expect(composition.state == .loading)
    }

    @Test func samePortStormIssuesZeroLoadsAfterInitialCommit() {
        var connected = true
        let port = 41000
        func resolve() -> ResolvedHomeBase {
            connected ? .url("http://127.0.0.1:\(port)") : .held
        }

        var composition = JournalWindowComposition()
        let first = composition.open(destination: .root, resolvedBase: resolve(), verdictClass: .transient)!
        composition.noteMainFrameCommit(committedURL: first.url)
        var extraLoads = 0
        var sawHeld = false
        for _ in 0..<10 {
            connected = false
            let drop = composition.reload(resolvedBase: resolve(), verdictClass: .transient)
            #expect(drop == nil)
            if composition.state == .held {
                sawHeld = true
            }
            #expect(composition.state == .linkDown)
            connected = true
            let returned = composition.reload(resolvedBase: resolve(), verdictClass: .transient)
            if returned != nil {
                extraLoads += 1
            }
            #expect(composition.state != .held)
            #expect(composition.showsWebView)
        }
        #expect(extraLoads == 0)
        #expect(!sawHeld)
    }

    @Test func rebuiltListenerStormLoadsOncePerNewPortAndNeverUnmounts() {
        var connected = true
        var port = 41000
        func resolve() -> ResolvedHomeBase {
            connected ? .url("http://127.0.0.1:\(port)") : .held
        }

        var composition = JournalWindowComposition()
        let first = composition.open(destination: .root, resolvedBase: resolve(), verdictClass: .transient)!
        composition.noteMainFrameCommit(committedURL: first.url)
        var loads = 0
        var sawHeld = false
        var committedPort: Int?
        for index in 0..<10 {
            connected = false
            let drop = composition.reload(resolvedBase: resolve(), verdictClass: .transient)
            #expect(drop == nil)
            if composition.state == .held {
                sawHeld = true
            }
            #expect(composition.state == .linkDown)
            #expect(composition.showsWebView)
            connected = true
            port = 41001 + index
            let returned = composition.reload(resolvedBase: resolve(), verdictClass: .transient)
            if returned != nil {
                loads += 1
            }
            #expect(returned != nil)
            #expect(composition.state == .loading)
            #expect(composition.showsWebView)
            if index == 3, let returned {
                composition.noteMainFrameCommit(committedURL: returned.url)
                committedPort = port
            }
        }
        #expect(loads == 10)
        #expect(!sawHeld)

        connected = false
        _ = composition.reload(resolvedBase: resolve(), verdictClass: .transient)
        connected = true
        port = committedPort!
        let backToCommitted = composition.reload(resolvedBase: resolve(), verdictClass: .transient)
        #expect(backToCommitted == nil)
        #expect(composition.state == .loaded)
    }

    @Test func unboundCommitLatchesForTransientDrop() async {
        let latchedBase = JournalWindowLiveBase(.url("https://journal.example"))
        let latchedSession = JournalWindowSession(
            resolveHomeBase: { latchedBase.value },
            connectionVerdict: { journalWindowUnreachableVerdict() }
        )
        let latchedSeam = makeJournalWindowSeam(session: latchedSession)
        _ = await latchedSession.open(destination: .root)!
        latchedSeam.didCommit(
            navigation: NSObject(),
            committedDocumentURL: URL(string: "https://journal.example/")!
        )
        latchedBase.value = .held
        let latchedDrop = await latchedSession.reloadRetainedDestination()
        #expect(latchedDrop == nil)
        #expect(latchedSession.state == .linkDown)
        #expect(latchedSession.hasDisplayedContent)

        let unlatchedBase = JournalWindowLiveBase(.url("https://journal.example"))
        let unlatchedSession = JournalWindowSession(
            resolveHomeBase: { unlatchedBase.value },
            connectionVerdict: { journalWindowUnreachableVerdict() }
        )
        _ = await unlatchedSession.open(destination: .root)!
        unlatchedBase.value = .held
        let unlatchedDrop = await unlatchedSession.reloadRetainedDestination()
        #expect(unlatchedDrop == nil)
        #expect(unlatchedSession.state == .held)
        #expect(!unlatchedSession.hasDisplayedContent)
    }

    @Test func axLinkDownTokenAndRoutingIDs() {
        #expect(JournalWindowAXState.linkDown.axToken == "link_down")
        #expect(AXID.Journal.Browser.retry == "journal.browser.retry")
        #expect(AXID.Journal.Browser.openSettings == "journal.browser.openSettings")
        #expect(AXID.Journal.Browser.connectJournal == "journal.browser.connectJournal")
        #expect(AXContract.staticIDs.contains(AXID.Journal.Browser.openSettings))
        #expect(AXContract.staticIDs.contains(AXID.Journal.Browser.connectJournal))
        #expect(AXContract.vocabularies["JournalWindowAXState"]?.contains("link_down") == true)
    }

    @Test func unregisteredFailureBecomesErrorOnlyForCurrentLoadWithoutBindings() async {
        var composition = JournalWindowComposition()
        let command = composition.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        composition.handleUnregisteredFailure(isSelfInflictedCancellation: false)
        #expect(composition.state == .error)

        var loaded = JournalWindowComposition()
        let loadedCommand = loaded.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        loaded.noteMainFrameCommit(committedURL: loadedCommand.url)
        loaded.handle(.finished(generation: loadedCommand.generation))
        loaded.handleUnregisteredFailure(isSelfInflictedCancellation: false)
        #expect(loaded.state == .loaded)

        var userNav = JournalWindowComposition()
        let userCommand = userNav.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        userNav.handle(.finished(generation: userCommand.generation))
        userNav.noteMainFrameCommit(committedURL: userCommand.url)
        _ = userNav.beginUserInitiatedNavigation(
            url: URL(string: "https://journal.example/app/home")!,
            baseURL: userCommand.baseURL
        )
        #expect(userNav.loadCommand == nil)
        userNav.handleUnregisteredFailure(isSelfInflictedCancellation: false)
        #expect(userNav.state == .loading)

        let session = JournalWindowSession(resolveHomeBase: { .url("https://journal.example") })
        let seam = makeJournalWindowSeam(session: session)
        let load = await session.open(destination: .root)!
        seam.registerAppInitiatedLoad(navigation: NSObject(), generation: load.generation)
        seam.didFail(
            navigation: NSObject(),
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        #expect(session.state == .loading)

        var cancelled = JournalWindowComposition()
        _ = cancelled.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )
        cancelled.handleUnregisteredFailure(isSelfInflictedCancellation: true)
        #expect(cancelled.state == .loading)

        var linkDown = JournalWindowComposition()
        let linkCommand = linkDown.open(
            destination: .root,
            resolvedBase: .url("https://journal.example"),
            verdictClass: .transient
        )!
        linkDown.noteMainFrameCommit(committedURL: linkCommand.url)
        _ = linkDown.reload(resolvedBase: .held, verdictClass: .transient)
        linkDown.handleUnregisteredFailure(isSelfInflictedCancellation: false)
        #expect(linkDown.state == .linkDown)

        _ = command
    }
}

@MainActor
private final class JournalWindowLiveVerdict {
    var value: JournalConnectionVerdict

    init(_ value: JournalConnectionVerdict) {
        self.value = value
    }
}

@MainActor
private final class JournalWindowLiveBase {
    var value: ResolvedHomeBase

    init(_ value: ResolvedHomeBase) {
        self.value = value
    }
}

@MainActor
private func journalWindowReducerVerdict(
    state: TunnelLifecycleState,
    hasPersistedPairing: Bool = true,
    isTunnelManaged: Bool = true,
    isProxyStarting: Bool = false,
    establishedLoopbackPort: Int? = nil,
    hasTransport: Bool = false
) -> JournalConnectionVerdict {
    TunnelLifecycleOwner.reduceConnectionVerdict(
        state: state,
        hasPersistedPairing: hasPersistedPairing,
        isTunnelManaged: isTunnelManaged,
        supervisorAttemptState: .idle,
        isProxyStarting: isProxyStarting,
        establishedLoopbackPort: establishedLoopbackPort,
        hasTransport: hasTransport
    )
}

@MainActor
private func journalWindowConnectingVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(state: .connecting, isProxyStarting: true)
}

@MainActor
private func journalWindowDisconnectedVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(state: .disconnected, hasPersistedPairing: false)
}

@MainActor
private func journalWindowConnectedVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(
        state: .connected(localPort: 41000, via: .relay),
        establishedLoopbackPort: 41000,
        hasTransport: true
    )
}

@MainActor
private func journalWindowNoRouteVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(state: .disconnected, isTunnelManaged: false)
}

@MainActor
private func journalWindowUnreachableVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(state: .disconnected, isTunnelManaged: true)
}

@MainActor
private func journalWindowLoopbackVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(state: .error(.loopbackUnavailable))
}

@MainActor
private func journalWindowRevokedVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(state: .error(.revoked))
}

@MainActor
private func journalWindowKeychainVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(state: .error(.keychainUnavailable))
}

@MainActor
private func journalWindowNotEntitledVerdict() -> JournalConnectionVerdict {
    journalWindowReducerVerdict(state: .error(.notEntitled))
}

@MainActor
private func journalWindowVerdict(for cause: JournalConnectionFailureCause) -> JournalConnectionVerdict {
    switch cause {
    case .noRoute:
        return journalWindowNoRouteVerdict()
    case .unreachable:
        return journalWindowUnreachableVerdict()
    case .loopbackUnavailable:
        return journalWindowLoopbackVerdict()
    case .revoked:
        return journalWindowRevokedVerdict()
    case .keychainUnavailable:
        return journalWindowKeychainVerdict()
    case .notEntitled:
        return journalWindowNotEntitledVerdict()
    case .mismatch:
        return JournalConnectionVerdict(
            severity: .attention,
            message: journalWindowUnreachableVerdict().message,
            caption: nil,
            axToken: PairingConnectionAXState.mismatch.axToken,
            failureCause: .mismatch
        )
    case .notServing:
        return JournalConnectionVerdict(
            severity: .attention,
            message: journalWindowUnreachableVerdict().message,
            caption: nil,
            axToken: PairingConnectionAXState.notServing.axToken,
            failureCause: .notServing
        )
    }
}

@MainActor
private final class JournalURLOpenProbe {
    var opened: [URL] = []
    var posted = false
}

@MainActor
private func observeOpenJournalWindow(_ probe: JournalURLOpenProbe) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: .openJournalWindow,
        object: nil,
        queue: nil
    ) { _ in
        MainActor.assumeIsolated {
            probe.posted = true
        }
    }
}

@MainActor
private func makeJournalWindowSeam(session: JournalWindowSession) -> JournalWindowWebViewSeam {
    JournalWindowWebViewSeam(session: session, openExternalURL: { _ in })
}

@MainActor
private func completeJournalWindowLoad(
    _ command: JournalWindowLoadCommand,
    seam: JournalWindowWebViewSeam,
    committedURL: URL? = nil
) {
    let navigation = NSObject()
    seam.registerAppInitiatedLoad(navigation: navigation, generation: command.generation)
    seam.didCommit(navigation: navigation, committedDocumentURL: committedURL ?? command.url)
    seam.didFinish(navigation: navigation)
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
