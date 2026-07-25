// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI
import WebKit

internal typealias JournalWindowExternalURLOpener = @MainActor @Sendable (URL) -> Void
internal typealias JournalWindowWebsiteDataStoreProvider = @MainActor @Sendable () -> WKWebsiteDataStore

@MainActor
internal enum JournalWindowWebsiteDataStore {
    static let sharedNonPersistent = WKWebsiteDataStore.nonPersistent()
}

/// Encodes the open=>render / closed=>inert invariant for the journal scene root.
func shouldRenderJournalContent(journalWindowOpen: Bool) -> Bool { journalWindowOpen }

@MainActor
func routeOpenJournalWindow(
    appState: AppState,
    openWindow: (String) -> Void,
    activate: () -> Void
) {
    openWindow(SolstoneSceneID.journal.rawValue)
    appState.didOpenWindow(.journal)
    activate()
}

struct JournalWindowSceneRoot: View {
    let appState: AppState
    private let resolveHomeBase: JournalWindowSession.ResolveHomeBase
    private let openExternalURL: JournalWindowExternalURLOpener
    private let websiteDataStore: JournalWindowWebsiteDataStoreProvider

    init(
        appState: AppState,
        resolveHomeBase: JournalWindowSession.ResolveHomeBase? = nil,
        openExternalURL: @escaping JournalWindowExternalURLOpener = { url in
            NSWorkspace.shared.open(url)
        },
        websiteDataStore: @escaping JournalWindowWebsiteDataStoreProvider = {
            JournalWindowWebsiteDataStore.sharedNonPersistent
        }
    ) {
        self.appState = appState
        self.resolveHomeBase = resolveHomeBase ?? { [appState] in
            await appState.resolveHomeBase()
        }
        self.openExternalURL = openExternalURL
        self.websiteDataStore = websiteDataStore
    }

    var body: some View {
        if shouldRenderJournalContent(journalWindowOpen: appState.openSceneIds.contains(.journal)) {
            JournalWindowView(
                intent: appState.journalOpenIntent,
                homeBaseChangeToken: appState.journalHomeBaseChangeToken,
                resolveHomeBase: resolveHomeBase,
                openExternalURL: openExternalURL,
                websiteDataStore: websiteDataStore
            )
        } else {
            Color.clear
        }
    }
}

private struct JournalWindowView: View {
    let intent: JournalOpenIntent?
    let homeBaseChangeToken: UInt64
    let openExternalURL: JournalWindowExternalURLOpener
    let websiteDataStore: JournalWindowWebsiteDataStoreProvider
    @State private var session: JournalWindowSession

    init(
        intent: JournalOpenIntent?,
        homeBaseChangeToken: UInt64,
        resolveHomeBase: @escaping JournalWindowSession.ResolveHomeBase,
        openExternalURL: @escaping JournalWindowExternalURLOpener,
        websiteDataStore: @escaping JournalWindowWebsiteDataStoreProvider
    ) {
        self.intent = intent
        self.homeBaseChangeToken = homeBaseChangeToken
        self.openExternalURL = openExternalURL
        self.websiteDataStore = websiteDataStore
        _session = State(initialValue: JournalWindowSession(resolveHomeBase: resolveHomeBase))
    }

    var body: some View {
        ZStack {
            if session.state != .held {
                JournalWebView(
                    session: session,
                    loadCommand: session.loadCommand,
                    openExternalURL: openExternalURL,
                    websiteDataStore: websiteDataStore
                )
                .accessibilityIdentifier(AXID.Journal.Browser.webView)
            }

            switch session.state {
            case .held:
                Text(UICopy.JOURNAL_WINDOW_HELD)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView(UICopy.JOURNAL_WINDOW_LOADING)
                    .controlSize(.large)
            case .loaded:
                EmptyView()
            case .error:
                VStack(spacing: 12) {
                    Text(UICopy.JOURNAL_WINDOW_ERROR)
                        .font(.headline)
                    Button(UICopy.JOURNAL_WINDOW_RETRY) {
                        Task {
                            await session.retry()
                        }
                    }
                    .accessibilityIdentifier(AXID.Journal.Browser.retry)
                }
                .padding(24)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .accessibilityIdentifier(AXID.Journal.Browser.navigationState)
        .accessibilityValue(session.state.axToken)
        .task(id: intent?.id) {
            guard let intent else { return }
            await session.open(destination: intent.destination)
        }
        .onChange(of: homeBaseChangeToken) { _, _ in
            Task {
                await session.reloadRetainedDestination()
            }
        }
    }
}

private struct JournalWebView: NSViewRepresentable {
    let session: JournalWindowSession
    let loadCommand: JournalWindowLoadCommand?
    let openExternalURL: JournalWindowExternalURLOpener
    let websiteDataStore: JournalWindowWebsiteDataStoreProvider

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, openExternalURL: openExternalURL)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration(dataStore: websiteDataStore()))
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #else
        // Keep Web Inspector unavailable in release builds.
        webView.isInspectable = false
        #endif
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.session = session
        context.coordinator.openExternalURL = openExternalURL
        guard let loadCommand,
              context.coordinator.lastLoadedGeneration != loadCommand.generation
        else {
            return
        }

