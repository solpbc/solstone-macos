// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Darwin
import Dispatch
import Foundation
import SafariServices
import os

/// Carries the Safari extension's native messages to the browser intake.
///
/// Safari hands each extension message to the app's extension handler, which
/// runs sandboxed and can reach the app only through the shared app-group
/// container. The handler keeps one socket here per extension connection; the
/// bridge speaks to the intake's own endpoint exactly as the Chrome and
/// Firefox helper does, and returns the intake's frames to the extension
/// through Safari's app-to-extension messages, one at a time and in order.
public final class SafariExtensionBridge: @unchecked Sendable {
    public static let groupIdentifier = "7QCG8V4M6H.app.solstone.observer"
    public static let extensionIdentifier = "app.solstone.observer.safari"
    static let socketName = "safari.sock"
    static let lockName = "safari.lock"
    static let openFrameType = "safari_open"
    private static let logger = Logger(subsystem: "app.solstone.observer", category: "safari")

    public static let shared = SafariExtensionBridge()

    typealias Dispatcher = @Sendable (_ userInfo: [String: Any], _ done: @escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var published: (path: String, device: dev_t, inode: ino_t)?
    private let hostSocketURL: @Sendable () -> URL
    private let dispatcher: Dispatcher
    private let dispatchQueue = DispatchQueue(label: "app.solstone.observer.safari.dispatch")

    init(
        hostSocketURL: @escaping @Sendable () -> URL = { NativeHostPaths.socketURL() },
        dispatcher: @escaping Dispatcher = SafariExtensionBridge.safariDispatch
    ) {
        self.hostSocketURL = hostSocketURL
        self.dispatcher = dispatcher
    }

    public static func socketURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent(socketName)
    }

    /// Listens for the extension handler. Idempotent; a failure leaves Safari
    /// seeing the app as unavailable and every other browser unaffected.
    public func start(socketURL: URL? = SafariExtensionBridge.socketURL()) {
        lock.lock()
        defer { lock.unlock() }
        guard listenerFD < 0 else { return }
        guard let socketURL else {
            Self.logger.error("Safari bridge left off: no app-group container")
            return
        }
        let path = socketURL.path
        guard NativeHostSocketPath.fits(path), var address = NativeHostEndpoint.address(path) else {
            Self.logger.error("Safari bridge left off: socket path too long")
            return
        }
        try? FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // One app owns the socket at a time. The kernel drops the lock however the app ends,
        // so whoever holds it may treat a socket nothing answers on as left by a crash.
        let lockPath = socketURL.deletingLastPathComponent().appendingPathComponent(Self.lockName).path
        let held = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard held >= 0 else {
            Self.logger.error("Safari bridge left off: lock unavailable (\(errno, privacy: .public))")
            return
        }
        guard flock(held, LOCK_EX | LOCK_NB) == 0 else {
            Self.logger.error("Safari bridge left off: another solstone app holds safari.sock")
            Darwin.close(held)
            return
        }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, existing.st_uid == geteuid() else {
                Self.logger.error("Safari bridge left off: endpoint is not ours")
                Darwin.close(held)
                return
            }
            switch Self.probe(address) {
            case .live:
                Self.logger.error("Safari bridge left off: a listener already answers on safari.sock")
                Darwin.close(held)
                return
            case .unknown(let failure):
                Self.logger.error("Safari bridge left off: safari.sock could not be checked (\(failure, privacy: .public))")
                Darwin.close(held)
                return
            case .stale:
                unlink(path)
                Self.logger.notice("Safari bridge reclaimed a stale safari.sock")
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.logger.error("Safari bridge left off: socket failed (\(errno, privacy: .public))")
            Darwin.close(held)
            return
        }
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        var created = stat()
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0, lstat(path, &created) == 0 else {
            Self.logger.error("Safari bridge left off: bind failed (\(errno, privacy: .public))")
            Darwin.close(fd)
            Darwin.close(held)
            return
        }
        listenerFD = fd
        published = (path, created.st_dev, created.st_ino)
        Self.logger.notice("Safari bridge listening")
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "safari-bridge-accept"
        thread.start()
    }

