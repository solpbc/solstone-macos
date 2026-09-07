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

    public static func makeSessionConfiguration(
        additionalProtocolClasses: [AnyClass]? = nil,
        additionalHeaders: [String: String]? = nil
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.connectionProxyDictionary = [:]
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
