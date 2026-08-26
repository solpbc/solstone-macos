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
            failure: .selfInflictedCancellation(hasDisplayedContent: true)
        ))
        #expect(composition.state == .loading)
        #expect(composition.loadCommand?.url == second.url)

        composition.handle(.failed(
            generation: first.generation,
            failure: .selfInflictedCancellation(hasDisplayedContent: false)
        ))
        #expect(composition.state == .loading)
        #expect(composition.loadCommand?.url == second.url)

        composition.handle(.failed(
            generation: second.generation,
            failure: .selfInflictedCancellation(hasDisplayedContent: false)
        ))
        #expect(composition.state == .error)

        let third = composition.reload(resolvedBase: .url("https://c.example"))!
        composition.handle(.failed(
            generation: third.generation,
            failure: .selfInflictedCancellation(hasDisplayedContent: true)
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

        #expect(!menuSource.contains("NSWorkspace.shared.open"))
        #expect(wireUpContains(menuSource, "appState.requestOpenJournal(.root)"))
    }

    @Test func legitimateNonJournalNSWorkspaceOpenSitesRemain() throws {
        let settingsSource = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let repairSource = try readWireUpSource("Sources/solstone/AppPlacementRepair.swift")

        #expect(settingsSource.components(separatedBy: "NSWorkspace.shared.open").count - 1 == 6)
        #expect(repairSource.components(separatedBy: "NSWorkspace.shared.open").count - 1 == 1)
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
