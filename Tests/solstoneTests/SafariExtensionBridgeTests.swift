// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
import Darwin
import Foundation
import Testing
@testable import solstone

private final class DispatchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String: Any]] = []
    func append(_ item: [String: Any]) { lock.withLock { items.append(item) } }
    var all: [[String: Any]] { lock.withLock { items } }
}

private func socketPair() throws -> (Int32, Int32) {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
    return (pair[0], pair[1])
}

private func bridge(hostSocket: URL, log: DispatchLog) -> SafariExtensionBridge {
    SafariExtensionBridge(hostSocketURL: { hostSocket }, dispatcher: { info, done in
        log.append(info)
        done()
    })
}

private func openFrame(_ connection: String) -> Data {
    Data("{\"c\":\"\(connection)\",\"type\":\"safari_open\"}".utf8)
}

private func bridgeDirectory() throws -> URL {
    let root = URL(fileURLWithPath: "/private/var/tmp/sb-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    return root
}

private func boundSocket(at url: URL, listening: Bool) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = try #require(NativeHostEndpoint.address(url.path))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(bound == 0)
    if listening { try #require(listen(fd, 1) == 0) }
    return fd
}

private func inode(_ url: URL) -> ino_t? {
    var info = stat()
    return lstat(url.path, &info) == 0 ? info.st_ino : nil
}

private let noHost = URL(fileURLWithPath: "/nonexistent/host.sock")

@Suite("SafariExtensionBridge", .serialized)
struct SafariExtensionBridgeTests {
    @Test func aSocketACrashLeftIsReclaimedAndRemovedOnQuit() throws {
        let root = try bridgeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent(SafariExtensionBridge.socketName)
        close(try boundSocket(at: socketURL, listening: false))
        let address = try #require(NativeHostEndpoint.address(socketURL.path))
        #expect(SafariExtensionBridge.probe(address) == .stale)

        let subject = bridge(hostSocket: noHost, log: DispatchLog())
        subject.start(socketURL: socketURL)
        #expect(SafariExtensionBridge.probe(address) == .live)
        subject.stop()
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }

    @Test func aSocketThatAnswersKeepsItsListener() throws {
        let root = try bridgeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent(SafariExtensionBridge.socketName)
        let live = try boundSocket(at: socketURL, listening: true)
        defer { close(live) }
        let before = inode(socketURL)

        let subject = bridge(hostSocket: noHost, log: DispatchLog())
        subject.start(socketURL: socketURL)
        subject.stop()
        #expect(before != nil && inode(socketURL) == before)
    }

    @Test func aSecondAppStartingAtOnceLeavesTheFirstItsSocket() throws {
        let root = try bridgeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent(SafariExtensionBridge.socketName)
        let first = bridge(hostSocket: noHost, log: DispatchLog())
        first.start(socketURL: socketURL)
        let published = inode(socketURL)

        let second = bridge(hostSocket: noHost, log: DispatchLog())
        second.start(socketURL: socketURL)
        second.stop()
        #expect(published != nil && inode(socketURL) == published)
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    }

    @Test func anUnavailableIntakeAnswersTheHelloAndCloses() throws {
        let log = DispatchLog()
        let missing = URL(fileURLWithPath: "/private/var/tmp/sb-missing-\(UUID().uuidString.prefix(8))/host.sock")
        let (handler, bridgeEnd) = try socketPair()
        defer { close(handler) }
        try NativeHostFrameIO.writeFrame(openFrame("ab12"), to: handler, direction: .control)
        bridge(hostSocket: missing, log: log).serve(bridgeEnd)

        let sent = log.all
        #expect(sent.count == 1)
        #expect(sent.first?["c"] as? String == "ab12")
        #expect(sent.first?["closed"] as? Bool == true)
        let frames = try #require(sent.first?["f"] as? [String])
        let ack = try #require(JSONSerialization.jsonObject(with: Data(frames[0].utf8)) as? [String: Any])
        #expect(ack["type"] as? String == "hello_ack")
        #expect(ack["capture"] as? String == "unavailable")
    }

    @Test func framesRelayToTheIntakeAndBackToTheirOwnConnection() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp/sb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let hostSocket = root.appendingPathComponent("host.sock")
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = try #require(NativeHostEndpoint.address(hostSocket.path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(chmod(hostSocket.path, 0o600) == 0)
        #expect(listen(listener, 1) == 0)

        // A stand-in intake: checks the bridge's local hello, takes one frame, answers, hangs up.
        let received = DispatchLog()
        let intake = Thread {
            let client = accept(listener, nil, nil)
            defer { close(client) }
            guard let context = try? NativeHostFrameIO.readFrame(from: client, direction: .control),
                  let hello = try? NativeHostFrameIO.readFrame(from: client, direction: .extensionToHost) else { return }
            received.append(["context": String(decoding: context.body, as: UTF8.self),
                             "hello": String(decoding: hello.body, as: UTF8.self)])
            try? NativeHostFrameIO.writeFrame(Data("{\"type\":\"hello_ack\"}".utf8), to: client, direction: .hostToExtension)
        }
        intake.start()

        let log = DispatchLog()
        let (handler, bridgeEnd) = try socketPair()
        defer { close(handler) }
        let hello = "{\"type\":\"hello\",\"brand\":\"safari\",\"inst\":\"i\"}"
        try NativeHostFrameIO.writeFrame(openFrame("cd34"), to: handler, direction: .control)
        try NativeHostFrameIO.writeFrame(Data(hello.utf8), to: handler, direction: .extensionToHost)
        bridge(hostSocket: hostSocket, log: log).serve(bridgeEnd)

        let seen = try #require(received.all.first)
        let context = try #require(JSONSerialization.jsonObject(with: Data((seen["context"] as? String ?? "").utf8)) as? [String: String])
        #expect(context == ["type": "local_hello", "brand": "safari", "mode": "production"])
        #expect(seen["hello"] as? String == hello)

        let sent = log.all
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0["c"] as? String == "cd34" })
        #expect(sent.first?["f"] as? [String] == ["{\"type\":\"hello_ack\"}"])
        #expect(sent.first?["closed"] == nil)
        #expect(sent.last?["closed"] as? Bool == true)
    }

    @Test func anUnnamedConnectionIsDropped() throws {
        let log = DispatchLog()
        let (handler, bridgeEnd) = try socketPair()
        defer { close(handler) }
        try NativeHostFrameIO.writeFrame(Data("{\"type\":\"hello\"}".utf8), to: handler, direction: .control)
        bridge(hostSocket: URL(fileURLWithPath: "/nonexistent/host.sock"), log: log).serve(bridgeEnd)
        #expect(log.all.isEmpty)
    }
}
#endif
