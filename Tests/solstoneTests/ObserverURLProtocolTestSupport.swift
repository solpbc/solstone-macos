// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

final class ObserverURLProtocolStore: @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var data: Data
        var error: URLError?
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var requests: [URLRequest] = []
    private(set) var requestBodies: [String?] = []

    func reset() {
        lock.withLock {
            responses.removeAll()
            requests.removeAll()
            requestBodies.removeAll()
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.continuation.resume()
            }
        }
    }

    func enqueue(statusCode: Int = 200, body: String = "", error: URLError? = nil) {
        lock.withLock {
            responses.append(Response(statusCode: statusCode, data: Data(body.utf8), error: error))
        }
    }

    func next(for request: URLRequest) -> Response {
        let ready: [CheckedContinuation<Void, Never>]
        let response: Response
        lock.lock()
        requests.append(request)
        requestBodies.append(Self.bodyString(from: request))
        if responses.isEmpty {
            response = Response(statusCode: 500, data: Data(), error: nil)
        } else {
            response = responses.removeFirst()
        }
        (ready, waiters) = Self.drainWaiters(waiters, requestCount: requests.count)
        lock.unlock()

        for continuation in ready {
            continuation.resume()
        }
        return response
    }

    func snapshotRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    func waitForRequestCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume: Bool = lock.withLock {
                if requests.count >= target {
                    return true
                }
                waiters.append((target: target, continuation: continuation))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private static func drainWaiters(
        _ waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)],
        requestCount: Int
    ) -> (
        ready: [CheckedContinuation<Void, Never>],
        pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)]
    ) {
        var ready: [CheckedContinuation<Void, Never>] = []
        var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if requestCount >= waiter.target {
                ready.append(waiter.continuation)
            } else {
                pending.append(waiter)
            }
        }
        return (ready, pending)
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

final class ObserverURLProtocol: URLProtocol {
    static let store = ObserverURLProtocolStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.store.next(for: request)
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

func observerURLProtocolConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ObserverURLProtocol.self]
    config.timeoutIntervalForRequest = 0
    config.timeoutIntervalForResource = 0
    return config
}