        context.coordinator.prepareProgrammaticLoad(loadCommand)
        let navigation = webView.load(URLRequest(url: loadCommand.url))
        context.coordinator.register(navigation: navigation, generation: loadCommand.generation)
        context.coordinator.lastLoadedGeneration = loadCommand.generation
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.tearDown()
    }

    private static func makeConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController = WKUserContentController()
        configuration.userContentController.removeAllUserScripts()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var session: JournalWindowSession
        var openExternalURL: JournalWindowExternalURLOpener
        var lastLoadedGeneration: UInt64?
        private var generationByNavigation: [ObjectIdentifier: UInt64] = [:]
        private var programmaticNavigationClaims = JournalWindowProgrammaticNavigationClaims()

        init(
            session: JournalWindowSession,
            openExternalURL: @escaping JournalWindowExternalURLOpener
        ) {
            self.session = session
            self.openExternalURL = openExternalURL
        }

        func prepareProgrammaticLoad(_ command: JournalWindowLoadCommand) {
            programmaticNavigationClaims.prepare(command)
        }

        func register(navigation: WKNavigation?, generation: UInt64) {
            guard let navigation else { return }
            generationByNavigation[ObjectIdentifier(navigation)] = generation
        }

        func tearDown() {
            generationByNavigation.removeAll()
            programmaticNavigationClaims.removeAll()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let input = JournalWindowNavigationPolicyInput(
                requestURL: navigationAction.request.url,
                targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
                targetFrameIsNil: navigationAction.targetFrame == nil,
                shouldPerformDownload: navigationAction.shouldPerformDownload,
                currentBaseURL: session.currentBaseURL
            )

            switch JournalWindowPolicy.decideNavigationAction(input) {
            case .allow:
                beginAllowedNavigationIfNeeded(input)
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .cancelAndOpenExternal(let url):
                openExternalURL(url)
                decisionHandler(.cancel)
            case .cancelAndLoadInWindow(let url):
                loadInCurrentWindow(url, webView: webView)
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(
                JournalWindowPolicy.allowsNavigationResponse(canShowMIMEType: navigationResponse.canShowMIMEType)
                    ? .allow
                    : .cancel
            )
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            handleNavigationEvent(.started(generation: generation(for: navigation)))
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            handleNavigationEvent(.committed(generation: generation(for: navigation)))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            handleNavigationEvent(.finished(generation: generation(for: navigation)))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleFailure(navigation: navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(navigation: navigation, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            handleNavigationEvent(.contentProcessTerminated(generation: session.generation))
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let input = JournalWindowNavigationPolicyInput(
                requestURL: navigationAction.request.url,
                targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
                targetFrameIsNil: true,
                shouldPerformDownload: navigationAction.shouldPerformDownload,
                currentBaseURL: session.currentBaseURL
            )
            switch JournalWindowPolicy.decideNavigationAction(input) {
            case .cancelAndLoadInWindow(let url):
                loadInCurrentWindow(url, webView: webView)
            case .cancelAndOpenExternal(let url):
                openExternalURL(url)
            case .allow, .cancel:
                break
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        private func beginAllowedNavigationIfNeeded(_ input: JournalWindowNavigationPolicyInput) {
            guard input.targetFrameIsMainFrame != false,
                  let url = input.requestURL
            else {
                return
            }
            if programmaticNavigationClaims.consume(url: url) != nil {
                return
            }
            guard let baseURL = session.currentBaseURL else { return }
            _ = session.beginAllowedNavigation(url: url, baseURL: baseURL)
        }

        private func loadInCurrentWindow(_ url: URL, webView: WKWebView) {
            guard let baseURL = session.currentBaseURL else { return }
            let command = session.beginDirectLoad(url: url, baseURL: baseURL)
            prepareProgrammaticLoad(command)
            let navigation = webView.load(URLRequest(url: command.url))
            register(navigation: navigation, generation: command.generation)
            lastLoadedGeneration = command.generation
        }

        private func handleFailure(navigation: WKNavigation!, error: Error) {
            let failure: JournalWindowNavigationFailure = JournalWindowPolicy.isSelfInflictedCancellation(error)
                ? .selfInflictedCancellation
                : .other
            handleNavigationEvent(.failed(generation: generation(for: navigation), failure: failure))
        }

        private func handleNavigationEvent(_ event: JournalWindowNavigationEvent) {
            session.handle(event)
            if event.isTerminal {
                programmaticNavigationClaims.remove(generation: event.generation)
            }
        }

        private func generation(for navigation: WKNavigation?) -> UInt64 {
            guard let navigation else { return session.generation }
            return generationByNavigation[ObjectIdentifier(navigation)] ?? session.generation
        }
    }
}
