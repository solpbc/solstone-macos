// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
import Foundation
import Network
import Testing
@testable import solstone

/// Exercise Darwin CFNetwork itself: URLProtocol interception did not expose
/// the custom InputStream crash during the first installed browser upload.
@Suite("Browser file upload", .timeLimit(.minutes(1)))
struct BrowserFileUploadTests {
    @Test func finalizedFileReachesRealHTTPPeer() async throws {
        let peer = try BrowserUploadHTTPPeer()
        defer { peer.stop() }
        let port = try await peer.start()
        let fixture = try BrowserFileUploadFixture(port: port)
        defer { fixture.clear() }
        let upload = Task { await fixture.client.uploadStaged(prepared: fixture.prepared, lease: fixture.lease) }
        var requests = peer.requests.makeAsyncIterator()
        let body = try #require(try await requests.next())
        #expect(body == (try Data(contentsOf: fixture.prepared.bodyURL)))
        await peer.respond(status: "503 Service Unavailable", body: Data("{}".utf8))
        guard case .failure(let error) = await upload.value,
              case .serverError(let server) = error as? UploadError else {
            Issue.record("Real HTTP response must reach the browser upload delegate")
            return
        }
        #expect(server.statusCode == 503)
    }

    @Test func routeReplacementCancelsAnInFlightFileUpload() async throws {
        let peer = try BrowserUploadHTTPPeer()
        defer { peer.stop() }
        let port = try await peer.start()
        let fixture = try BrowserFileUploadFixture(port: port)
        defer { fixture.clear() }
        let upload = Task { await fixture.client.uploadStaged(prepared: fixture.prepared, lease: fixture.lease) }
        var requests = peer.requests.makeAsyncIterator()
        _ = try #require(try await requests.next())
        // The old connection holds its response. Replacing the capability at
        // the same URL must cancel it, rather than silently adopting the route.
        fixture.routes.update(BrowserIntakeRouteCapability(
            serverURL: fixture.route.serverURL, identityDigest: fixture.route.identityDigest,
            pairingGeneration: 1, transportIncarnation: 2, credentialIsCurrent: { true }
        ))
        guard case .failure(let error) = await upload.value else {
            Issue.record("A revoked upload cannot acknowledge custody")
            return
        }
        #expect((error as? URLError)?.code == .cancelled)
        #expect(!fixture.lease.isValid())
    }
}

private struct BrowserFileUploadFixture: Sendable {
    let root: URL
    let gate: BrowserUploadGate
    let routes: BrowserIntakeRouteState
    let route: BrowserIntakeRouteCapability
    let lease: BrowserUploadLease
    let prepared: PreparedIngestV3Upload
    let client: UploadClient

    init(port: UInt16) throws {
        root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("browser-file-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor")
        let store = try BrowserIntakeStore(rootURL: root.appendingPathComponent("spool"),
            projection: BrowserContractProjection(rootURL: vendor))
        _ = try store.publishEpoch(identityToken: "file-upload-pairing", nowMs: 1700000000000)
        gate = BrowserUploadGate(store: store)
        let permit = try #require(gate.currentPermit())
        routes = BrowserIntakeRouteState()
        route = BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1:\(port)",
            identityDigest: permit.identityToken, pairingGeneration: 1, transportIncarnation: 1,
            credentialIsCurrent: { true })
        routes.update(route)
        let capturedRoute = route, capturedRoutes = routes, capturedGate = gate
        routes.setOnChange { capturedGate.invalidateCurrentLease() }
        let candidateLease = gate.makeLease(permit: permit, periodId: "file-period",
            routeCheck: { capturedRoutes.matches(capturedRoute) })
        lease = try #require(candidateLease)
        let file = root.appendingPathComponent("browser_pages.jsonl")
        try Data((String(repeating: "native-file-upload-marker", count: 8192) + "\n").utf8).write(to: file)
        prepared = try IngestV3UploadRequestBuilder.build(baseURL: route.serverURL,
            day: "20260930", segment: "120000_1", selectedFiles: [file], meta: nil,
            source: "browser", boundary: "file-upload-boundary", bodyURL: root.appendingPathComponent("multipart.body"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        client = UploadClient(sessionConfiguration: configuration)
    }

    func clear() { try? FileManager.default.removeItem(at: root) }
}

/// A bounded HTTP/1.1 peer on an ephemeral loopback port. Actor isolation owns
/// connection state; Network callbacks only enqueue work or yield stream events.
private actor BrowserUploadHTTPPeer {
    nonisolated let requests: AsyncThrowingStream<Data, Error>
    private let requestEvents: AsyncThrowingStream<Data, Error>.Continuation
    private let ready: AsyncThrowingStream<UInt16, Error>
    private let listener: NWListener
    private let queue = DispatchQueue(label: "browser-file-upload-http-test")
    private var connection: NWConnection?
    private var received = Data()

    init() throws {
        (requests, requestEvents) = AsyncThrowingStream.makeStream()
        let (events, continuation) = AsyncThrowingStream<UInt16, Error>.makeStream()
        ready = events
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let nativeListener = try NWListener(using: parameters)
        listener = nativeListener
        nativeListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = nativeListener.port {
                    continuation.yield(port.rawValue)
                    continuation.finish()
                }
            case .failed(let error): continuation.finish(throwing: error)
            case .cancelled: continuation.finish()
            default: break
            }
        }
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: queue)
        var iterator = ready.makeAsyncIterator()
        return try #require(try await iterator.next())
    }

    nonisolated func stop() {
        Task {
            await close()
        }
    }

    private func close() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        connection?.cancel()
        requestEvents.finish()
    }

    private func accept(_ candidate: NWConnection) {
        guard connection == nil else { candidate.cancel(); return }
        connection = candidate
        candidate.start(queue: queue)
        read(candidate)
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            Task { await self?.consume(data, done: done, error: error, connection: connection) }
        }
    }

    private func consume(_ data: Data?, done: Bool, error: NWError?, connection: NWConnection) {
        if let error { requestEvents.finish(throwing: error); return }
        if let data { received.append(data) }
        guard received.count <= 1024 * 1024 else { close(); return }
        if let end = received.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: received[..<end.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) }
            if let length, received.count - end.upperBound >= length {
                requestEvents.yield(Data(received[end.upperBound..<(end.upperBound + length)]))
                requestEvents.finish()
                return
            }
        }
        if done { requestEvents.finish(); return }
        read(connection)
    }

    func respond(status: String, body: Data) {
        guard let connection else { return }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
