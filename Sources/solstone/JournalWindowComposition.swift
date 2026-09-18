// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os
import SolstoneCore

public struct JournalWindowDestination: Sendable, Equatable {
    public let path: String
    public let query: String?
    public let fragment: String?

    public static let root = JournalWindowDestination(validatedPath: "/", query: nil, fragment: nil)

    public init?(path: String, query: String? = nil, fragment: String? = nil) {
        guard let normalizedPath = Self.normalizePath(path) else {
            return nil
        }
        let normalizedQuery: String?
        if let query {
            guard let value = Self.normalizeQuery(query) else { return nil }
            normalizedQuery = value
        } else {
            normalizedQuery = nil
        }
        let normalizedFragment: String?
        if let fragment {
            guard let value = Self.normalizeFragment(fragment) else { return nil }
            normalizedFragment = value
        } else {
            normalizedFragment = nil
        }
        self.init(validatedPath: normalizedPath, query: normalizedQuery, fragment: normalizedFragment)
    }

    private init(validatedPath path: String, query: String?, fragment: String?) {
        self.path = path
        self.query = query
        self.fragment = fragment
    }

    private static func normalizePath(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return "/"
        }
        guard !value.contains("://"),
              !value.contains("?"),
              !value.contains("#")
        else {
            return nil
        }
        if !value.hasPrefix("/") {
            value = "/" + value
        }
        return value
    }

    private static func normalizeQuery(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("?") {
            value.removeFirst()
        }
        guard !value.contains("#") else { return nil }
        return value.isEmpty ? nil : value
    }

    private static func normalizeFragment(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard !value.contains("#") else { return nil }
        return value.isEmpty ? nil : value
    }
}

internal struct JournalOpenIntent: Sendable, Equatable, Identifiable {
    let id: UInt64
    let destination: JournalWindowDestination
}

internal enum JournalWindowAXState: CaseIterable, Sendable, Equatable {
    case held
    case loading
    case loaded
    case error
    case linkDown
}

internal enum JournalWindowVerdictClass: Sendable, Equatable {
    case transient
    case nonTransient
}

internal enum JournalWindowOverlayAction: Equatable {
    case none
    case retry
    case openSettings
    case connectJournal
}

func journalWindowVerdictClass(
    failureCause: JournalConnectionFailureCause?,
    axToken: String
) -> JournalWindowVerdictClass {
    guard let failureCause else {
        if axToken == PairingConnectionAXState.connecting.axToken {
            return .transient
        }
        if axToken == PairingConnectionAXState.connected.axToken {
            return .transient
        }
        return .nonTransient
    }

    switch failureCause {
    case .noRoute, .unreachable, .loopbackUnavailable:
        return .transient
    case .revoked, .keychainUnavailable, .mismatch, .notServing, .notEntitled:
        return .nonTransient
    }
}

private func journalWindowOverlayAction(
    failureCause: JournalConnectionFailureCause?,
    axToken: String
) -> JournalWindowOverlayAction {
    guard let failureCause else {
        if axToken == PairingConnectionAXState.connecting.axToken {
            return .none
        }
        if axToken == PairingConnectionAXState.connected.axToken {
            return .none
        }
        return .connectJournal
    }

    switch failureCause {
    case .noRoute, .unreachable, .loopbackUnavailable:
        return .retry
    case .revoked, .keychainUnavailable, .mismatch, .notServing:
        return .openSettings
    case .notEntitled:
        return .none
    }
}

internal struct JournalWindowLoadCommand: Sendable, Equatable {
    let url: URL
    let baseURL: URL
    let generation: UInt64
}

internal enum JournalWindowNavigationFailure: Sendable, Equatable {
    case selfInflictedCancellation
    case other
}

internal enum JournalWindowNavigationEvent: Sendable, Equatable {
    case started(generation: UInt64)
    case committed(generation: UInt64)
    case finished(generation: UInt64)
    case failed(generation: UInt64, failure: JournalWindowNavigationFailure)
    case contentProcessTerminated(generation: UInt64)

    var generation: UInt64 {
        switch self {
        case .started(let generation),
             .committed(let generation),
             .finished(let generation),
             .failed(let generation, _),
             .contentProcessTerminated(let generation):
            return generation
        }
    }
}

