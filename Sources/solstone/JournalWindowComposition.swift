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

    mutating func handle(_ event: JournalWindowNavigationEvent) {
        guard event.generation == generation else { return }

        switch event {
        case .started, .committed:
            state = .loading
        case .finished:
            state = .loaded
        case .failed(_, let failure):
            switch failure {
            case .selfInflictedCancellation:
                break
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

    func handle(_ event: JournalWindowNavigationEvent) {
        composition.handle(event)
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
