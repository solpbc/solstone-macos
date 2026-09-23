// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import os
import SolstoneCore
import SwiftUI
import WebKit

internal typealias JournalWindowExternalURLOpener = @MainActor @Sendable (URL) -> Void
internal typealias JournalWindowWebsiteDataStoreProvider = @MainActor @Sendable () -> WKWebsiteDataStore

private func logJournalWindowLoad(_ url: URL) {
    let host = url.host ?? ""
    let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    Logger.journal.info(
        "journal-window: load host=\(host, privacy: .public) port=\(port, privacy: .public) path=\(url.path, privacy: .private) query=\(url.query ?? "", privacy: .private) fragment=\(url.fragment ?? "", privacy: .private)"
    )
}

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
    private let connectionVerdict: JournalWindowSession.ConnectionVerdictProvider
    private let pairingBusy: JournalWindowSession.PairingBusyProvider
    private let recover: JournalWindowSession.RecoveryDispatch
    private let settingsRouter: JournalWindowSession.SettingsRouter?
    private let openExternalURL: JournalWindowExternalURLOpener
    private let websiteDataStore: JournalWindowWebsiteDataStoreProvider
    @Environment(\.openWindow) private var openWindow

    init(
        appState: AppState,
        resolveHomeBase: JournalWindowSession.ResolveHomeBase? = nil,
        connectionVerdict: JournalWindowSession.ConnectionVerdictProvider? = nil,
        pairingBusy: JournalWindowSession.PairingBusyProvider? = nil,
        recover: JournalWindowSession.RecoveryDispatch? = nil,
        settingsRouter: JournalWindowSession.SettingsRouter? = nil,
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
        self.connectionVerdict = connectionVerdict ?? { [appState] in
            appState.tunnelLifecycleOwner.connectionVerdict
        }
        self.pairingBusy = pairingBusy ?? { [appState] in
            if case .pairing = appState.pairingCoordinator.state {
                return true
            }
            return false
        }
        self.recover = recover ?? { [appState] action in
            switch action {
            case .reevaluatePairing:
                await appState.reevaluateTunnelPairing()
            case .coalescedReconnect:
                await appState.tunnelLifecycleOwner.requestCoalescedReconnect()
            default:
                await appState.reevaluateTunnelPairing()
            }
        }
        self.settingsRouter = settingsRouter
        self.openExternalURL = openExternalURL
        self.websiteDataStore = websiteDataStore
    }

    var body: some View {
        if shouldRenderJournalContent(journalWindowOpen: appState.openSceneIds.contains(.journal)) {
            JournalWindowView(
                intent: appState.journalOpenIntent,
                homeBaseChangeToken: appState.journalHomeBaseChangeToken,
                resolveHomeBase: resolveHomeBase,
                connectionVerdict: connectionVerdict,
                pairingBusy: pairingBusy,
                recover: recover,
                openSettings: settingsRouter ?? {
                    appState.pendingSettingsTab = "journal"
                    routeOpenSettingsWindow(
                        appState: appState,
                        openWindow: { openWindow(id: $0) },
                        activate: { NSApp.activate(ignoringOtherApps: true) }
                    )
                },
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
        connectionVerdict: @escaping JournalWindowSession.ConnectionVerdictProvider,
        pairingBusy: @escaping JournalWindowSession.PairingBusyProvider,
        recover: @escaping JournalWindowSession.RecoveryDispatch,
        openSettings: @escaping JournalWindowSession.SettingsRouter,
        openExternalURL: @escaping JournalWindowExternalURLOpener,
        websiteDataStore: @escaping JournalWindowWebsiteDataStoreProvider
    ) {
        self.intent = intent
        self.homeBaseChangeToken = homeBaseChangeToken
        self.openExternalURL = openExternalURL
        self.websiteDataStore = websiteDataStore
        _session = State(
            initialValue: JournalWindowSession(
                resolveHomeBase: resolveHomeBase,
                connectionVerdict: connectionVerdict,
                pairingBusy: pairingBusy,
                recover: recover,
                openSettings: openSettings
            )
        )
    }

    var body: some View {
        ZStack {
            if session.showsWebView {
                JournalWebView(
                    session: session,
                    loadCommand: session.loadCommand,
                    openExternalURL: openExternalURL,
                    websiteDataStore: websiteDataStore
                )
            }

            switch session.state {
            case .held, .linkDown:
                honestyOverlay
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

            AXStateCompanion(
                id: AXID.Journal.Browser.navigationState,
                value: session.state.axToken
            )
            .allowsHitTesting(false)
        }
        .frame(minWidth: 820, minHeight: 580)
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

    @ViewBuilder
    private var honestyOverlay: some View {
        let headline = session.headline
        let caption = session.caption
        let overlayAction = session.overlayAction
        let overlayButtonTitle = session.overlayButtonTitle
        let retryEnabled = session.retryEnabled
        let isPairingBusy = session.isPairingBusy

        VStack(spacing: 12) {
            Text(headline)
                .font(.headline)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch overlayAction {
            case .retry:
                Button(overlayButtonTitle ?? UICopy.JOURNAL_WINDOW_RETRY) {
                    Task {
                        await session.performHonestyRetry()
                    }
                }
                .disabled(!retryEnabled || isPairingBusy)
                .accessibilityIdentifier(AXID.Journal.Browser.retry)
            case .openSettings:
                Button(overlayButtonTitle ?? UICopy.SETTINGS_SETUP_JOURNAL_APP_ACTION) {
                    session.performHonestyRoute()
                }
                .accessibilityIdentifier(AXID.Journal.Browser.openSettings)
            case .connectJournal:
                Button(overlayButtonTitle ?? UICopy.SETTINGS_SETUP_JOURNAL_LINK_ACTION) {
                    session.performHonestyRoute()
                }
                .accessibilityIdentifier(AXID.Journal.Browser.connectJournal)
            case .none:
                EmptyView()
            }
        }
        .padding(24)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        webView.setAccessibilityIdentifier(AXID.Journal.Browser.webView)
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
        context.coordinator.seam.update(session: session, openExternalURL: openExternalURL)
        guard let loadCommand = context.coordinator.seam.prepareLoadCommandForUpdate(loadCommand) else { return }

        context.coordinator.loadAfterCapabilityCookie(loadCommand, webView: webView)
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
        let seam: JournalWindowWebViewSeam
        private var pendingLoadGeneration: UInt64?
        private var isTornDown = false

        init(
            session: JournalWindowSession,
            openExternalURL: @escaping JournalWindowExternalURLOpener
        ) {
            seam = JournalWindowWebViewSeam(session: session, openExternalURL: openExternalURL)
        }

        func tearDown() {
            isTornDown = true
            seam.tearDown()
        }

        /// Every app-initiated load first sets the loopback capability cookie in
        /// this web view's store and waits for it, so the load and every request
        /// its page makes carry it. A newer command or a teardown arriving while
        /// the cookie is set supersedes this one.
        func loadAfterCapabilityCookie(_ command: JournalWindowLoadCommand, webView: WKWebView) {
            guard pendingLoadGeneration != command.generation else { return }
            pendingLoadGeneration = command.generation
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            Task { @MainActor [weak self, weak webView] in
                await setLoopbackCapabilityCookie(for: command.url, in: cookieStore)
                guard let self, let webView, !self.isTornDown,
                      self.pendingLoadGeneration == command.generation
                else { return }
                logJournalWindowLoad(command.url)
                let navigation = webView.load(URLRequest(url: command.url))
                self.seam.registerAppInitiatedLoad(navigation: navigation, generation: command.generation)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let result = seam.decideNavigationAction(
                requestURL: navigationAction.request.url,
                targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
                targetFrameIsNil: navigationAction.targetFrame == nil,
                shouldPerformDownload: navigationAction.shouldPerformDownload,
                isUserInitiated: Self.isUserInitiatedNavigation(navigationAction.navigationType)
            )

            switch result {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .loadInCurrentWindow(let command):
                loadInCurrentWindow(command, webView: webView)
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(
                seam.decideNavigationResponse(canShowMIMEType: navigationResponse.canShowMIMEType)
                    ? .allow
                    : .cancel
            )
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            seam.didStartProvisionalNavigation(navigation)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            seam.didCommit(navigation: navigation, committedDocumentURL: webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            seam.didFinish(navigation: navigation)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            seam.didFail(navigation: navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            seam.didFail(navigation: navigation, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            seam.contentProcessTerminated()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let result = seam.decideNewWindowNavigationAction(
                requestURL: navigationAction.request.url,
                targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame,
                targetFrameIsNil: true,
                shouldPerformDownload: navigationAction.shouldPerformDownload
            )
            switch result {
            case .loadInCurrentWindow(let command):
                loadInCurrentWindow(command, webView: webView)
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

        private func loadInCurrentWindow(_ command: JournalWindowLoadCommand, webView: WKWebView) {
            loadAfterCapabilityCookie(command, webView: webView)
        }

        private static func isUserInitiatedNavigation(_ navigationType: WKNavigationType) -> Bool {
            switch navigationType {
            case .linkActivated, .formSubmitted, .backForward, .reload:
                return true
            case .formResubmitted, .other:
                return false
            @unknown default:
                return false
            }
        }

    }
}
