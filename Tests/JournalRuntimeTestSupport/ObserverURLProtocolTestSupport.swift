// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public final class ObserverURLProtocolStore: @unchecked Sendable {
    public struct Response: Sendable {
        public var statusCode: Int
        public var data: Data
        public var delay: Duration
        public var error: URLError?
    }

    public let token = UUID().uuidString

    private let lock = NSLock()
    private var responses: [Response] = []
    private var routeHandlers: [@Sendable (URLRequest) -> Response?] = []
    private(set) var requests: [URLRequest] = []
    public private(set) var requestBodies: [String?] = []

    public init() {}

    public func reset() {
        lock.withLock {
            responses.removeAll()
            routeHandlers.removeAll()
            requests.removeAll()
            requestBodies.removeAll()
        }
    }

    public func registerRoute(
        matching: @escaping @Sendable (URLRequest) -> Bool,
        statusCode: Int = 200,
        body: String = "",
        delay: Duration = .zero,
        error: URLError? = nil
    ) {
        lock.withLock {
            routeHandlers.append({ req in
                guard matching(req) else { return nil }
                return Response(
                    statusCode: statusCode,
                    data: Data(body.utf8),
                    delay: delay,
                    error: error
                )
            })
        }
    }

    public func registerRoute(
        path: String,
        method: String? = nil,
        statusCode: Int = 200,
        body: String = "",
        delay: Duration = .zero,
        error: URLError? = nil
    ) {
        registerRoute(
            matching: { req in
                guard req.url?.path == path else { return false }
                if let method, req.httpMethod != method { return false }
                return true
            },
            statusCode: statusCode,
            body: body,
            delay: delay,
            error: error
        )
    }

    public func enqueue(
        statusCode: Int = 200,
        body: String = "",
        delay: Duration = .zero,
        error: URLError? = nil
    ) {
        lock.withLock {
            responses.append(Response(
                statusCode: statusCode,
                data: Data(body.utf8),
                delay: delay,
                error: error
            ))
        }
    }

    public func next(for request: URLRequest) -> Response {
        let response: Response
        lock.lock()
        requests.append(request)
        requestBodies.append(Self.bodyString(from: request))
        if let match = routeHandlers.lazy.compactMap({ $0(request) }).first {
            response = match
        } else if responses.isEmpty {
            response = Response(statusCode: 500, data: Data(), delay: .zero, error: nil)
        } else {
            response = responses.removeFirst()
        }
        lock.unlock()

        return response
    }

    public func snapshotRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    public func waitForRequestCount(_ target: Int, timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if lock.withLock({ requests.count >= target }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }
}

private final class ObserverURLProtocolStoreRegistry: @unchecked Sendable {
    static let shared = ObserverURLProtocolStoreRegistry()

    private let lock = NSLock()
    private var stores: [String: ObserverURLProtocolStore] = [:]

    func register(_ store: ObserverURLProtocolStore) {
        // Tests create only a small number of stores per run; keeping registry entries avoids lifecycle races.
        lock.withLock { stores[store.token] = store }
    }

    func store(for token: String) -> ObserverURLProtocolStore? {
        lock.withLock { stores[token] }
    }
}

final class ObserverURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard
            let token = request.value(forHTTPHeaderField: "X-Solstone-Test-Store"),
            let store = ObserverURLProtocolStoreRegistry.shared.store(for: token)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        let next = store.next(for: request)
        if next.delay > .zero {
            let seconds = Double(next.delay.components.seconds) + Double(next.delay.components.attoseconds) * 1e-18
            Thread.sleep(forTimeInterval: seconds)
        }
        if let error = next.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !next.data.isEmpty {
            client?.urlProtocol(self, didLoad: next.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

public func observerURLProtocolConfiguration(store: ObserverURLProtocolStore) -> URLSessionConfiguration {
    ObserverURLProtocolStoreRegistry.shared.register(store)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ObserverURLProtocol.self]
    config.httpAdditionalHeaders = ["X-Solstone-Test-Store": store.token]
    config.timeoutIntervalForRequest = 0
    config.timeoutIntervalForResource = 0
    return config
}
