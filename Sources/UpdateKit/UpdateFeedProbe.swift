// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Sparkle

/// Reads the update feed once while an update is already waiting to install.
///
/// Sparkle 2 resumes a waiting update without reading the feed again, so it never learns
/// that a newer release came out. This makes the one request Sparkle's own daily check
/// would have made: the same feed address, Sparkle's user agent, nothing else. Sparkle
/// still downloads and verifies whatever replaces the waiting update.
public enum UpdateFeedProbe {
    public typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let defaultOrigin = URL(string: "https://updates.solstone.app")!

    /// The origin Sparkle's patched downloader allows: the explicit operator feed
    /// override when one is set, otherwise the production update host.
    static func approvedOrigin(feedOverride: String?) -> URL {
        guard let feedOverride, let url = URL(string: feedOverride) else { return defaultOrigin }
        return url
    }

    /// The same test the patched Sparkle downloader applies to every address it contacts.
    static func isApproved(_ url: URL, origin: URL) -> Bool {
        guard
            url.scheme?.lowercased() == "https",
            origin.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(), !host.isEmpty,
            let originHost = origin.host?.lowercased(), !originHost.isEmpty,
            host == originHost,
            (url.port ?? 443) == (origin.port ?? 443),
            url.user == nil, url.password == nil,
            origin.user == nil, origin.password == nil
        else {
            return false
        }
        return true
    }

    static func request(feedURL: URL, userAgent: String) -> URLRequest {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// A loader that refuses any address, including a redirect, outside the approved origin.
    static func confinedLoader(origin: URL) -> Loader {
        { request in
            guard let url = request.url, isApproved(url, origin: origin) else {
                throw URLError(.unsupportedURL)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request, delegate: ConfinedRedirects(origin: origin))
        }
    }

    /// The newest build in the feed that this Mac could install: a macOS item on the
    /// default channel whose minimum system version this Mac meets. Sparkle has the final
    /// say on what it takes; this only decides whether asking it again is worth a download.
    static func newestEligibleBuild(inAppcast data: Data, systemVersion: String) -> String? {
        let parser = XMLParser(data: data)
        let reader = AppcastItemReader()
        parser.delegate = reader
        guard parser.parse() else { return nil }

        let comparator = SUStandardVersionComparator.default
        var newest: String?
        for item in reader.items {
            guard let build = item.build, !build.isEmpty, item.channel == nil else { continue }
            if let os = item.os, os != "macos" { continue }
            if let minimum = item.minimumSystemVersion, !minimum.isEmpty,
               comparator.compareVersion(minimum, toVersion: systemVersion) == .orderedDescending {
                continue
            }
            if let current = newest, comparator.compareVersion(build, toVersion: current) != .orderedDescending {
                continue
            }
            newest = build
        }
        return newest
    }

    static func isNewer(_ build: String, than other: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(build, toVersion: other) == .orderedDescending
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

private final class ConfinedRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url, UpdateFeedProbe.isApproved(url, origin: origin) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

private final class AppcastItemReader: NSObject, XMLParserDelegate {
    struct Item {
        var build: String?
        var minimumSystemVersion: String?
        var channel: String?
        var os: String?
    }

    private(set) var items: [Item] = []
    private var current: Item?
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "item":
            current = Item()
        case "enclosure":
            if current?.build == nil, let build = attributeDict["sparkle:version"] {
                current?.build = build
            }
            current?.os = attributeDict["sparkle:os"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "item":
            if let current { items.append(current) }
            current = nil
        case "sparkle:version":
            if !value.isEmpty { current?.build = value }
        case "sparkle:minimumSystemVersion":
            current?.minimumSystemVersion = value
        case "sparkle:channel":
            current?.channel = value
        default:
            break
        }
        text = ""
    }
}