    /// On orderly quit, removes the socket this app published. The listener ends with the process.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let published else { return }
        self.published = nil
        var current = stat()
        guard lstat(published.path, &current) == 0, current.st_dev == published.device, current.st_ino == published.inode else {
            Self.logger.notice("Safari bridge left safari.sock in place: it is no longer the one it published")
            return
        }
        unlink(published.path)
        Self.logger.notice("Safari bridge removed safari.sock")
    }

    enum SocketProbe: Equatable { case live, stale, unknown(Int32) }

    /// A socket nothing listens on refuses the connection; one already gone is stale too.
    static func probe(_ address: sockaddr_un) -> SocketProbe {
        var address = address
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown(errno) }
        defer { Darwin.close(fd) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return .live }
        let failure = errno
        return failure == ECONNREFUSED || failure == ENOENT ? .stale : .unknown(failure)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                Self.logger.error("Safari bridge stopped accepting (\(errno, privacy: .public))")
                return
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else {
                Darwin.close(client)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "safari-bridge-connection"
            thread.start()
        }
    }

    /// One extension connection: an open frame naming it, then its frames.
    func serve(_ handler: Int32) {
        defer { Darwin.close(handler) }
        guard let open = try? NativeHostFrameIO.readFrame(from: handler, direction: .control, firstByteTimeoutMs: 5_000),
              let object = try? JSONSerialization.jsonObject(with: open.body) as? [String: Any],
              object["type"] as? String == Self.openFrameType,
              let connection = object["c"] as? String, !connection.isEmpty, connection.utf8.count <= 64 else { return }

        Self.logger.notice("Safari connection \(connection.prefix(8), privacy: .public) opened")
        let hostPath = hostSocketURL().path
        let attempt = NativeHostEndpoint.connect(path: hostPath)
        guard let host = attempt.descriptor else {
            Self.logger.notice("Safari connection \(connection.prefix(8), privacy: .public): intake unavailable (\(attempt.error, privacy: .public))")
            // The intake is off or starting: answer the hello the way the helper does.
            deliver(connection, frames: [Self.unavailableHelloAck], closed: true)
            return
        }
        defer { Darwin.close(host) }
        let context = Data("{\"brand\":\"safari\",\"mode\":\"production\",\"type\":\"local_hello\"}".utf8)
        guard (try? NativeHostFrameIO.writeFrame(context, to: host, direction: .control, timeoutMs: 5_000)) != nil else {
            deliver(connection, frames: [], closed: true)
            return
        }

        let stop = SafariBridgeStop()
        let returned = DispatchSemaphore(value: 0)
        let returnPath = Thread { [weak self] in
            self?.pumpHostFrames(from: host, connection: connection, stop: stop)
            shutdown(handler, SHUT_RDWR)
            returned.signal()
        }
        returnPath.name = "safari-bridge-return"
        returnPath.start()

        while !stop.isSet {
            guard let frame = try? NativeHostFrameIO.readFrame(
                from: handler, direction: .extensionToHost, shouldCancel: { stop.isSet }
            ) else { break }
            guard (try? NativeHostFrameIO.writeFrame(
                frame.body, to: host, direction: .extensionToHost, shouldCancel: { stop.isSet }
            )) != nil else { break }
        }
        stop.set()
        shutdown(host, SHUT_RDWR)
        returned.wait()
        Self.logger.notice("Safari connection \(connection.prefix(8), privacy: .public) closed")
    }

    private func pumpHostFrames(from host: Int32, connection: String, stop: SafariBridgeStop) {
        while !stop.isSet {
            guard let frame = try? NativeHostFrameIO.readFrame(
                from: host, direction: .hostToExtension, shouldCancel: { stop.isSet }
            ) else { break }
            Self.logger.debug("Safari connection \(connection.prefix(8), privacy: .public) <- \(Self.frameType(frame.body), privacy: .public)")
            deliver(connection, frames: [String(decoding: frame.body, as: UTF8.self)], closed: false)
        }
        Self.logger.notice("Safari connection \(connection.prefix(8), privacy: .public): intake ended (stopped=\(stop.isSet, privacy: .public))")
        if !stop.isSet { deliver(connection, frames: [], closed: true) }
        stop.set()
    }

    /// Safari delivers app messages to every open port; the connection id lets
    /// the extension keep only its own. Each waits for the previous one.
    private func deliver(_ connection: String, frames: [String], closed: Bool) {
        var userInfo: [String: Any] = ["c": connection, "f": frames]
        if closed { userInfo["closed"] = true }
        let dispatcher = self.dispatcher
        dispatchQueue.sync {
            let sent = DispatchSemaphore(value: 0)
            dispatcher(userInfo) { sent.signal() }
            if sent.wait(timeout: .now() + 5) == .timedOut {
                Self.logger.error("Safari bridge dispatch timed out")
            }
        }
    }

    static let safariDispatch: Dispatcher = { userInfo, done in
        let message = SafariDispatchMessage(userInfo: userInfo)
        Task.detached {
            do {
                try await SFSafariApplication.dispatchMessage(
                    withName: "f", toExtensionWithIdentifier: extensionIdentifier, userInfo: message.userInfo
                )
            } catch {
                logger.error("Safari dispatch failed: \(error.localizedDescription, privacy: .public)")
            }
            done()
        }
    }

    private static func frameType(_ body: Data) -> String {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["type"] as? String ?? "?"
    }

    static let unavailableHelloAck =
        "{\"type\":\"hello_ack\",\"capture\":\"unavailable\",\"delivery\":\"unknown\",\"freshness_ms\":0,\"destination_generation\":null,\"period_id\":null,\"custody\":{\"full\":false,\"stale\":false},\"version\":\"1.3.0\"}"
}

/// Plist values only (strings, arrays, booleans), handed to Safari unchanged.
private struct SafariDispatchMessage: @unchecked Sendable {
    let userInfo: [String: Any]
}

private final class SafariBridgeStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}

#endif