internal struct JournalWindowComposition: Sendable, Equatable {
    private(set) var state: JournalWindowAXState = .held
    private(set) var destination: JournalWindowDestination = .root
    private(set) var generation: UInt64 = 0
    private(set) var currentBaseURL: URL?
    private(set) var loadCommand: JournalWindowLoadCommand?
    private(set) var hasDisplayedContent = false
    private(set) var committedBaseURL: URL?
    private(set) var committedDestination: JournalWindowDestination?

    var showsWebView: Bool { state != .held }

    mutating func open(
        destination newDestination: JournalWindowDestination,
        resolvedBase: ResolvedHomeBase,
        verdictClass: JournalWindowVerdictClass = .transient
    ) -> JournalWindowLoadCommand? {
        destination = newDestination
        return beginLoad(resolvedBase: resolvedBase, verdictClass: verdictClass)
    }

    mutating func reload(
        resolvedBase: ResolvedHomeBase,
        verdictClass: JournalWindowVerdictClass = .transient
    ) -> JournalWindowLoadCommand? {
        if case .url(let base) = resolvedBase,
           let candidate = Self.composeLoadCommand(
               base: base,
               destination: destination,
               generation: generation
           ),
           candidate.baseURL == currentBaseURL,
           state == .loading || state == .loaded {
            return nil
        }

        return beginLoad(resolvedBase: resolvedBase, verdictClass: verdictClass)
    }

    mutating func beginDirectLoad(url: URL, baseURL: URL) -> JournalWindowLoadCommand {
        if let derived = Self.destination(for: url, relativeTo: baseURL) {
            destination = derived
        }
        generation += 1
        state = .loading
        currentBaseURL = baseURL
        let command = JournalWindowLoadCommand(url: url, baseURL: baseURL, generation: generation)
        loadCommand = command
        return command
    }

    mutating func beginUserInitiatedNavigation(url: URL, baseURL: URL) -> UInt64 {
        applyNavigationContinuation(url: url, baseURL: baseURL)
        generation += 1
        loadCommand = nil
        return generation
    }

    mutating func continueCurrentNavigation(url: URL, baseURL: URL) {
        applyNavigationContinuation(url: url, baseURL: baseURL)
    }

    mutating func applySameDocumentNavigation(url: URL, baseURL: URL) {
        if let derived = Self.destination(for: url, relativeTo: baseURL) {
            destination = derived
        }
        currentBaseURL = baseURL
    }

    mutating func noteMainFrameCommit(committedURL: URL?) {
        hasDisplayedContent = true
        if let base = currentBaseURL {
            committedBaseURL = base
            if let committedURL, let derived = Self.destination(for: committedURL, relativeTo: base) {
                committedDestination = derived
            }
        }
    }

    mutating func handle(_ event: JournalWindowNavigationEvent) {
        guard event.generation == generation else { return }

        if state == .linkDown {
            switch event {
            case .started, .committed, .finished, .failed:
                return
            case .contentProcessTerminated:
                enterHeld()
                return
            }
        }

        switch event {
        case .started, .committed:
            state = .loading
        case .finished:
            state = .loaded
        case .failed(_, let failure):
            switch failure {
            case .selfInflictedCancellation:
                state = hasDisplayedContent ? .loaded : .error
            case .other:
                state = .error
            }
        case .contentProcessTerminated:
            clearDisplayedContentLatch()
            state = .error
        }
    }

    mutating func handleUnregisteredFailure(isSelfInflictedCancellation: Bool) {
        guard state == .loading,
              loadCommand != nil,
              !isSelfInflictedCancellation
        else {
            return
        }
        state = .error
    }

    private mutating func beginLoad(
        resolvedBase: ResolvedHomeBase,
        verdictClass: JournalWindowVerdictClass
    ) -> JournalWindowLoadCommand? {
        if case .url(let base) = resolvedBase,
           let command = Self.composeLoadCommand(
            base: base,
            destination: destination,
            generation: generation &+ 1
           ) {
            if state == .linkDown, shouldRecoverToLoaded(command: command) {
                generation += 1
                state = .loaded
                loadCommand = nil
                return nil
            }

            generation += 1
            state = .loading
            currentBaseURL = command.baseURL
            loadCommand = command
            return command
        }

        generation += 1
        loadCommand = nil
        if hasDisplayedContent, verdictClass == .transient {
            state = .linkDown
            return nil
        }

        enterHeld()
        return nil
    }

