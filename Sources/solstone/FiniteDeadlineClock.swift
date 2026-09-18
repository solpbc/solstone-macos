// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public final class JournalVersionRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Refuse all HTTP redirections; send no follow-up request.
        completionHandler(nil)
    }
}

public enum BoundedLoopbackClientError: Error, Equatable, Sendable {
    case timedOut
    case responseOversized(Int)
    case invalidResponse
    case connectionFailed
}

public enum BoundedLoopbackClient {
    public static let maxResponseBodyBytes = 64 * 1024 // 64 KiB
    public static let defaultDeadline: Duration = .seconds(15)

    /// Deployed compatibility floor for concurrent streams on one carrier.
    ///
    /// The loopback tunnel maps one remote stream to each persistent TCP
    /// connection and holds it for that connection's whole life. Installed
    /// Journals may still carry this policy, so the app-owned URLSession pools
    /// must continue to fit inside it together.
    public static let deployedJournalStreamFloor = 8

    /// Concurrent streams admitted by the current Journal policy. This is not
    /// a negotiated client capability: an older Journal can still enforce the
    /// deployed compatibility floor above.
    public static let tunnelStreamBudget = 16

    /// Persistent connections the shared loopback control pool may hold.
    public static let loopbackConnectionsPerHost = 4

    /// Persistent connections the ingest pool may hold. Kept with
    /// `loopbackConnectionsPerHost` so the sum stays inside the deployed floor.
    public static let uploadConnectionsPerHost = 2

    /// The one pool for loopback control traffic.
    ///
    /// Every caller used to take `makeSession()` as a default argument, which
    /// mints a fresh `URLSession` — and therefore a fresh connection pool — on
    /// every call, and nothing ever invalidated one. The number of pools aimed
    /// at the tunnel scaled with client instantiations while deployed Journals
    /// admitted only eight streams.
    public static let sharedSession: URLSession = makeSession()

    public static func makeSessionConfiguration(
        additionalProtocolClasses: [AnyClass]? = nil,
        additionalHeaders: [String: String]? = nil
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.connectionProxyDictionary = [:]
        // Never the platform default here: it is six per host per pool, and the
        // deployed compatibility floor is eight across every app-owned pool.
        config.httpMaximumConnectionsPerHost = loopbackConnectionsPerHost
        if let additionalProtocolClasses {
            config.protocolClasses = additionalProtocolClasses
        }
        if let additionalHeaders {
            config.httpAdditionalHeaders = additionalHeaders
        }
        return config
    }

    public static func makeSession(
        configuration: URLSessionConfiguration = makeSessionConfiguration(),
        delegate: URLSessionTaskDelegate = JournalVersionRedirectDelegate()
    ) -> URLSession {
        URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public static func execute(
        request: URLRequest,
        session: URLSession,
        deadline: Duration = defaultDeadline,
        maxBytes: Int = maxResponseBodyBytes
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await withTaskDeadline(deadline) {
            var req = request
            if req.cachePolicy == .useProtocolCachePolicy {
                req.cachePolicy = .reloadIgnoringLocalCacheData
            }
            let (asyncBytes, rawResponse) = try await session.bytes(for: req)
            guard let http = rawResponse as? HTTPURLResponse else {
                throw BoundedLoopbackClientError.invalidResponse
            }
            var data = Data()
            data.reserveCapacity(min(maxBytes, 4096))
            for try await byte in asyncBytes {
                data.append(byte)
                if data.count > maxBytes {
                    throw BoundedLoopbackClientError.responseOversized(data.count)
                }
            }
            return (data: data, response: http)
        }
    }

    public static func withTaskDeadline<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BoundedLoopbackClientError.timedOut
            }

            guard let first = try await group.next() else {
                throw BoundedLoopbackClientError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}
