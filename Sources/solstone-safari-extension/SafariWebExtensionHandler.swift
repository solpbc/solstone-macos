// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

// The Safari extension's native-messaging handler. Safari gives it one
// extension message per request; it relays that message's frame, unchanged,
// to the solstone app through a socket in the shared app-group container.
// The app answers the extension directly, so a request only acknowledges.

import Darwin
import Foundation
import SafariServices
import os

private let groupIdentifier = "7QCG8V4M6H.app.solstone.observer"
private let socketName = "safari.sock"
private let maxConnections = 16
private let logger = Logger(subsystem: "app.solstone.observer.safari", category: "relay")

/// Sockets this process holds, one per extension connection, oldest first.
private final class RelaySockets: @unchecked Sendable {
    static let shared = RelaySockets()
    private let lock = NSLock()
    private var order: [String] = []
    private var sockets: [String: Int32] = [:]

    func withLock<T>(_ body: (RelaySockets) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    func socket(for connection: String) -> Int32? { sockets[connection] }

    func insert(_ fd: Int32, for connection: String) {
        sockets[connection] = fd
        order.append(connection)
        // A connection whose page Safari unloaded never says goodbye.
        while order.count > maxConnections {
            let oldest = order.removeFirst()
            if let stale = sockets.removeValue(forKey: oldest) { close(stale) }
        }
    }

    func remove(_ connection: String) {
        order.removeAll { $0 == connection }
        if let fd = sockets.removeValue(forKey: connection) { close(fd) }
    }
}

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var reply: [String: Any] = [:]
        // The extension mints connection ids as hex; nothing else is relayed.
        if let message, let connection = message["c"] as? String,
           !connection.isEmpty, connection.utf8.count <= 64,
           connection.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            reply = Self.handle(message, connection: connection)
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private static func handle(_ message: [String: Any], connection: String) -> [String: Any] {
        RelaySockets.shared.withLock { sockets in
            if message["close"] as? Bool == true {
                sockets.remove(connection)
                return ["c": connection]
            }
            guard let text = message["f"] as? String else { return ["c": connection] }
            let frame = Data(text.utf8)
            if let fd = sockets.socket(for: connection) {
                if writeFrame(fd, frame) { return ["c": connection] }
                sockets.remove(connection)
                return ["c": connection, "closed": true]
            }
            guard let fd = connectToApp() else {
                // The app isn't running: answer the hello the way the helper does.
                logger.notice("connection \(connection.prefix(8), privacy: .public): app unavailable")
                return ["c": connection, "f": [unavailableHelloAck], "closed": true]
            }
            let open = Data("{\"c\":\"\(connection)\",\"type\":\"safari_open\"}".utf8)
            guard writeFrame(fd, open), writeFrame(fd, frame) else {
                close(fd)
                return ["c": connection, "closed": true]
            }
            sockets.insert(fd, for: connection)
            logger.notice("connection \(connection.prefix(8), privacy: .public): opened")
            return ["c": connection]
        }
    }

    private static func connectToApp() -> Int32? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            logger.error("no app-group container")
            return nil
        }
        let path = container.appendingPathComponent(socketName).path
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            logger.notice("connect failed: \(errno, privacy: .public)")
            close(fd)
            return nil
        }
        return fd
    }

    /// Native-messaging framing: a 32-bit little-endian length, then the bytes.
    private static func writeFrame(_ fd: Int32, _ body: Data) -> Bool {
        var length = UInt32(body.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(body)
        return framed.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private static let unavailableHelloAck =
        "{\"type\":\"hello_ack\",\"capture\":\"unavailable\",\"delivery\":\"unknown\",\"freshness_ms\":0,\"destination_generation\":null,\"period_id\":null,\"custody\":{\"full\":false,\"stale\":false},\"version\":\"1.3.0\"}"
}