    private func shouldRecoverToLoaded(command: JournalWindowLoadCommand) -> Bool {
        guard let committedBaseURL, let committedDestination else {
            return false
        }
        return command.baseURL == committedBaseURL
            && Self.destinationsMatchIgnoringFragment(destination, committedDestination)
    }

    private mutating func enterHeld() {
        state = .held
        currentBaseURL = nil
        loadCommand = nil
        clearDisplayedContentLatch()
    }

    private mutating func clearDisplayedContentLatch() {
        hasDisplayedContent = false
        committedBaseURL = nil
        committedDestination = nil
    }

    static func destinationsMatchIgnoringFragment(
        _ lhs: JournalWindowDestination,
        _ rhs: JournalWindowDestination
    ) -> Bool {
        lhs.path == rhs.path && lhs.query == rhs.query
    }

    private mutating func applyNavigationContinuation(url: URL, baseURL: URL) {
        if let derived = Self.destination(for: url, relativeTo: baseURL) {
            destination = derived
        }
        state = .loading
        currentBaseURL = baseURL
    }

    static func composeLoadCommand(
        base: String,
        destination: JournalWindowDestination,
        generation: UInt64
    ) -> JournalWindowLoadCommand? {
        guard var baseComponents = URLComponents(string: base),
              let scheme = baseComponents.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseComponents.host != nil
        else {
            return nil
        }

        let basePath = baseComponents.percentEncodedPath
        let destinationPath = destination.path
        let joinedPath: String
        if basePath.isEmpty || basePath == "/" {
            joinedPath = destinationPath
        } else {
            joinedPath = basePath.trimmingTrailingSlashes() + destinationPath
        }

        baseComponents.percentEncodedPath = joinedPath.isEmpty ? "/" : joinedPath
        baseComponents.percentEncodedQuery = destination.query
        baseComponents.percentEncodedFragment = destination.fragment

        guard let url = baseComponents.url else { return nil }

        var baseOnly = baseComponents
        baseOnly.percentEncodedPath = basePath.isEmpty ? "/" : basePath
        baseOnly.percentEncodedQuery = nil
        baseOnly.percentEncodedFragment = nil
        guard let baseURL = baseOnly.url else { return nil }

        return JournalWindowLoadCommand(url: url, baseURL: baseURL, generation: generation)
    }

    static func destination(for url: URL, relativeTo baseURL: URL) -> JournalWindowDestination? {
        guard let origin = JournalWindowOrigin(url: baseURL),
              origin == JournalWindowOrigin(url: url)
        else {
            return nil
        }

        let basePath = (URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "")
            .trimmingTrailingSlashes()
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        if !basePath.isEmpty, path.hasPrefix(basePath) {
            path.removeFirst(basePath.count)
        }
        if path.isEmpty {
            path = "/"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }

        return JournalWindowDestination(
            path: path,
            query: url.query,
            fragment: url.fragment
        )
    }
}

@MainActor
@Observable
internal final class JournalWindowSession {
    typealias ResolveHomeBase = @MainActor @Sendable () async -> ResolvedHomeBase
    typealias ConnectionVerdictProvider = @MainActor () -> JournalConnectionVerdict
    typealias PairingBusyProvider = @MainActor () -> Bool
    typealias RecoveryDispatch = @MainActor (JournalConnectionRecoveryAction) async -> Void
    typealias SettingsRouter = @MainActor () -> Void

    private let resolveHomeBase: ResolveHomeBase
    private let connectionVerdict: ConnectionVerdictProvider
    private let pairingBusy: PairingBusyProvider
    private let recover: RecoveryDispatch
    private let openSettings: SettingsRouter
    private var composition = JournalWindowComposition()

    var state: JournalWindowAXState { composition.state }
    var destination: JournalWindowDestination { composition.destination }
    var generation: UInt64 { composition.generation }
    var loadCommand: JournalWindowLoadCommand? { composition.loadCommand }
    var currentBaseURL: URL? { composition.currentBaseURL }
    var hasDisplayedContent: Bool { composition.hasDisplayedContent }
    var committedBaseURL: URL? { composition.committedBaseURL }
    var committedDestination: JournalWindowDestination? { composition.committedDestination }
    var showsWebView: Bool { composition.showsWebView }

