// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

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

    public static func chat(day: String, eventIndex: Int) -> JournalWindowDestination {
        let encodedDay = encodePathSegment(day)
        return JournalWindowDestination(
            validatedPath: "/app/chat/\(encodedDay)",
            query: nil,
            fragment: "event-\(eventIndex)"
        )
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

    private static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
}

internal struct JournalWindowLoadCommand: Sendable, Equatable {
    let url: URL
    let baseURL: URL
    let generation: UInt64
}

internal enum JournalWindowNavigationFailure: Sendable, Equatable {
    case selfInflictedCancellation(hasDisplayedContent: Bool)
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

    mutating func open(
        destination newDestination: JournalWindowDestination,
        resolvedBase: ResolvedHomeBase
    ) -> JournalWindowLoadCommand? {
        destination = newDestination
        return beginLoad(resolvedBase: resolvedBase)
    }

    mutating func reload(resolvedBase: ResolvedHomeBase) -> JournalWindowLoadCommand? {
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

        return beginLoad(resolvedBase: resolvedBase)
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

    mutating func handle(_ event: JournalWindowNavigationEvent) {
        guard event.generation == generation else { return }

        switch event {
        case .started, .committed:
            state = .loading
        case .finished:
            state = .loaded
        case .failed(_, let failure):
            switch failure {
            case .selfInflictedCancellation(let hasDisplayedContent):
                state = hasDisplayedContent ? .loaded : .error
            case .other:
                state = .error
            }
        case .contentProcessTerminated:
            state = .error
        }
    }

    private mutating func beginLoad(resolvedBase: ResolvedHomeBase) -> JournalWindowLoadCommand? {
        generation += 1

        guard case .url(let base) = resolvedBase,
              let command = Self.composeLoadCommand(
                base: base,
                destination: destination,
                generation: generation
              )
        else {
            state = .held
            currentBaseURL = nil
            loadCommand = nil
            return nil
        }

        state = .loading
        currentBaseURL = command.baseURL
        loadCommand = command
        return command
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

    private let resolveHomeBase: ResolveHomeBase
    private var composition = JournalWindowComposition()

    var state: JournalWindowAXState { composition.state }
    var destination: JournalWindowDestination { composition.destination }
    var generation: UInt64 { composition.generation }
    var loadCommand: JournalWindowLoadCommand? { composition.loadCommand }
    var currentBaseURL: URL? { composition.currentBaseURL }

    init(resolveHomeBase: @escaping ResolveHomeBase) {
        self.resolveHomeBase = resolveHomeBase
    }

    @discardableResult
    func open(destination: JournalWindowDestination) async -> JournalWindowLoadCommand? {
        let resolved = await resolveHomeBase()
        return composition.open(destination: destination, resolvedBase: resolved)
    }

    @discardableResult
    func reloadRetainedDestination() async -> JournalWindowLoadCommand? {
        let resolved = await resolveHomeBase()
        return composition.reload(resolvedBase: resolved)
    }

    @discardableResult
    func retry() async -> JournalWindowLoadCommand? {
        await reloadRetainedDestination()
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

    func handle(_ event: JournalWindowNavigationEvent) {
        composition.handle(event)
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
    private var hasDisplayedContent = false
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
            currentBaseURL: session.currentBaseURL
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
            currentBaseURL: session.currentBaseURL
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
        hasDisplayedContent = true
        lastCommittedDocumentURL = committedDocumentURL
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
        let generation = bindings.generation(for: navigation)
        if let generation {
            let failure: JournalWindowNavigationFailure = isSelfInflictedCancellation
                ? .selfInflictedCancellation(hasDisplayedContent: hasDisplayedContent)
                : .other
            session.handle(.failed(generation: generation, failure: failure))
        }
        bindings.release(navigation)
    }

    func contentProcessTerminated() {
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

    init(
        requestURL: URL?,
        targetFrameIsMainFrame: Bool?,
        targetFrameIsNil: Bool,
        shouldPerformDownload: Bool,
        currentBaseURL: URL?
    ) {
        self.requestURL = requestURL
        self.targetFrameIsMainFrame = targetFrameIsMainFrame
        self.targetFrameIsNil = targetFrameIsNil
        self.shouldPerformDownload = shouldPerformDownload
        self.currentBaseURL = currentBaseURL
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
        if input.targetFrameIsNil {
            return onOrigin ? .cancelAndLoadInWindow(url) : .cancelAndOpenExternal(url)
        }

        return onOrigin ? .allow : .cancelAndOpenExternal(url)
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
