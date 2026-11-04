// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network

/// What makes the answering journal the right one.
public enum JournalLocalAnchor: Equatable, Sendable {
    /// This account's own journal: its socket and runtime record, or with no socket, the instance id
    /// or setup root stored in a journal folder this account holds.
    case ownJournal
    /// The journal the flow already expects, by instance id.
    case instance(String)
}

/// Where a verified journal answers. Socket when there is one, otherwise TCP on `port`.
public struct JournalLocalRoute: Equatable, Sendable {
    public let socket: String?
    public let port: Int

    public init(socket: String?, port: Int) {
        self.socket = socket
        self.port = port
    }
}

/// Reaches this account's journal over its owner socket, falling back to TCP only when no socket exists.
/// A socket that exists but is refused, belongs to someone else, or answers for a different journal is
/// never a reason to use TCP. Redirects are returned to the caller and never followed.
public struct JournalLocalHTTPClient: Sendable {
    public typealias Exchange = @Sendable (URLRequest, JournalLocalRoute) async throws -> (Data, URLResponse)

    private let ownRoots: @Sendable () async -> [String]
    private let environment: [String: String]
    private let socketExists: @Sendable (String) throws -> Bool
    private let readRecord: @Sendable (String?) throws -> JournalLocalRuntime?
    private let exchange: Exchange

    public init(
        userAgent: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ownRoots: @escaping @Sendable () async -> [String]
    ) {
        self.init(
            environment: environment,
            ownRoots: ownRoots,
            socketExists: JournalLocalEndpoint.socketExists,
            readRecord: JournalLocalEndpoint.runtimeRecord,
            exchange: { try await Self.liveExchange($0, route: $1, userAgent: userAgent) }
        )
    }

    init(
        environment: [String: String],
        ownRoots: @escaping @Sendable () async -> [String],
        socketExists: @escaping @Sendable (String) throws -> Bool,
        readRecord: @escaping @Sendable (String?) throws -> JournalLocalRuntime?,
        exchange: @escaping Exchange
    ) {
        self.environment = environment
        self.ownRoots = ownRoots
        self.socketExists = socketExists
        self.readRecord = readRecord
        self.exchange = exchange
    }

    /// Checks who is answering, then sends. Nothing reaches a journal that didn't pass.
    public func data(for request: URLRequest, anchor: JournalLocalAnchor) async throws -> (Data, URLResponse) {
        try await send(request, via: verify(anchor))
    }

    /// A one-time link that opens `target` (path, query and fragment) in a browser, made by the checked
    /// journal over its owner socket. Each call makes a live link: call it only to open one, and open the
    /// result unchanged. A journal with no socket, or whose socket answers 404 for links, predates the gate
    /// and gets its plain address. Any other failure throws `linkFailed`, never a plain address, because a
    /// gated journal answers a plain address with a page that only says how to open it.
    public func browserLink(path target: String, anchor: JournalLocalAnchor) async throws -> URL {
        let route = try await verify(anchor)
        let plain = URL(string: "http://127.0.0.1:\(route.port)\(target)")
        guard route.socket != nil else {
            guard let plain else { throw JournalLocalHTTPError.unavailable }
            return plain
        }
        var request = Self.request(Self.linkRoute)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": target])
        let answer: (Data, URLResponse)
        do {
            answer = try await send(request, via: route)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JournalLocalHTTPError.linkFailed("no answer: \(error)")
        }
        let status = (answer.1 as? HTTPURLResponse)?.statusCode ?? 0
        switch Self.linkAnswer(status: status, body: answer.0, port: route.port) {
        case .link(let link):
            return link
        case .noLinks:
            guard let plain else { throw JournalLocalHTTPError.unavailable }
            return plain
        case .failed(let cause):
            throw JournalLocalHTTPError.linkFailed(cause)
        }
    }

    static let linkRoute = "/_solstone/browser-link"

    enum LinkAnswer: Equatable {
        /// A one-time link to open unchanged.
        case link(URL)
        /// The journal predates links and its port has no gate.
        case noLinks
        /// Anything else. Never a reason to open a plain address.
        case failed(String)
    }