    var headline: String { liveVerdict.message }
    var caption: String? { liveVerdict.caption }
    var overlayAction: JournalWindowOverlayAction {
        journalWindowOverlayAction(failureCause: liveVerdict.failureCause, axToken: liveVerdict.axToken)
    }
    var overlayButtonTitle: String? {
        switch overlayAction {
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
    var isPairingBusy: Bool { pairingBusy() }
    var retryEnabled: Bool { overlayAction == .retry && !isPairingBusy }

    private var liveVerdict: JournalConnectionVerdict { connectionVerdict() }

    init(
        resolveHomeBase: @escaping ResolveHomeBase,
        connectionVerdict: @escaping ConnectionVerdictProvider = { .neutral },
        pairingBusy: @escaping PairingBusyProvider = { false },
        recover: @escaping RecoveryDispatch = { _ in },
        openSettings: @escaping SettingsRouter = {}
    ) {
        self.resolveHomeBase = resolveHomeBase
        self.connectionVerdict = connectionVerdict
        self.pairingBusy = pairingBusy
        self.recover = recover
        self.openSettings = openSettings
    }

    @discardableResult
    func open(destination: JournalWindowDestination) async -> JournalWindowLoadCommand? {
        let resolved = await resolveHomeBase()
        logBaseOutcome(resolved)
        let command = composition.open(
            destination: destination,
            resolvedBase: resolved,
            verdictClass: currentVerdictClass()
        )
        logLoadCommand(command)
        return command
    }

    @discardableResult
    func reloadRetainedDestination() async -> JournalWindowLoadCommand? {
        let resolved = await resolveHomeBase()
        logBaseOutcome(resolved)
        let command = composition.reload(resolvedBase: resolved, verdictClass: currentVerdictClass())
        logLoadCommand(command)
        return command
    }

    @discardableResult
    func retry() async -> JournalWindowLoadCommand? {
        await reloadRetainedDestination()
    }

    func performHonestyRetry() async {
        guard retryEnabled else { return }
        let action = journalConnectionRecoveryAction(for: liveVerdict.failureCause)
        await recover(action)
    }

    func performHonestyRoute() {
        switch overlayAction {
        case .openSettings, .connectJournal:
            openSettings()
        case .none, .retry:
            break
        }
    }

    @discardableResult
    func beginDirectLoad(url: URL, baseURL: URL) -> JournalWindowLoadCommand {
        composition.beginDirectLoad(url: url, baseURL: baseURL)
    }

    func beginUserInitiatedNavigation(url: URL, baseURL: URL) -> UInt64 {
        composition.beginUserInitiatedNavigation(url: url, baseURL: baseURL)
    }

    func continueCurrentNavigation(url: URL, baseURL: URL) {
        composition.continueCurrentNavigation(url: url, baseURL: baseURL)
    }

    func applySameDocumentNavigation(url: URL, baseURL: URL) {
        composition.applySameDocumentNavigation(url: url, baseURL: baseURL)
    }

    func noteMainFrameCommit(committedURL: URL?) {
        Logger.journal.info("journal-window: nav commit generation=\(self.generation, privacy: .public)")
        composition.noteMainFrameCommit(committedURL: committedURL)
    }

    func handle(_ event: JournalWindowNavigationEvent) {
        Logger.journal.info(
            "journal-window: nav event=\(self.navigationEventName(event), privacy: .public) generation=\(event.generation, privacy: .public)"
        )
        composition.handle(event)
    }

    func handleUnregisteredFailure(isSelfInflictedCancellation: Bool) {
        composition.handleUnregisteredFailure(isSelfInflictedCancellation: isSelfInflictedCancellation)
    }

    private func currentVerdictClass() -> JournalWindowVerdictClass {
        journalWindowVerdictClass(failureCause: liveVerdict.failureCause, axToken: liveVerdict.axToken)
    }

    private func logBaseOutcome(_ resolved: ResolvedHomeBase) {
        switch resolved {
        case .held:
            Logger.journal.info("journal-window: base held")
        case .url(let base):
            logPublicHostPort(of: base, tag: "journal-window: base")
        }
    }

    private func logLoadCommand(_ command: JournalWindowLoadCommand?) {
        guard let command else { return }
        logPublicHostPort(of: command.url.absoluteString, tag: "journal-window: load")
    }

    private func logPublicHostPort(of raw: String, tag: String) {
        let url = URL(string: raw)
        let host = url?.host ?? ""
        let port = url?.port ?? defaultPort(for: url?.scheme)
        let path = url?.path ?? ""
        let query = url?.query ?? ""
        let fragment = url?.fragment ?? ""
        Logger.journal.info(
            "\(tag, privacy: .public) host=\(host, privacy: .public) port=\(port, privacy: .public) path=\(path, privacy: .private) query=\(query, privacy: .private) fragment=\(fragment, privacy: .private)"
        )
    }

    private func defaultPort(for scheme: String?) -> Int {
        scheme?.lowercased() == "https" ? 443 : 80
    }

    private func navigationEventName(_ event: JournalWindowNavigationEvent) -> String {
        switch event {
        case .started:
            return "started"
        case .committed:
            return "committed"
        case .finished:
            return "finished"
        case .failed(_, let failure):
            switch failure {
            case .selfInflictedCancellation:
                return "failed-cancelled"
            case .other:
                return "failed"
            }
        case .contentProcessTerminated:
            return "process-terminated"
        }
    }
}

internal enum JournalWindowWebViewNavigationActionResult: Equatable {
    case allow
    case cancel
    case loadInCurrentWindow(JournalWindowLoadCommand)
}

@MainActor
internal struct JournalWindowNavigationBindings {
    private struct Entry {
        let generation: UInt64
        // Measured WebKit behavior: five sequential navigations in one WKWebView reused
        // WKNavigation identities on page-driven loads and webView.load() returns. Terminal
        // release is primary; retaining is the backstop for a registered load WebKit drops
        // without start/failure, with the strictly-older prune bounding the leak.
        let navigation: AnyObject
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    var count: Int { entries.count }

    mutating func register(_ navigation: AnyObject?, generation: UInt64) {
        pruneEntries(olderThan: generation)
        guard let navigation else { return }
        entries[ObjectIdentifier(navigation)] = Entry(generation: generation, navigation: navigation)
    }

    mutating func bind(_ navigation: AnyObject?, currentGeneration: UInt64) -> UInt64? {
        guard let navigation else { return nil }
        let identifier = ObjectIdentifier(navigation)
        if let entry = entries[identifier] {
            return entry.generation
        }
        pruneEntries(olderThan: currentGeneration)
        entries[identifier] = Entry(generation: currentGeneration, navigation: navigation)
        return currentGeneration
    }

    func generation(for navigation: AnyObject?) -> UInt64? {
        guard let navigation else { return nil }
        return entries[ObjectIdentifier(navigation)]?.generation
    }

    mutating func release(_ navigation: AnyObject?) {
        guard let navigation else { return }
        entries.removeValue(forKey: ObjectIdentifier(navigation))
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    private mutating func pruneEntries(olderThan generation: UInt64) {
        entries = entries.filter { $0.value.generation >= generation }
    }
}

@MainActor
internal final class JournalWindowWebViewSeam {
    private var session: JournalWindowSession
    private var openExternalURL: JournalWindowExternalURLOpener
    private var bindings = JournalWindowNavigationBindings()
    private var lastCommittedDocumentURL: URL?
    private var lastLoadedGeneration: UInt64?

    var bindingCount: Int { bindings.count }

    init(
        session: JournalWindowSession,
        openExternalURL: @escaping JournalWindowExternalURLOpener
    ) {
        self.session = session
        self.openExternalURL = openExternalURL
    }

    func update(
        session: JournalWindowSession,
        openExternalURL: @escaping JournalWindowExternalURLOpener
    ) {
        self.session = session
        self.openExternalURL = openExternalURL
    }

    func prepareLoadCommandForUpdate(_ command: JournalWindowLoadCommand?) -> JournalWindowLoadCommand? {
        guard let command,
              lastLoadedGeneration != command.generation
        else {
            return nil
        }
        return command
    }

    func registerAppInitiatedLoad(navigation: AnyObject?, generation: UInt64) {
        bindings.register(navigation, generation: generation)
        lastLoadedGeneration = generation
    }

    func decideNavigationAction(
        requestURL: URL?,
        targetFrameIsMainFrame: Bool?,
        targetFrameIsNil: Bool,
        shouldPerformDownload: Bool,
        isUserInitiated: Bool
    ) -> JournalWindowWebViewNavigationActionResult {
        let input = JournalWindowNavigationPolicyInput(
            requestURL: requestURL,
            targetFrameIsMainFrame: targetFrameIsMainFrame,
            targetFrameIsNil: targetFrameIsNil,
            shouldPerformDownload: shouldPerformDownload,
            currentBaseURL: session.currentBaseURL,
            isLinkDown: session.state == .linkDown
        )

        switch JournalWindowPolicy.decideNavigationAction(input) {
        case .allow:
            beginAllowedNavigationIfNeeded(input, isUserInitiated: isUserInitiated)
            return .allow
        case .cancel:
            return .cancel
        case .cancelAndOpenExternal(let url):
            openExternalURL(url)
            return .cancel
        case .cancelAndLoadInWindow(let url):
            return beginLoadInCurrentWindow(url)
        }
    }

    func decideNewWindowNavigationAction(
        requestURL: URL?,
        targetFrameIsMainFrame: Bool?,
        targetFrameIsNil: Bool,
        shouldPerformDownload: Bool
    ) -> JournalWindowWebViewNavigationActionResult {
        let input = JournalWindowNavigationPolicyInput(
            requestURL: requestURL,
            targetFrameIsMainFrame: targetFrameIsMainFrame,
            targetFrameIsNil: targetFrameIsNil,
            shouldPerformDownload: shouldPerformDownload,
            currentBaseURL: session.currentBaseURL,
            isLinkDown: session.state == .linkDown
        )

        switch JournalWindowPolicy.decideNavigationAction(input) {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .cancelAndOpenExternal(let url):
            openExternalURL(url)
            return .cancel
        case .cancelAndLoadInWindow(let url):
            return beginLoadInCurrentWindow(url)
        }
    }

    func decideNavigationResponse(canShowMIMEType: Bool) -> Bool {
        JournalWindowPolicy.allowsNavigationResponse(canShowMIMEType: canShowMIMEType)
    }

    func didStartProvisionalNavigation(_ navigation: AnyObject?) {
        guard let generation = bindings.bind(navigation, currentGeneration: session.generation) else { return }
        session.handle(.started(generation: generation))
    }

    func didCommit(navigation: AnyObject?, committedDocumentURL: URL?) {
        lastCommittedDocumentURL = committedDocumentURL
        session.noteMainFrameCommit(committedURL: committedDocumentURL)
        guard let generation = bindings.generation(for: navigation) else { return }
        session.handle(.committed(generation: generation))
    }

    func didFinish(navigation: AnyObject?) {
        let generation = bindings.generation(for: navigation)
        if let generation {
            session.handle(.finished(generation: generation))
        }
        bindings.release(navigation)
    }

    func didFail(navigation: AnyObject?, isSelfInflictedCancellation: Bool) {
        let error: Error
        if isSelfInflictedCancellation {
            error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        } else {
            error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        }
        didFail(navigation: navigation, error: error)
    }

    func didFail(navigation: AnyObject?, error: Error) {
        let isSelfInflictedCancellation = JournalWindowPolicy.isSelfInflictedCancellation(error)
        Logger.journal.error(
            "journal-window: fail error=\(error.localizedDescription, privacy: .public) generation=\(self.session.generation, privacy: .public)"
        )
        let generation = bindings.generation(for: navigation)
        if let generation {
            let failure: JournalWindowNavigationFailure = isSelfInflictedCancellation
                ? .selfInflictedCancellation
                : .other
            session.handle(.failed(generation: generation, failure: failure))
            bindings.release(navigation)
            return
        }
        if bindingCount == 0 {
            session.handleUnregisteredFailure(isSelfInflictedCancellation: isSelfInflictedCancellation)
        }
    }

    func contentProcessTerminated() {
        // Recovery comes from retry's generation bump plus the strictly-older prune; this
        // is deliberately not another terminal cleanup path.
        session.handle(.contentProcessTerminated(generation: session.generation))
    }

    func tearDown() {
        bindings.removeAll()
    }

    private func beginAllowedNavigationIfNeeded(
        _ input: JournalWindowNavigationPolicyInput,
        isUserInitiated: Bool
    ) {
        guard input.targetFrameIsMainFrame != false,
              let url = input.requestURL
        else {
            return
        }
        guard let baseURL = session.currentBaseURL else { return }
        if JournalWindowPolicy.isSameDocumentNavigation(from: lastCommittedDocumentURL, to: url) {
            // WebKit sends no terminal callback for same-document fragment changes.
            session.applySameDocumentNavigation(url: url, baseURL: baseURL)
            return
        }
        if isUserInitiated {
            _ = session.beginUserInitiatedNavigation(url: url, baseURL: baseURL)
        } else {
            session.continueCurrentNavigation(url: url, baseURL: baseURL)
        }
    }

    private func beginLoadInCurrentWindow(_ url: URL) -> JournalWindowWebViewNavigationActionResult {
        guard let baseURL = session.currentBaseURL else { return .cancel }
        let command = session.beginDirectLoad(url: url, baseURL: baseURL)
        return .loadInCurrentWindow(command)
    }
}

internal struct JournalWindowOrigin: Sendable, Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased()
        else {
            return nil
        }

        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

internal enum JournalWindowNavigationDecision: Sendable, Equatable {
    case allow
    case cancel
    case cancelAndOpenExternal(URL)
    case cancelAndLoadInWindow(URL)
}

internal struct JournalWindowNavigationPolicyInput: Sendable, Equatable {
    let requestURL: URL?
    let targetFrameIsMainFrame: Bool?
    let targetFrameIsNil: Bool
    let shouldPerformDownload: Bool
    let currentBaseURL: URL?
    let isLinkDown: Bool

    init(
        requestURL: URL?,
        targetFrameIsMainFrame: Bool?,
        targetFrameIsNil: Bool,
        shouldPerformDownload: Bool,
        currentBaseURL: URL?,
        isLinkDown: Bool = false
    ) {
        self.requestURL = requestURL
        self.targetFrameIsMainFrame = targetFrameIsMainFrame
        self.targetFrameIsNil = targetFrameIsNil
        self.shouldPerformDownload = shouldPerformDownload
        self.currentBaseURL = currentBaseURL
        self.isLinkDown = isLinkDown
    }
}

internal enum JournalWindowPolicy {
    static func decideNavigationAction(_ input: JournalWindowNavigationPolicyInput) -> JournalWindowNavigationDecision {
        guard let url = input.requestURL else {
            return .cancel
        }

        if input.shouldPerformDownload {
            return .cancel
        }

        if input.targetFrameIsMainFrame == false {
            return .allow
        }

        guard let baseURL = input.currentBaseURL,
              let baseOrigin = JournalWindowOrigin(url: baseURL),
              let targetOrigin = JournalWindowOrigin(url: url)
        else {
            return .cancelAndOpenExternal(url)
        }

        let onOrigin = baseOrigin == targetOrigin
        let decision: JournalWindowNavigationDecision
        if input.targetFrameIsNil {
            decision = onOrigin ? .cancelAndLoadInWindow(url) : .cancelAndOpenExternal(url)
        } else {
            decision = onOrigin ? .allow : .cancelAndOpenExternal(url)
        }

        if input.isLinkDown {
            switch decision {
            case .allow, .cancelAndLoadInWindow:
                return .cancel
            case .cancel, .cancelAndOpenExternal:
                return decision
            }
        }

        return decision
    }

    static func allowsNavigationResponse(canShowMIMEType: Bool) -> Bool {
        canShowMIMEType
    }

    static func isSameDocumentNavigation(from currentDocumentURL: URL?, to target: URL) -> Bool {
        guard let currentDocumentURL,
              let targetComponents = URLComponents(url: target, resolvingAgainstBaseURL: false),
              targetComponents.percentEncodedFragment != nil,
              let currentComponents = URLComponents(url: currentDocumentURL, resolvingAgainstBaseURL: false),
              let currentOrigin = JournalWindowOrigin(url: currentDocumentURL),
              let targetOrigin = JournalWindowOrigin(url: target),
              currentOrigin == targetOrigin
        else {
            return false
        }

        return currentComponents.percentEncodedPath == targetComponents.percentEncodedPath
            && currentComponents.percentEncodedQuery == targetComponents.percentEncodedQuery
    }

    static func isSelfInflictedCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        // WebKitErrorFrameLoadInterruptedByPolicyChange is deprecated; use the stable domain/code pair.
        return nsError.domain == "WebKitErrorDomain" && nsError.code == 102
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var value = self
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