    /// What the journal's answer to a link request means.
    static func linkAnswer(status: Int, body: Data, port: Int) -> LinkAnswer {
        switch status {
        case 200:
            return oneTimeLink(in: body, port: port).map(LinkAnswer.link) ?? .failed("the answer held no usable link")
        case 404:
            return .noLinks
        default:
            let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
            return .failed("status \(status): \(reason ?? "no reason given")")
        }
    }

    /// Only a one-time link to the checked journal's own port is opened.
    static func oneTimeLink(in body: Data, port: Int) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = object["url"] as? String,
              let components = URLComponents(string: text),
              components.scheme == "http",
              components.host == "localhost" || components.host == "127.0.0.1",
              components.port == port,
              components.path == "/",
              components.fragment == nil,
              let items = components.queryItems, items.count == 1, items[0].name == "auth",
              let token = items[0].value, !token.isEmpty
        else { return nil }
        return URL(string: text)
    }

    public func send(_ request: URLRequest, via route: JournalLocalRoute) async throws -> (Data, URLResponse) {
        try await exchange(request, route)
    }

    public func verify(_ anchor: JournalLocalAnchor) async throws -> JournalLocalRoute {
        try Task.checkCancellation()
        let socket = try JournalLocalEndpoint.socketPath(environment: environment)
        let record = try readRecord(socket)
        if let record {
            guard (1...65535).contains(record.tcpPort), record.socketPath == socket, !record.generation.isEmpty else {
                throw JournalLocalHTTPError.unavailable
            }
        }
        let exists = try socket.map(socketExists) ?? false
        let route = JournalLocalRoute(
            socket: exists ? socket : nil,
            port: record?.tcpPort ?? JournalLocalEndpoint.defaultTCPPort
        )
        if exists {
            guard let record else { throw JournalLocalHTTPError.unavailable }
            try await requireLiveRuntime(matching: record, route: route)
            if case .instance(let expected) = anchor {
                try await requireInstance(expected, route: route)
            }
            return route
        }
        switch anchor {
        case .instance(let expected):
            try await requireInstance(expected, route: route)
        case .ownJournal:
            try await requireOwnJournalOverTCP(record: record, route: route)
        }
        return route
    }

    private func requireLiveRuntime(matching record: JournalLocalRuntime, route: JournalLocalRoute) async throws {
        let (bytes, response) = try await send(Self.request("/_solstone/local-runtime"), via: route)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JournalLocalHTTPError.unavailable }
        guard let live = try? JSONDecoder().decode(JournalLocalRuntime.self, from: bytes) else {
            throw JournalLocalHTTPError.invalidResponse
        }
        guard Self.sameRoot(live.journalRoot, record.journalRoot), live.generation == record.generation,
              live.socketPath == record.socketPath, live.tcpPort == record.tcpPort else {
            throw JournalLocalHTTPError.notOwnJournal
        }
    }

    private func requireInstance(_ expected: String, route: JournalLocalRoute) async throws {
        let (bytes, response) = try await send(Self.request("/app/link/api/identity"), via: route)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JournalLocalHTTPError.unavailable }
        guard let answered = Self.instanceID(inJSON: bytes),
              answered.caseInsensitiveCompare(expected) == .orderedSame else {
            throw JournalLocalHTTPError.notOwnJournal
        }
    }

    /// Another account's journal answers with a different instance id, so it never matches. With no
    /// journal folder of this account's own, nothing that answers counts as its own. Connection failures
    /// are thrown as they are: nothing answering is a different state from the wrong thing answering.
    private func requireOwnJournalOverTCP(record: JournalLocalRuntime?, route: JournalLocalRoute) async throws {
        let (bytes, response) = try await send(Self.request("/app/link/api/identity"), via: route)
        var candidates = await ownRoots()
        if let record { candidates.insert(record.journalRoot, at: 0) }
        let roots = candidates.filter(Self.isDirectory)
        let stored = roots.map { (root: $0, ids: Self.storedInstanceIDs(root: $0)) }
        if (response as? HTTPURLResponse)?.statusCode == 200, let answered = Self.instanceID(inJSON: bytes),
           stored.contains(where: { $0.ids.contains { $0.caseInsensitiveCompare(answered) == .orderedSame } }) {
            return
        }
        // A journal still in its first run may have no stored id yet. Its setup state names its folder.
        let unidentified = stored.filter(\.ids.isEmpty).map(\.root)
        if !unidentified.isEmpty,
           let (stateBytes, stateResponse) = try? await send(Self.request("/init/api/state"), via: route),
           (stateResponse as? HTTPURLResponse)?.statusCode == 200,
           let state = try? JSONSerialization.jsonObject(with: stateBytes) as? [String: Any],
           let path = state["journal_path"] as? String,
           unidentified.contains(where: { Self.sameRoot($0, path) }) {
            return
        }
        throw JournalLocalHTTPError.notOwnJournal
    }

    private static func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "http://localhost\(path)")!, timeoutInterval: 5)
    }

    private static func instanceID(inJSON bytes: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let id = object["instance_id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private static func storedInstanceIDs(root: String) -> [String] {
        ["link/state.json", "link/ca/state.json"].compactMap { relative in
            let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
            return (try? Data(contentsOf: url)).flatMap(instanceID(inJSON:))
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func sameRoot(_ left: String, _ right: String) -> Bool {
        URL(fileURLWithPath: left).resolvingSymlinksInPath().standardizedFileURL ==
            URL(fileURLWithPath: right).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func liveExchange(
        _ request: URLRequest,
        route: JournalLocalRoute,
        userAgent: String
    ) async throws -> (Data, URLResponse) {
        guard let originalURL = request.url, originalURL.scheme == "http",
              ["localhost", "127.0.0.1"].contains(originalURL.host) else { throw JournalLocalHTTPError.unavailable }
        if let socket = route.socket {
            guard try JournalLocalEndpoint.socketExists(socket) else { throw JournalLocalHTTPError.refused }
            return try await UnixHTTPExchange(socket: socket, request: request, userAgent: userAgent).run()
        }
        var forwarded = request
        var url = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)!
        url.host = "127.0.0.1"
        url.port = route.port
        forwarded.url = url.url
        forwarded.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        forwarded.httpShouldHandleCookies = false
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: LocalNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: forwarded)
        guard let http = response as? HTTPURLResponse, http.url == forwarded.url,
              let normalized = HTTPURLResponse(
                url: originalURL, statusCode: http.statusCode, httpVersion: "HTTP/1.1",
                headerFields: http.allHeaderFields.reduce(into: [String: String]()) {
                    $0[String(describing: $1.key)] = String(describing: $1.value)
                })
        else { throw JournalLocalHTTPError.unavailable }
        return (data, normalized)
    }
}

private final class LocalNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// All mutable exchange state is confined to queue. Cancellation and the deadline use it too.
private final class UnixHTTPExchange: @unchecked Sendable {
    let connection: NWConnection
    let request: URLRequest
    let userAgent: String
    let queue = DispatchQueue(label: "journal.local-http")
    var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    var buffer = Data()
    var cancelled = false
    var deadline: DispatchWorkItem?

    init(socket: String, request: URLRequest, userAgent: String) {
        self.connection = NWConnection(to: .unix(path: socket), using: .tcp)
        self.request = request
        self.userAgent = userAgent
    }

    func run() async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<(Data, URLResponse), any Error>) {
        self.continuation = continuation
        if cancelled { finish(.failure(CancellationError())); return }
        let timeout = DispatchWorkItem { self.finish(.failure(JournalLocalHTTPError.timedOut)) }
        deadline = timeout
        queue.asyncAfter(deadline: .now() + min(max(request.timeoutInterval, 1), 30), execute: timeout)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: self.send()
            // A socket left behind with nothing listening parks in waiting. It won't come back on its own.
            case .failed, .waiting: self.finish(.failure(JournalLocalHTTPError.unavailable))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func send() {
        guard let url = request.url else { finish(.failure(JournalLocalHTTPError.unavailable)); return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let target = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath) +
            (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let body = request.httpBody ?? Data()
        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nUser-Agent: \(userAgent)\r\nContent-Length: \(body.count)\r\n"
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            guard !["host", "connection", "content-length", "transfer-encoding", "user-agent"].contains(key.lowercased()) else { continue }
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n") else {
                finish(.failure(JournalLocalHTTPError.invalidResponse)); return
            }
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { error in
            if error != nil { self.finish(.failure(JournalLocalHTTPError.unavailable)) }
            else { self.receive() }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            guard self.continuation != nil else { return }
            if let data { self.buffer.append(data) }
            do {
                if let parsed = try JournalHTTPFraming.parse(self.buffer, url: self.request.url!, method: self.request.httpMethod ?? "GET") {
                    self.finish(.success(parsed)); return
                }
                if complete || error != nil { self.finish(.failure(JournalLocalHTTPError.invalidResponse)); return }
                self.receive()
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

/// A complete frame wins over an EOF/Network error delivered with the final bytes.
enum JournalHTTPFraming {
    static func parse(_ bytes: Data, url: URL, method: String = "GET") throws -> (Data, URLResponse)? {
        let boundary = Data("\r\n\r\n".utf8)
        guard bytes.count <= 16 * 1024 * 1024 else { throw JournalLocalHTTPError.invalidResponse }
        guard let end = bytes.range(of: boundary) else {
            if bytes.count > 65536 { throw JournalLocalHTTPError.invalidResponse }
            return nil
        }
        guard end.lowerBound <= 65536,
              let head = String(data: bytes[..<end.lowerBound], encoding: .utf8) else { throw JournalLocalHTTPError.invalidResponse }
        let lines = head.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ")
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])), let code = Int(status[1]),
              (100...599).contains(code) else { throw JournalLocalHTTPError.invalidResponse }
        if (100..<200).contains(code), code != 101 {
            return try parse(bytes.subdata(in: end.upperBound..<bytes.count), url: url, method: method)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw JournalLocalHTTPError.invalidResponse }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { throw JournalLocalHTTPError.invalidResponse }
            headers[key] = value
        }
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw JournalLocalHTTPError.invalidResponse
        }
        if method == "HEAD" || code == 204 || code == 304 { return (Data(), response) }
        let start = end.upperBound
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw JournalLocalHTTPError.invalidResponse }
            var offset = start
            var body = Data()
            while true {
                guard let line = bytes.range(of: Data("\r\n".utf8), in: offset..<bytes.count) else { return nil }
                let text = String(decoding: bytes[offset..<line.lowerBound], as: UTF8.self)
                guard let token = text.split(separator: ";", maxSplits: 1).first,
                      let chunk = Int(token, radix: 16), chunk >= 0,
                      chunk <= 16 * 1024 * 1024 - body.count else { throw JournalLocalHTTPError.invalidResponse }
                offset = line.upperBound
                if chunk == 0 {
                    if bytes.count >= offset + 2, bytes[offset..<offset+2] == Data("\r\n".utf8) { return (body, response) }
                    guard bytes.range(of: boundary, in: offset..<bytes.count) != nil else { return nil }
                    return (body, response)
                }
                guard bytes.count - offset >= chunk + 2 else { return nil }
                guard bytes[offset+chunk..<offset+chunk+2] == Data("\r\n".utf8) else { throw JournalLocalHTTPError.invalidResponse }
                body.append(bytes[offset..<offset+chunk])
                offset += chunk + 2
            }
        }
        guard let value = headers["content-length"], let length = Int(value), length >= 0,
              length <= 16 * 1024 * 1024 else { throw JournalLocalHTTPError.invalidResponse }
        guard bytes.count - start >= length else { return nil }
        return (bytes.subdata(in: start..<start+length), response)
    }
}
