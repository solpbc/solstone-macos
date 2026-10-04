// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Darwin
import Foundation
import SolstoneCore
import os

public enum BrowserHostListenerError: Error, Equatable, Sendable {
    case endpointCollision
    case socketPathTooLong
    case unsafeEndpoint
    case socketFailure
}

struct BrowserHostSocketIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
}

struct BrowserHostEndpointIdentity: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case socket, other }
    let kind: Kind
    let uid: uid_t
    let mode: mode_t
    let device: UInt64
    let inode: UInt64

    init(_ value: stat) {
        kind = (value.st_mode & S_IFMT) == S_IFSOCK ? .socket : .other
        uid = value.st_uid
        mode = value.st_mode & 0o777
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
    }

    init(kind: Kind, uid: uid_t, mode: mode_t = 0o600, device: UInt64, inode: UInt64) {
        self.kind = kind
        self.uid = uid
        self.mode = mode
        self.device = device
        self.inode = inode
    }
}

public enum BrowserHostEndpointDisposition: String, Sendable, Equatable {
    case absent
    case removed
    case live
    case stale
    case refused
}

enum BrowserHostEndpointRepairPolicy {
    static func mayRemove(
        first: BrowserHostEndpointIdentity,
        rechecked: BrowserHostEndpointIdentity,
        rootVerified: Bool,
        effectiveUID: uid_t
    ) -> Bool {
        rootVerified && first.kind == .socket && rechecked.kind == .socket &&
            first.uid == effectiveUID && rechecked.uid == effectiveUID &&
            first.device == rechecked.device && first.inode == rechecked.inode &&
            first.mode == 0o600 && rechecked.mode == 0o600
    }

    static func mayCleanup(
        created: BrowserHostSocketIdentity,
        current: BrowserHostEndpointIdentity,
        rootVerified: Bool,
        effectiveUID: uid_t
    ) -> Bool {
        rootVerified && current.kind == .socket && current.uid == effectiveUID &&
            created.device == current.device && created.inode == current.inode
    }
}

public protocol BrowserHostByteSink: Sendable {
    func write(_ data: Data) async throws
    func beginClose(withinMilliseconds: UInt64)
    func cancel()
    func stopReading()
}

extension BrowserHostByteSink {
    public func beginClose(withinMilliseconds: UInt64) {}
    public func cancel() {}
    public func stopReading() {}
}

enum BrowserHostIO {
    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class BrowserHostWriteControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deadline: UInt64?
    var shouldStop: Bool {
        lock.withLock { cancelled || deadline.map { DispatchTime.now().uptimeNanoseconds >= $0 } == true }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func beginClose(withinMilliseconds: UInt64) {
        lock.withLock {
            let next = DispatchTime.now().uptimeNanoseconds + withinMilliseconds * 1_000_000
            deadline = min(deadline ?? next, next)
        }
    }
}

final class FDByteSink: BrowserHostByteSink, @unchecked Sendable {
    private let fd: Int32
    private let limits: BrowserHostLimits
    private let control = BrowserHostWriteControl()

    init(fd: Int32, limits: BrowserHostLimits) {
        self.fd = dup(fd)
        self.limits = limits
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
    func beginClose(withinMilliseconds: UInt64) { control.beginClose(withinMilliseconds: withinMilliseconds) }
    func cancel() { control.cancel(); if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) } }
    func stopReading() { if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RD) } }

    func write(_ data: Data) async throws {
        let fd = fd, limits = limits, control = control
        try await withTaskCancellationHandler {
            try await BrowserHostIO.perform {
                try NativeHostFrameIO.writeFrame(
                    data, to: fd, direction: .hostToExtension, limits: limits,
                    timeoutMs: limits.handshakeMs, shouldCancel: { control.shouldStop }
                )
            }
        } onCancel: { control.cancel() }
    }
}

public actor BrowserHostOutbound {
    private let sink: any BrowserHostByteSink
    private var pendingState: Data?
    private var pendingBoundary: Data?
    private var pendingReplies: [(Data, @Sendable () -> Void)] = []
    private var pendingBye: Data?
    private var publishedPeriodID: String?
    private var publishedDestinationGeneration: String?
    private var isWriting = false
    private var isClosed = false
    private var drainTask: Task<Void, Never>?

    public init(sink: any BrowserHostByteSink) {
        self.sink = sink
    }

    public func enqueueState(_ data: Data) {
        guard !isClosed, pendingBye == nil else { return }
        pendingState = data
        drainIfNeeded()
    }

    public func enqueueBoundary(_ data: Data) {
        guard !isClosed, pendingBye == nil else { return }
        pendingBoundary = data
        drainIfNeeded()
    }

    /// Accept state and its period transition atomically after the caller's actor hop.
    /// The cursor belongs to this channel, and advances only when its queue accepts the state.
    @discardableResult
    func enqueuePublication(
        state: Data, boundary: Data?, periodID: String?, destinationGeneration: String?,
        isCurrent: @Sendable () -> Bool
    ) -> Bool {
        guard !isClosed, pendingBye == nil, isCurrent() else { return false }
        let sameEpoch = publishedDestinationGeneration != nil &&
            destinationGeneration == publishedDestinationGeneration
        let changedPeriod = publishedPeriodID != nil && periodID != nil && periodID != publishedPeriodID
        if sameEpoch && changedPeriod {
            guard let boundary else { return false }
            pendingBoundary = boundary
        } else if !sameEpoch || periodID == nil {
            pendingBoundary = nil
        }
        pendingState = state
        publishedPeriodID = periodID
        publishedDestinationGeneration = destinationGeneration
        drainIfNeeded()
        return true
    }

    public func enqueueReply(_ data: Data, budgetRelease: @escaping @Sendable () -> Void) {
        guard !isClosed, pendingBye == nil else {
            budgetRelease()
            return
        }
        pendingReplies.append((data, budgetRelease))
        drainIfNeeded()
    }

    public func enqueueBye(_ data: Data) {
        guard !isClosed else { return }
        sink.beginClose(withinMilliseconds: 5_000)
        pendingBye = data
        drainIfNeeded()
        sink.stopReading()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        sink.cancel()
        drainTask?.cancel()
        for (_, release) in pendingReplies {
            release()
        }
        pendingReplies.removeAll()
        pendingState = nil
        pendingBoundary = nil
        pendingBye = nil
    }

    public func finish() async {
        sink.beginClose(withinMilliseconds: 5_000)
        let task = drainTask
        await task?.value
        close()
    }

    public func flush() async { await drainTask?.value }

    private func drainIfNeeded() {
        guard !isWriting, !isClosed else { return }
        isWriting = true
        drainTask = Task { [weak self] in
            await self?.runDrainLoop()
        }
    }

    private func runDrainLoop() async {
        while !isClosed {
            let nextAction: OutboundAction? = nextItem()
            guard let nextAction else { break }
            do {
                switch nextAction {
                case .state(let data):
                    try await sink.write(data)
                case .boundary(let data):
                    try await sink.write(data)
                case .reply(let data, let release):
                    defer { release() }
                    try await sink.write(data)
                case .bye(let data):
                    try await sink.write(data)
                    close()
                    break
                }
            } catch {
                close()
                break
            }
        }
        isWriting = false
        drainTask = nil
    }

    private enum OutboundAction {
        case state(Data)
        case boundary(Data)
        case reply(Data, @Sendable () -> Void)
        case bye(Data)
    }

    private func nextItem() -> OutboundAction? {
        if let bye = pendingBye {
            pendingBye = nil
            return .bye(bye)
        }
        if let boundary = pendingBoundary {
            pendingBoundary = nil
            return .boundary(boundary)
        }
        if let state = pendingState {
            pendingState = nil
            return .state(state)
        }
        if !pendingReplies.isEmpty {
            let (reply, release) = pendingReplies.removeFirst()
            return .reply(reply, release)
        }
        return nil
    }
}

/// Owns the protected endpoint namespace and removes only positively identified nodes.
final class BrowserHostEndpointFence: @unchecked Sendable {
    private let rootURL: URL
    private var rootFD: Int32 = -1
    private var fenceFD: Int32 = -1
    private var listenerFD: Int32 = -1
    private var createdSocket: BrowserHostSocketIdentity?
    private var temporarySocket: (String, BrowserHostSocketIdentity)?
    private let euid = geteuid()

    init(rootURL: URL) { self.rootURL = rootURL }
    deinit { release() }

    func inspectEndpoint() -> BrowserHostEndpointDisposition {
        guard NativeHostEndpoint.ancestorsAreSafe(rootURL.path, allowMissing: true) else { return .refused }
        var pathInfo = stat()
        guard lstat(rootURL.path, &pathInfo) == 0 else { return errno == ENOENT ? .absent : .refused }
        guard validRoot(pathInfo) else { return .refused }
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { return .refused }
        defer { Darwin.close(root) }
        guard rootMatches(root, expected: pathInfo) else { return .refused }
        var endpoint = stat()
        guard fstatat(root, "host.sock", &endpoint, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT && rootMatches(root, expected: pathInfo) ? .absent : .refused
        }
        guard validSocket(endpoint) else { return .refused }
        let fence = openat(root, "host.fence", O_RDONLY | O_NOFOLLOW)
        guard fence >= 0 else { return .refused }
        defer { Darwin.close(fence) }
        guard fenceMatches(root: root, fence: fence), provenanceMatches(fence, endpoint: endpoint) else { return .refused }
        let disposition = probe()
        var after = stat()
        guard rootMatches(root, expected: pathInfo), fenceMatches(root: root, fence: fence),
              fstatat(root, "host.sock", &after, AT_SYMLINK_NOFOLLOW) == 0,
              same(endpoint, after), validSocket(after) else { return .refused }
        return disposition
    }

    func repairStaleEndpoint() throws -> BrowserHostEndpointDisposition {
        try verifyOrCreateRoot()
        defer { release() }
        guard let first = try endpointInfo() else { return rootStillVerified() ? .absent : .refused }
        guard validSocket(first), try acquireFence(create: false) else {
            return inspectEndpoint() == .live ? .live : .refused
        }
        guard fenceMatches(root: rootFD, fence: fenceFD), provenanceMatches(fenceFD, endpoint: first) else { return .refused }
        let disposition = probe()
        guard disposition == .stale else { return disposition }
        guard rootStillVerified(), fenceMatches(root: rootFD, fence: fenceFD),
              let second = try endpointInfo(), same(first, second), validSocket(second),
              provenanceMatches(fenceFD, endpoint: second) else { return .refused }
        guard unlinkat(rootFD, "host.sock", 0) == 0 else { return .refused }
        return .removed
    }

    func bindListener() throws -> Int32 {
        var succeeded = false
        defer { if !succeeded { release() } }
        try verifyOrCreateRoot()
        guard try acquireFence(create: true) else { throw BrowserHostListenerError.endpointCollision }
        guard rootStillVerified(), fenceMatches(root: rootFD, fence: fenceFD) else { throw BrowserHostListenerError.unsafeEndpoint }
        guard try endpointInfo() == nil else { throw BrowserHostListenerError.endpointCollision }
        // Bind privately, retain the filesystem identity, then publish without replacing an entry.
        let temporaryName = "." + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let temporaryPath = rootURL.appendingPathComponent(temporaryName).path
        guard var address = NativeHostEndpoint.address(temporaryPath),
              NativeHostSocketPath.fits(rootURL.appendingPathComponent("host.sock").path) else {
            throw BrowserHostListenerError.socketPathTooLong
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrowserHostListenerError.socketFailure }
        listenerFD = descriptor
        var noSigPipe: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw BrowserHostListenerError.socketFailure
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            throw errno == EADDRINUSE ? BrowserHostListenerError.endpointCollision : BrowserHostListenerError.socketFailure
        }
        guard let before = try endpointInfo(temporaryName), before.kind == S_IFSOCK, before.uid == euid,
              rootStillVerified(), fenceMatches(root: rootFD, fence: fenceFD) else {
            throw BrowserHostListenerError.unsafeEndpoint
        }
        let identity = BrowserHostSocketIdentity(device: before.device, inode: before.inode)
        temporarySocket = (temporaryName, identity)
        guard fchmodat(rootFD, temporaryName, 0o600, AT_SYMLINK_NOFOLLOW) == 0,
              let secured = try endpointInfo(temporaryName), same(before, secured), validSocket(secured),
              listen(descriptor, 16) == 0,
              rootStillVerified(), fenceMatches(root: rootFD, fence: fenceFD),
              renameatx_np(rootFD, temporaryName, rootFD, "host.sock", UInt32(RENAME_EXCL)) == 0 else {
            throw BrowserHostListenerError.unsafeEndpoint
        }
        temporarySocket = nil
        createdSocket = identity
        guard let published = try endpointInfo(), same(secured, published), validSocket(published), rootStillVerified() else {
            throw BrowserHostListenerError.unsafeEndpoint
        }
        let payload = Data("\(published.device):\(published.inode)\n".utf8)
        guard ftruncate(fenceFD, 0) == 0,
              payload.withUnsafeBytes({ pwrite(fenceFD, $0.baseAddress!, $0.count, 0) }) == payload.count,
              fsync(fenceFD) == 0, fenceMatches(root: rootFD, fence: fenceFD) else {
            throw BrowserHostListenerError.unsafeEndpoint
        }
        succeeded = true
        return descriptor
    }

    func closeListener() {
        guard listenerFD >= 0 else { return }
        _ = shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        listenerFD = -1
    }

    func cleanupOwnedSocket() {
        guard rootFD >= 0, fenceFD >= 0, rootStillVerified(), fenceMatches(root: rootFD, fence: fenceFD) else { return }
        if let createdSocket { cleanup(name: "host.sock", identity: createdSocket) }
        if let (name, identity) = temporarySocket { cleanup(name: name, identity: identity) }
        createdSocket = nil
        temporarySocket = nil
    }

    func release() {
        closeListener()
        cleanupOwnedSocket()
        if fenceFD >= 0 { Darwin.close(fenceFD); fenceFD = -1 }
        if rootFD >= 0 { Darwin.close(rootFD); rootFD = -1 }
    }

    private func cleanup(name: String, identity: BrowserHostSocketIdentity) {
        guard let current = try? endpointInfo(name),
              BrowserHostEndpointRepairPolicy.mayCleanup(
                created: identity, current: BrowserHostEndpointIdentity(current),
                rootVerified: rootStillVerified(), effectiveUID: euid
              ) else { return }
        _ = unlinkat(rootFD, name, 0)
    }

    private func verifyOrCreateRoot() throws {
        guard NativeHostEndpoint.ancestorsAreSafe(rootURL.path, allowMissing: true) else { throw BrowserHostListenerError.unsafeEndpoint }
        var pathInfo = stat()
        if lstat(rootURL.path, &pathInfo) != 0 {
            guard errno == ENOENT else { throw BrowserHostListenerError.unsafeEndpoint }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard NativeHostEndpoint.ancestorsAreSafe(rootURL.path), lstat(rootURL.path, &pathInfo) == 0,
              pathInfo.kind == S_IFDIR, pathInfo.uid == euid else { throw BrowserHostListenerError.unsafeEndpoint }
        if rootFD < 0 { rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        var opened = stat()
        guard rootFD >= 0, fstat(rootFD, &opened) == 0, opened.kind == S_IFDIR, opened.uid == euid,
              same(pathInfo, opened), fchmod(rootFD, 0o700) == 0, rootStillVerified() else {
            throw BrowserHostListenerError.unsafeEndpoint
        }
    }

    private func acquireFence(create: Bool) throws -> Bool {
        guard rootStillVerified() else { throw BrowserHostListenerError.unsafeEndpoint }
        if fenceFD < 0 {
            fenceFD = openat(rootFD, "host.fence", O_RDWR | O_NOFOLLOW | (create ? O_CREAT : 0), 0o600)
        }
        guard fenceFD >= 0 else {
            if !create && errno == ENOENT { return false }
            throw BrowserHostListenerError.unsafeEndpoint
        }
        guard fenceMatches(root: rootFD, fence: fenceFD) else { throw BrowserHostListenerError.unsafeEndpoint }
        if flock(fenceFD, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK || errno == EAGAIN { return false }
        throw BrowserHostListenerError.socketFailure
    }

    private func endpointInfo(_ name: String = "host.sock") throws -> stat? {
        var info = stat()
        if fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw BrowserHostListenerError.unsafeEndpoint
    }

    private func probe() -> BrowserHostEndpointDisposition {
        let connection = NativeHostEndpoint.connect(path: rootURL.appendingPathComponent("host.sock").path)
        if let fd = connection.descriptor { Darwin.close(fd); return .live }
        return connection.error == ECONNREFUSED ? .stale : .refused
    }

    private func provenanceMatches(_ fence: Int32, endpoint: stat) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = pread(fence, &bytes, bytes.count, 0)
        guard count > 0, count < bytes.count else { return false }
        return Data(bytes.prefix(count)) == Data("\(endpoint.device):\(endpoint.inode)\n".utf8)
    }

    private func fenceMatches(root: Int32, fence: Int32) -> Bool {
        var opened = stat()
        var current = stat()
        return fstat(fence, &opened) == 0 && opened.kind == S_IFREG && opened.uid == euid &&
            opened.mode & 0o777 == 0o600 && opened.st_nlink == 1 &&
            fstatat(root, "host.fence", &current, AT_SYMLINK_NOFOLLOW) == 0 && same(opened, current)
    }

    private func rootStillVerified() -> Bool {
        var opened = stat()
        return rootFD >= 0 && fstat(rootFD, &opened) == 0 && validRoot(opened) && rootMatches(rootFD, expected: opened)
    }

    private func rootMatches(_ fd: Int32, expected: stat) -> Bool {
        var path = stat()
        var opened = stat()
        return NativeHostEndpoint.ancestorsAreSafe(rootURL.path) && lstat(rootURL.path, &path) == 0 &&
            fstat(fd, &opened) == 0 && same(expected, opened) && same(opened, path) && validRoot(path)
    }

    private func validRoot(_ info: stat) -> Bool { info.kind == S_IFDIR && info.uid == euid && info.mode & 0o777 == 0o700 }
    private func validSocket(_ info: stat) -> Bool { info.kind == S_IFSOCK && info.uid == euid && info.mode & 0o777 == 0o600 }
    private func same(_ first: stat, _ second: stat) -> Bool { first.device == second.device && first.inode == second.inode && first.uid == second.uid && first.kind == second.kind }
}

private extension stat {
    var kind: UInt16 { UInt16(st_mode & S_IFMT) }
    var uid: uid_t { st_uid }
    var mode: mode_t { st_mode }
    var device: UInt64 { UInt64(st_dev) }
    var inode: UInt64 { UInt64(st_ino) }
}

final class BrowserHostAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = false
    private var listenerFD: Int32 = -1
    private var generation = 0
    private var closeRequest: (ExitReason, Int)?

    func prepare(generation: Int) -> Bool {
        lock.withLock {
            guard generation >= self.generation else { return false }
            if let closeRequest, generation < closeRequest.1 { return false }
            if generation != self.generation {
                self.generation = generation
                closeRequest = nil
            }
            return closeRequest == nil
        }
    }

    @discardableResult
    func install(listenerFD: Int32, generation: Int) -> Bool {
        lock.withLock {
            guard closeRequest == nil, self.generation == generation else { return false }
            self.listenerFD = listenerFD
            self.generation = generation
            closeRequest = nil
            accepting = true
            return true
        }
    }

    func isOpen(generation expected: Int? = nil) -> Bool {
        lock.withLock {
            accepting && (expected == nil || generation == expected!)
        }
    }

    @discardableResult
    func commitClose(reason: ExitReason, generation: Int) -> Bool {
        let fd = lock.withLock { () -> Int32? in
            guard generation == self.generation &+ 1, closeRequest == nil else { return nil }
            closeRequest = (reason, generation)
            accepting = false
            let descriptor = listenerFD
            listenerFD = -1
            return descriptor
        }
        guard let fd else { return false }
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        return true
    }

    func committedClose(generation: Int) -> (ExitReason, Int)? {
        lock.withLock {
            guard let closeRequest, closeRequest.1 == generation else { return nil }
            return closeRequest
        }
    }

    func close() {
        let fd = lock.withLock { () -> Int32 in
            accepting = false
            let fd = listenerFD
            listenerFD = -1
            return fd
        }
        if fd >= 0 {
            _ = shutdown(fd, SHUT_RDWR)
        }
    }
}

final class BrowserHostSessionBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: BrowserHostLimits
    private var sessions: Set<UUID> = []
    private var retainedInput = 0
    private var largeAssemblies = 0
    private var pendingTotal = 0
    private var pendingBySession: [UUID: Int] = [:]

    init(limits: BrowserHostLimits) { self.limits = limits }

    func open(_ id: UUID) -> Bool {
        lock.withLock {
            guard sessions.count < limits.sessions else { return false }
            return sessions.insert(id).inserted
        }
    }

    func close(_ id: UUID) {
        lock.withLock {
            sessions.remove(id)
            pendingTotal -= pendingBySession.removeValue(forKey: id) ?? 0
        }
    }

    func reserveInput(_ amount: Int, large: Bool) -> Bool {
        lock.withLock {
            guard amount >= 0, amount <= limits.retainedInputBytes - retainedInput,
                  !large || largeAssemblies < limits.simultaneousLargeAssemblies else { return false }
            retainedInput += amount
            if large { largeAssemblies += 1 }
            return true
        }
    }

    func releaseInput(_ amount: Int, large: Bool) {
        lock.withLock {
            retainedInput = max(0, retainedInput - amount)
            if large { largeAssemblies = max(0, largeAssemblies - 1) }
        }
    }

    func reserveReply(_ amount: Int, for id: UUID) -> Bool {
        lock.withLock {
            guard sessions.contains(id) else { return false }
            let current = pendingBySession[id, default: 0]
            guard amount >= 0, amount <= limits.pendingReplyPerSession - current,
                  amount <= limits.pendingReplyTotal - pendingTotal else { return false }
            pendingBySession[id] = current + amount
            pendingTotal += amount
            return true
        }
    }

    func releaseReply(_ amount: Int, for id: UUID) {
        lock.withLock {
            let current = pendingBySession[id, default: 0]
            let released = min(current, amount)
            pendingBySession[id] = current - released
            pendingTotal = max(0, pendingTotal - released)
        }
    }
}

public struct BrowserHostConnectionContext: Sendable {
    public let brandHint: NativeHostBrandHint
    public let mode: NativeHostMode

    public init(brandHint: NativeHostBrandHint, mode: NativeHostMode) {
        self.brandHint = brandHint
        self.mode = mode
    }

    public static func decode(_ data: Data) -> BrowserHostConnectionContext? {
        guard data.count <= 512, let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              object["type"] == "local_hello",
              let brandRaw = object["brand"], let brand = NativeHostBrandHint(rawValue: brandRaw),
              let modeRaw = object["mode"], let mode = NativeHostMode(rawValue: modeRaw) else { return nil }
        return BrowserHostConnectionContext(brandHint: brand, mode: mode)
    }
}

struct BrowserHostLifecycle: Equatable, Sendable {
    var generation = 0
    private(set) var accepting = false
    private(set) var shutdown = false
    private(set) var quiescence = false
    private(set) var listenerCount = 0
    private(set) var timerCount = 0
    private(set) var closingReason: ExitReason?

    mutating func install(generation: Int) {
        self.generation = generation
        accepting = true
        shutdown = false
        quiescence = false
        timerCount = 0
        listenerCount = 1
        closingReason = nil
    }

    @discardableResult
    mutating func beginClose(reason: ExitReason, generation: Int) -> Bool {
        guard generation == self.generation &+ 1, listenerCount > 0 else { return false }
        if shutdown, closingReason == reason { return false }
        shutdown = true
        accepting = false
        closingReason = reason
        if reason == .updaterInstall {
            quiescence = true
            timerCount = 1
        }
        return true
    }

    var admitsHello: Bool { accepting && !shutdown && !quiescence }

    @discardableResult
    mutating func finishQuiescence(generation: Int) -> Bool {
        guard generation == self.generation &+ 1, shutdown else { return false }
        quiescence = false
        timerCount = 0
        listenerCount = 0
        accepting = false
        return true
    }

    mutating func prepareRecovery(generation: Int) {
        timerCount = 0
        quiescence = false
        shutdown = false
        accepting = false
        listenerCount = 0
        closingReason = nil
        self.generation = generation
    }
}

struct BrowserProfileKey: Hashable, Sendable {
    let brand: BrowserBrand
    let inst: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.brand == rhs.brand && BrowserOpaqueString.equals(lhs.inst, rhs.inst)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(brand)
        hasher.combine(Data(inst.utf8))
    }
}

private final class BrowserHostSessionAuthority: @unchecked Sendable {
    let inst: String
    let epoch: String?
    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    private let freshness: TimeInterval
    private var expires: TimeInterval
    private var valid = true

    init(inst: String, epoch: String?, freshnessMs: UInt64, uptime: @escaping @Sendable () -> TimeInterval) {
        self.inst = inst
        self.epoch = epoch
        self.freshness = Double(freshnessMs) / 1_000
        self.uptime = uptime
        self.expires = uptime() + freshness
    }
    var isLive: Bool { lock.withLock { valid && expires > uptime() } }
    var remaining: TimeInterval { lock.withLock { valid ? max(0, expires - uptime()) : 0 } }
    func invalidate() { lock.withLock { valid = false } }
    func renew() -> Bool {
        lock.withLock {
            guard valid, expires > uptime() else { return false }
            expires = uptime() + freshness
            return true
        }
    }
}

struct BrowserHostProfileTable: Sendable {
    private(set) var entries: [BrowserProfileKey: BrowserHostProfile] = [:]
    private var sessionKeys: [UUID: BrowserProfileKey] = [:]
    private var sessionEpochs: [UUID: String] = [:]

    mutating func record(sessionID: UUID, brand: BrowserBrand, inst: String, epoch: String? = nil, profile: BrowserHostProfile) {
        let key = BrowserProfileKey(brand: brand, inst: inst)
        sessionKeys[sessionID] = key
        if let epoch {
            sessionEpochs[sessionID] = epoch
        }
        entries[key] = profile
        pruneHistory()
    }

    private mutating func pruneHistory() {
        let active = Set(sessionKeys.values)
        let history = entries.keys.filter { !active.contains($0) }.sorted {
            let first = entries[$0]?.lastSeen ?? .distantPast
            let second = entries[$1]?.lastSeen ?? .distantPast
            return first == second ? $0.inst < $1.inst : first < second
        }
        for key in history.prefix(max(0, entries.count - 48)) { entries.removeValue(forKey: key) }
    }

    func epoch(for sessionID: UUID) -> String? {
        sessionEpochs[sessionID]
    }

    mutating func refreshLease(sessionID: UUID, expiry: Date) {
        guard let key = sessionKeys[sessionID], var profile = entries[key] else { return }
        profile = BrowserHostProfile(
            lastSeen: profile.lastSeen,
            handshake: profile.handshake,
            byeReason: profile.byeReason,
            leaseExpiry: expiry
        )
        entries[key] = profile
    }

    mutating func dropCompatible(sessionID: UUID) {
        guard let key = sessionKeys[sessionID], let profile = entries[key] else { return }
        entries[key] = BrowserHostProfile(
            lastSeen: profile.lastSeen,
            handshake: profile.handshake,
            byeReason: "replaced",
            leaseExpiry: nil
        )
    }

    mutating func disconnect(sessionID: UUID) {
        sessionEpochs.removeValue(forKey: sessionID)
        if let key = sessionKeys.removeValue(forKey: sessionID) {
            if !sessionKeys.values.contains(key) {
                if let previous = entries[key] {
                    entries[key] = BrowserHostProfile(lastSeen: previous.lastSeen, handshake: previous.handshake,
                                                      byeReason: previous.byeReason, leaseExpiry: nil)
                }
            }
        }
        pruneHistory()
    }

    func sessionID(for inst: String) -> UUID? {
        sessionKeys.first(where: { BrowserOpaqueString.equals($0.value.inst, inst) })?.key
    }

    func sessionID(brand: BrowserBrand, inst: String) -> UUID? {
        sessionKeys.first(where: { $0.value == BrowserProfileKey(brand: brand, inst: inst) })?.key
    }

    func sessionKey(for sessionID: UUID) -> BrowserProfileKey? {
        sessionKeys[sessionID]
    }

    func count(_ brand: BrowserBrand) -> Int {
        Set(sessionKeys.values.filter { $0.brand == brand }).count
    }
}

private final class BrowserHostPublicationValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    @discardableResult func advance() -> UInt64 { lock.withLock { revision &+= 1; return revision } }
    func isCurrent(_ candidate: UInt64) -> Bool { lock.withLock { candidate == revision } }
}

public actor BrowserHostListener {
    public typealias Sleeper = @Sendable (Duration) async -> Void

    private let admissionGate = BrowserHostAdmissionGate()
    private let budget: BrowserHostSessionBudget
    private let limits: BrowserHostLimits
    private let snapshot: BrowserHostSnapshot
    private let updateGate: BrowserHostUpdateGate
    private let sleeper: Sleeper
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private var fence: BrowserHostEndpointFence?
    private var owner: BrowserIntakeOwner?
    private var projection: BrowserContractProjection?
    private var rootURL: URL?
    private var listeningFD: Int32 = -1
    private var lifecycle = BrowserHostLifecycle()
    private var acceptingModes: Set<NativeHostMode> = [.production]
    private var registration: [BrowserBrand: BrowserHostRegistrationSummary] = [:]
    private var profiles = BrowserHostProfileTable()
    private var sessions: [UUID: (Int32, BrowserHostOutbound)] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionAuthorities: [UUID: BrowserHostSessionAuthority] = [:]
    private var acceptTask: Task<Void, Never>?
    private var starting = false
    private var startupAttempt: UInt64 = 0
    private var quiescenceTask: Task<Void, Never>?
    private let publicationValidity = BrowserHostPublicationValidity()
    private var currentSnapshot = BrowserHostSnapshotValue()
    private let publicationWillEnqueue: @Sendable () async -> Void
    private let beforeBatchAdmission: @Sendable () async -> Void

    public init(
        limits: BrowserHostLimits,
        snapshot: BrowserHostSnapshot,
        updateGate: BrowserHostUpdateGate,
        sleeper: @escaping Sleeper = { duration in try? await Task.sleep(for: duration) },
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        publicationWillEnqueue: @escaping @Sendable () async -> Void = {},
        beforeBatchAdmission: @escaping @Sendable () async -> Void = {}
    ) {
        self.limits = limits
        self.budget = BrowserHostSessionBudget(limits: limits)
        self.snapshot = snapshot
        self.updateGate = updateGate
        self.sleeper = sleeper
        self.now = now
        self.uptime = uptime
        self.publicationWillEnqueue = publicationWillEnqueue
        self.beforeBatchAdmission = beforeBatchAdmission
    }

    public func start(
        rootURL: URL,
        owner: BrowserIntakeOwner,
        projection: BrowserContractProjection,
        registration: BrowserHostRegistrationReport,
        generation: Int,
        mode: NativeHostMode = .production,
        isCurrent: @escaping @Sendable () -> Bool = { true }
    ) async {
        await start(
            rootURL: rootURL,
            owner: owner,
            projection: projection,
            registration: registration,
            generation: generation,
            modes: [mode],
            isCurrent: isCurrent
        )
    }

    public func start(
        rootURL: URL,
        owner: BrowserIntakeOwner,
        projection: BrowserContractProjection,
        registration: BrowserHostRegistrationReport,
        generation: Int,
        modes: Set<NativeHostMode>,
        isCurrent: @escaping @Sendable () -> Bool = { true }
    ) async {
        guard !starting, listeningFD < 0, isCurrent(), admissionGate.prepare(generation: generation) else { return }
        publicationValidity.advance()
        starting = true
        startupAttempt &+= 1
        let attempt = startupAttempt
        defer { if startupAttempt == attempt { starting = false } }
        self.rootURL = rootURL
        self.owner = owner
        self.projection = projection
        self.acceptingModes = modes.intersection(NativeHostMode.enabledModes)
        if !registration.outcomes.isEmpty || self.registration.isEmpty {
            self.registration = Dictionary(uniqueKeysWithValues: registration.outcomes.map { key, value in
                (key, BrowserHostRegistrationSummary(state: value.state, reasonCode: value.reasonCode))
            })
        }
        await owner.setStatusChangeHandler { [weak self] in await self?.refreshSnapshot() }
        guard startupAttempt == attempt, isCurrent(), admissionGate.prepare(generation: generation) else { return }
        let endpointFence = BrowserHostEndpointFence(rootURL: rootURL)
        fence = endpointFence
        do {
            let fd = try endpointFence.bindListener()
            try NativeHostFrameIO.makeNonblocking(fd)
            guard isCurrent(), admissionGate.install(listenerFD: fd, generation: generation) else {
                endpointFence.release()
                fence = nil
                return
            }
            listeningFD = fd
            lifecycle.install(generation: generation)
            await owner.setAdmissionOpen { [admissionGate] in admissionGate.isOpen() }
            guard startupAttempt == attempt, isCurrent(), admissionGate.isOpen(generation: generation) else {
                if fence === endpointFence {
                    admissionGate.close()
                    endpointFence.release()
                    fence = nil
                    listeningFD = -1
                    publishStatus(.unavailable)
                }
                return
            }
            publishStatus(.available)
            let gate = admissionGate
            let budget = budget
            let limits = limits
            let updateGate = updateGate
            let projection = projection
            acceptTask = Task.detached(priority: .userInitiated) { [weak self] in
                await Self.acceptLoop(
                    fd: fd,
                    generation: generation,
                    gate: gate,
                    budget: budget,
                    limits: limits,
                    updateGate: updateGate,
                    projection: projection,
                    listener: self
                )
            }
        } catch BrowserHostListenerError.endpointCollision {
            endpointFence.release()
            fence = nil
            publishStatus(.collision)
        } catch BrowserHostListenerError.socketPathTooLong {
            endpointFence.release()
            fence = nil
            publishStatus(.pathTooLong)
        } catch {
            endpointFence.release()
            fence = nil
            publishStatus(.unavailable)
            Logger.storage.error("Browser host listener unavailable: endpoint setup failed")
        }
        await publishCurrentStatus()
    }

    func repairStaleEndpoint(rootURL: URL, isCurrent: @Sendable () -> Bool = { true }) -> BrowserHostEndpointDisposition {
        guard isCurrent() else { return .refused }
        do { return try BrowserHostEndpointFence(rootURL: rootURL).repairStaleEndpoint() }
        catch { return .refused }
    }

    public var holdsEndpointFence: Bool { fence != nil && listeningFD >= 0 && admissionGate.isOpen() }

    public func noteRegistration(_ report: BrowserHostRegistrationReport, isCurrent: @escaping @Sendable () -> Bool = { true }) async {
        guard isCurrent() else { return }
        registration = Dictionary(uniqueKeysWithValues: report.outcomes.map { brand, outcome in
            (brand, BrowserHostRegistrationSummary(state: outcome.state, reasonCode: outcome.reasonCode))
        })
        await publishCurrentStatus(isCurrent: isCurrent)
    }

    func flushOutput() async {
        let channels = sessions.values.map { $0.1 }
        for channel in channels { await channel.flush() }
    }

    public func refreshSnapshot() async {
        await publishCurrentStatus()
    }

    public nonisolated func commitClose(reason: ExitReason, generation: Int) {
        guard admissionGate.commitClose(reason: reason, generation: generation) else { return }
        Task { await self.close(reason: reason, generation: generation) }
    }

    public func finishCommittedClose(generation: Int) async {
        guard let request = admissionGate.committedClose(generation: generation) else { return }
        await close(reason: request.0, generation: request.1)
    }

    public func finalizeCommittedClose(generation: Int) {
        guard let request = admissionGate.committedClose(generation: generation),
              request.0 != .updaterInstall else { return }
        cleanup(generation: generation)
    }

    public func close(reason: ExitReason, generation: Int) async {
        guard lifecycle.beginClose(reason: reason, generation: generation) else {
            if generation == lifecycle.generation &+ 1 { await quiescenceTask?.value }
            return
        }
        admissionGate.close()
        for authority in sessionAuthorities.values { authority.invalidate() }
        publishStatus(currentSnapshot.listener)
        let bye = Self.byeMessage(reason: reason)
        let connections = Array(sessions.values)
        let readers = Array(sessionTasks.values)
        let acceptor = acceptTask
        let wait = Task {
            await withTaskGroup(of: Void.self) { group in
                for (_, outbound) in connections {
                    group.addTask {
                        await outbound.enqueueBye(bye)
                        await outbound.finish()
                    }
                }
                for reader in readers { group.addTask { await reader.value } }
                if let acceptor { group.addTask { await acceptor.value } }
            }
            await self.completeClose(generation: generation)
        }
        quiescenceTask = wait
        await wait.value
    }

    private func completeClose(generation: Int) async {
        guard generation == lifecycle.generation &+ 1 else { return }
        acceptTask = nil
        _ = lifecycle.finishQuiescence(generation: generation)
        cleanup(generation: generation)
        await publishCurrentStatus()
        quiescenceTask = nil
    }

    private static func byeMessage(reason: ExitReason) -> Data {
        let value: String
        switch reason {
        case .ordinaryQuit, .externalQuit, .placementRepair, .journalUpdaterInstall: value = "shutdown"
        case .settingsRestart: value = "replaced"
        case .updaterInstall: value = "update"
        }
        return Data("{\"type\":\"bye\",\"reason\":\"\(value)\"}".utf8)
    }

    public func resumeAfterFailedUpdaterInstall(generation: Int, isCurrent: @escaping @Sendable () -> Bool = { true }) async {
        guard isCurrent(), generation > lifecycle.generation else { return }
        await quiescenceTask?.value
        guard isCurrent(), generation > lifecycle.generation else { return }
        publicationValidity.advance()
        quiescenceTask = nil
        startupAttempt &+= 1
        starting = false
        let previousGeneration = lifecycle.generation
        admissionGate.close()
        cleanup(generation: previousGeneration &+ 1)
        lifecycle.prepareRecovery(generation: generation)
        guard let rootURL, let owner, let projection else { return }
        guard listeningFD < 0 else { return }
        await start(
            rootURL: rootURL,
            owner: owner,
            projection: projection,
            registration: BrowserHostRegistrationReport(outcomes: [:], changedAny: false),
            generation: generation,
            modes: acceptingModes,
            isCurrent: isCurrent
        )
    }

    private func cleanup(generation: Int) {
        guard generation == lifecycle.generation &+ 1 else { return }
        if listeningFD >= 0 {
            _ = Darwin.shutdown(listeningFD, SHUT_RDWR)
            if fence == nil {
                Darwin.close(listeningFD)
            }
            listeningFD = -1
        }
        fence?.release()
        fence = nil
        admissionGate.close()
    }

    public func startIfNeeded(rootURL: URL, isCurrent: @escaping @Sendable () -> Bool = { true }) async {
        guard isCurrent(), !lifecycle.shutdown, listeningFD < 0, let owner, let projection else { return }
        await start(
            rootURL: rootURL,
            owner: owner,
            projection: projection,
            registration: BrowserHostRegistrationReport(outcomes: [:], changedAny: false),
            generation: lifecycle.generation,
            modes: acceptingModes,
            isCurrent: isCurrent
        )
    }

    func isCompatibleSession(sessionID: UUID, inst: String) async -> Bool {
        guard admissionGate.isOpen() else { return false }
        guard let key = profiles.sessionKey(for: sessionID), BrowserOpaqueString.equals(key.inst, inst) else { return false }
        guard let profile = profiles.entries[key] else { return false }
        guard profile.handshake == .compatible, profile.byeReason == nil else { return false }
        guard let authority = sessionAuthorities[sessionID], authority.isLive,
              authority.epoch == owner?.store.getDestinationGeneration() else { return false }
        return true
    }

    @discardableResult
    func refreshLease(sessionID: UUID) -> Bool {
        guard sessionAuthorities[sessionID]?.renew() == true else { return false }
        let now = now()
        let expiry = now.addingTimeInterval(Double(projection?.policy.freshnessMaxMs ?? 15_000) / 1000)
        profiles.refreshLease(sessionID: sessionID, expiry: expiry)
        return true
    }

    private func publishStatus(_ listenerState: BrowserHostListenerState) {
        currentSnapshot = BrowserHostSnapshotValue(
            intakeEnabled: currentSnapshot.intakeEnabled,
            capture: currentSnapshot.capture,
            delivery: currentSnapshot.delivery,
            failureCode: currentSnapshot.failureCode,
            custodyFull: currentSnapshot.custodyFull,
            custodyStale: currentSnapshot.custodyStale,
            custodyPresent: currentSnapshot.custodyPresent,
            profiles: profileGroups(),
            registration: registration,
            listener: listenerState,
            shutdown: lifecycle.shutdown,
            quiescence: lifecycle.quiescence
        )
        let value = currentSnapshot
        let revision = publicationValidity.advance()
        Task { @MainActor [snapshot, publicationValidity] in
            guard publicationValidity.isCurrent(revision) else { return }
            snapshot.publish(value)
        }
    }

    private func publishCurrentStatus(isCurrent: @escaping @Sendable () -> Bool = { true }) async {
        let revision = publicationValidity.advance()
        let current: @Sendable () -> Bool = { [publicationValidity] in
            isCurrent() && publicationValidity.isCurrent(revision)
        }
        guard let owner else { return }
        let projected = await owner.currentHostProjection()
        let aboutRouteEpoch = await owner.aboutRouteEpoch()
        guard current() else { return }
        let facts = projected.facts
        let currentPeriodID = facts.periodId
        let currentDestGen = facts.destinationGeneration
        var boundary: Data?
        var failedValidation = projected.state == nil
        if let currentPeriodID, let currentDestGen, let projection {
            let object: [String: Any] = ["type": "boundary", "destination_generation": currentDestGen, "period_id": currentPeriodID]
            if let message = try? BrowserPayloadDecoder.validatedHostMessage(object, projection: projection) {
                boundary = BrowserPayloadDecoder.encodeHostToExtension(message)
            } else { failedValidation = true }
        }
        var invalidated: [BrowserHostOutbound] = []
        for (id, (_, outbound)) in sessions {
            if let authority = sessionAuthorities[id], failedValidation || authority.epoch != currentDestGen {
                authority.invalidate()
                profiles.dropCompatible(sessionID: id)
                invalidated.append(outbound)
            }
        }
        currentSnapshot = BrowserHostSnapshotValue(
            intakeEnabled: facts.intakeEnabled, capture: facts.capture, delivery: facts.delivery,
            failureCode: facts.failureCode, custodyFull: facts.custodyFull, custodyStale: facts.custodyStale,
            custodyPresent: facts.custodyPresent, profiles: profileGroups(), registration: registration,
            listener: currentSnapshot.listener, shutdown: lifecycle.shutdown, quiescence: lifecycle.quiescence
        )
        let value = currentSnapshot
        await MainActor.run { if current() { snapshot.publish(value) } }
        guard current() else { return }
        for outbound in invalidated {
            await outbound.enqueueBye(Data("{\"type\":\"bye\",\"reason\":\"replaced\"}".utf8))
            guard current() else { return }
        }
        guard let state = projected.state, !failedValidation else { return }
        await publicationWillEnqueue()
        guard current() else { return }
        for (id, (_, outbound)) in sessions {
            guard let authority = sessionAuthorities[id], authority.isLive,
                  profiles.sessionKey(for: id) != nil else { continue }
            let gate = admissionGate, store = owner.store
            let eligible: @Sendable () -> Bool = {
                current() && gate.isOpen() && authority.isLive &&
                    authority.epoch == currentDestGen && authority.epoch == store.getDestinationGeneration()
            }
            guard await owner.aboutRouteEpoch() == aboutRouteEpoch else { return }
            await outbound.enqueuePublication(state: state, boundary: boundary,
                periodID: currentPeriodID, destinationGeneration: currentDestGen, isCurrent: eligible)
            guard current() else { return }
        }
    }

    public func formatState() async -> Data? {
        guard let owner else { return nil }
        return await owner.projectedStateData()
    }

    private func profileGroups() -> BrowserHostProfileGroup {
        var chrome: [BrowserHostProfile] = []
        var edge: [BrowserHostProfile] = []
        var firefox: [BrowserHostProfile] = []
        for (key, profile) in profiles.entries {
            let live = profiles.sessionID(brand: key.brand, inst: key.inst).flatMap { sessionAuthorities[$0] }
            let expiry = admissionGate.isOpen() && live?.isLive == true && live?.epoch == owner?.store.getDestinationGeneration()
                ? now().addingTimeInterval(live?.remaining ?? 0) : nil
            let profile = BrowserHostProfile(lastSeen: profile.lastSeen, handshake: profile.handshake,
                                             byeReason: profile.byeReason, leaseExpiry: expiry)
            switch key.brand {
            case .chrome: chrome.append(profile)
            case .edge: edge.append(profile)
            case .firefox: firefox.append(profile)
            }
        }
        return BrowserHostProfileGroup(chrome: chrome, edge: edge, firefox: firefox)
    }

    func recordProfile(_ id: UUID, brand: BrowserBrand, inst: String, epoch: String? = nil, handshake: BrowserHostHandshake, bye: String? = nil) async {
        var previousOutbound: BrowserHostOutbound?
        if let previous = profiles.sessionID(brand: brand, inst: inst), previous != id {
            sessionAuthorities[previous]?.invalidate()
            profiles.disconnect(sessionID: previous)
            previousOutbound = sessions[previous]?.1
        }
        // Install replacement authority and profile atomically before yielding to the old writer.
        publicationValidity.advance()
        let now = now()
        if handshake == .compatible {
            sessionAuthorities[id] = BrowserHostSessionAuthority(inst: inst, epoch: epoch,
                freshnessMs: projection?.policy.freshnessMaxMs ?? 15_000, uptime: uptime)
        }
        profiles.record(sessionID: id, brand: brand, inst: inst, epoch: epoch, profile: BrowserHostProfile(
            lastSeen: now, handshake: handshake, byeReason: bye,
            leaseExpiry: now.addingTimeInterval(Double(projection?.policy.freshnessMaxMs ?? 15_000) / 1000)
        ))
        if let previousOutbound {
            await previousOutbound.enqueueBye(Data("{\"type\":\"bye\",\"reason\":\"replaced\"}".utf8))
        }
    }

    private func admit(_ descriptor: Int32, outbound: BrowserHostOutbound, generation: Int, connectedAt: UInt64) -> UUID? {
        guard admissionGate.isOpen(generation: generation), let owner, let projection else { return nil }
        let id = UUID()
        guard budget.open(id) else { return nil }
        sessions[id] = (descriptor, outbound)
        let modes = acceptingModes, limits = limits, budget = budget, updateGate = updateGate, gate = admissionGate
        sessionTasks[id] = Task { [self] in
            await Self.serve(descriptor: descriptor, sessionID: id, outbound: outbound,
                             acceptingModes: modes, owner: owner, projection: projection,
                             limits: limits, budget: budget, updateGate: updateGate,
                             gate: gate, generation: generation, listener: self, connectedAt: connectedAt)
            await finishSession(id)
            Darwin.close(descriptor)
            sessionTasks.removeValue(forKey: id)
        }
        return id
    }

    private func finishSession(_ id: UUID) async {
        publicationValidity.advance()
        sessionAuthorities.removeValue(forKey: id)?.invalidate()
        if let (_, outbound) = sessions.removeValue(forKey: id) {
            profiles.disconnect(sessionID: id)
            // A reader may notice the synchronous quit gate before close() runs on this actor.
            // It still owes the peer that committed BYE before releasing its writer.
            if let reason = admissionGate.committedClose(generation: lifecycle.generation &+ 1)?.0 ?? lifecycle.closingReason {
                await outbound.enqueueBye(Self.byeMessage(reason: reason))
            }
            await outbound.finish()
        }
        profiles.disconnect(sessionID: id)
        budget.close(id)
        await publishCurrentStatus()
    }

    public enum BrowserHostFirstMessageDecision: Equatable, Sendable {
        case compatible(brand: BrowserBrand, inst: String, hello: BrowserDecodedHello)
        case unsupportedApp(brand: BrowserBrand, inst: String)
        case unsupportedExtension(brand: BrowserBrand, inst: String)
        case close
    }

    public static func decideFirstMessage(
        body: Data,
        context: BrowserHostConnectionContext,
        acceptingModes: Set<NativeHostMode>,
        isFresh: Bool,
        projection: BrowserContractProjection,
        updateGate: BrowserHostUpdateGate,
        isCurrent: @escaping @Sendable () -> Bool = { true },
        decoded existing: BrowserDecodeResult? = nil
    ) async -> BrowserHostFirstMessageDecision {
        guard isFresh, isCurrent() else { return .close }
        guard acceptingModes.contains(context.mode), NativeHostMode.enabledModes.contains(context.mode) else { return .close }
        let decoded = existing ?? BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection)
        switch decoded {
        case .accept(.hello(let hello)):
            guard let brand = BrowserBrand(rawValue: hello.brand),
                  (context.brandHint == .firefox) == (brand == .firefox) else { return .close }
            guard isAllowlisted(mode: context.mode, brand: brand, projection: projection) else { return .close }
            return .compatible(brand: brand, inst: hello.inst, hello: hello)
        case .unsupported:
            guard let brand = brand(in: body),
                  (context.brandHint == .firefox) == (brand == .firefox) else { return .close }
            let allowlisted = isAllowlisted(mode: context.mode, brand: brand, projection: projection)
            let inst = inst(in: body) ?? UUID().uuidString
            let obsolete = !isCurrent()
            if BrowserHostUpdateEligibility.shouldRequest(
                decoded: decoded,
                firstMessage: true,
                fresh: isFresh,
                allowlisted: allowlisted,
                modeMatches: acceptingModes.contains(context.mode),
                obsolete: obsolete
            ) {
                _ = await updateGate.requestForAppBehindHello(isCurrent: isCurrent)
                return .unsupportedApp(brand: brand, inst: inst)
            } else {
                return .unsupportedExtension(brand: brand, inst: inst)
            }
        case .accept, .refuse:
            return .close
        }
    }

    private static func isAllowlisted(mode: NativeHostMode, brand: BrowserBrand, projection: BrowserContractProjection) -> Bool {
        switch mode {
        case .production:
            switch brand {
            case .chrome: return !projection.prodHosts.chromeId.isEmpty
            case .edge: return !projection.prodHosts.edgeId.isEmpty
            case .firefox: return !projection.prodHosts.firefoxId.isEmpty
            }
        case .development:
            switch brand {
            case .chrome: return !projection.devHosts.chromeId.isEmpty
            case .edge: return !projection.devHosts.edgeId.isEmpty
            case .firefox: return !projection.devHosts.firefoxId.isEmpty
            }
        }
    }

    private static func acceptLoop(
        fd: Int32,
        generation: Int,
        gate: BrowserHostAdmissionGate,
        budget: BrowserHostSessionBudget,
        limits: BrowserHostLimits,
        updateGate: BrowserHostUpdateGate,
        projection: BrowserContractProjection,
        listener: BrowserHostListener?
    ) async {
        while gate.isOpen(generation: generation) {
            let client: Int32
            do {
                client = try await BrowserHostIO.perform {
                    var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&readiness, 1, 250) > 0, gate.isOpen(generation: generation) else { return -1 }
                    return Darwin.accept(fd, nil, nil)
                }
            } catch { break }
            guard client >= 0 else {
                if gate.isOpen(generation: generation) { continue }
                break
            }
            let connectedAt = DispatchTime.now().uptimeNanoseconds
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid(),
                  gate.isOpen(generation: generation), let listener else {
                Darwin.close(client)
                continue
            }
            let outbound = BrowserHostOutbound(sink: FDByteSink(fd: client, limits: limits))
            guard await listener.admit(client, outbound: outbound, generation: generation, connectedAt: connectedAt) != nil else {
                Darwin.close(client)
                continue
            }
        }
    }

    private static func serve(
        descriptor: Int32, sessionID: UUID, outbound: BrowserHostOutbound,
        acceptingModes: Set<NativeHostMode>, owner: BrowserIntakeOwner,
        projection: BrowserContractProjection, limits: BrowserHostLimits,
        budget: BrowserHostSessionBudget, updateGate: BrowserHostUpdateGate,
        gate: BrowserHostAdmissionGate, generation: Int, listener: BrowserHostListener,
        connectedAt: UInt64
    ) async {
        let lifecycleCurrent: @Sendable () -> Bool = { gate.isOpen(generation: generation) }
        let handshakeLimits = Self.limits(limits, partialFrameMs: min(limits.partialFrameMs, limits.handshakeMs))
        let contextFrame: NativeHostFrame
        do {
            guard let frame = try await readFrame(descriptor: descriptor, direction: .control,
                limits: handshakeLimits, firstByteTimeoutMs: limits.handshakeMs,
                budget: budget, isCurrent: lifecycleCurrent) else { return }
            contextFrame = frame
        } catch { return }
        let contextWorkingBytes = contextFrame.body.count * 512
        guard contextFrame.body.count <= 512, budget.reserveInput(contextWorkingBytes, large: false) else {
            budget.releaseInput(contextFrame.reservedByteCount, large: contextFrame.isLargeAssembly)
            return
        }
        let context = BrowserHostConnectionContext.decode(contextFrame.body)
        budget.releaseInput(contextWorkingBytes, large: false)
        budget.releaseInput(contextFrame.reservedByteCount, large: contextFrame.isLargeAssembly)
        guard let context, acceptingModes.contains(context.mode), lifecycleCurrent() else { return }

        var authority: BrowserHostSessionAuthority?
        var renewal: Task<Void, Never>?
        defer { renewal?.cancel() }
        var first = true
        while lifecycleCurrent() {
            let remaining = remainingHandshakeMs(connectedAt: connectedAt, handshakeMs: limits.handshakeMs)
            let live: @Sendable () -> Bool
            if let authority {
                live = { lifecycleCurrent() && authority.isLive && authority.epoch == owner.store.getDestinationGeneration() }
            } else { live = lifecycleCurrent }
            let frame: NativeHostFrame
            do {
                guard let value = try await readFrame(descriptor: descriptor,
                    direction: first ? .control : .extensionToHost,
                    limits: first ? Self.limits(limits, partialFrameMs: min(limits.partialFrameMs, remaining)) : limits,
                    firstByteTimeoutMs: first ? remaining : nil, budget: budget, isCurrent: live) else { return }
                frame = value
            } catch { return }
            defer { budget.releaseInput(frame.reservedByteCount, large: frame.isLargeAssembly) }
            var workingBytes = 0
            defer { budget.releaseInput(workingBytes, large: false) }
            let decoded = BrowserPayloadDecoder.decode(bytes: frame.body, direction: "extension_to_host", projection: projection,
                reserveWorkingMemory: { amount in
                    guard budget.reserveInput(amount, large: false) else { return false }
                    workingBytes = amount
                    return true
                })
            var decision: BrowserHostFirstMessageDecision?
            if first {
                decision = await decideFirstMessage(body: frame.body, context: context,
                    acceptingModes: acceptingModes,
                    isFresh: remainingHandshakeMs(connectedAt: connectedAt, handshakeMs: limits.handshakeMs) > 0,
                    projection: projection, updateGate: updateGate, isCurrent: lifecycleCurrent, decoded: decoded)
                if decision == .close { return }
            } else {
                guard case .accept(.batch(let batch)) = decoded,
                      let authority, BrowserOpaqueString.equals(batch.inst, authority.inst), live() else { return }
            }
            guard live(), budget.reserveReply(limits.hostToExtension, for: sessionID) else { return }
            if case .accept(.batch) = decoded {
                await listener.beforeBatchAdmission()
            }
            let result = await owner.accept(decoded: decoded, sessionIsCurrent: live)
            guard lifecycleCurrent() else {
                budget.releaseReply(limits.hostToExtension, for: sessionID)
                return
            }
            guard case .message(let reply) = result else {
                budget.releaseReply(limits.hostToExtension, for: sessionID)
                return
            }
            await outbound.enqueueReply(reply) { budget.releaseReply(limits.hostToExtension, for: sessionID) }
            if let decision {
                // A hello_ack or unsupported reply reaches the wire before any state/boundary.
                await outbound.flush()
                guard lifecycleCurrent() else { return }
                switch decision {
                case .compatible(let brand, let inst, _):
                    let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
                    let epoch = object?["destination_generation"] as? String
                    await listener.recordProfile(sessionID, brand: brand, inst: inst, epoch: epoch, handshake: .compatible)
                    authority = await listener.sessionAuthorities[sessionID]
                    let sleeper = listener.sleeper
                    renewal = Task { [weak listener, weak outbound] in
                        while !Task.isCancelled {
                            await sleeper(.milliseconds(Int64(projection.policy.stateRenewalMs)))
                            guard !Task.isCancelled, let listener, let outbound,
                                  await listener.renewSession(sessionID, inst: inst, outbound: outbound) else { return }
                        }
                    }
                case .unsupportedApp(let brand, let inst):
                    await listener.recordProfile(sessionID, brand: brand, inst: inst, handshake: .unsupportedApp)
                    await listener.publishCurrentStatus()
                    return
                case .unsupportedExtension(let brand, let inst):
                    await listener.recordProfile(sessionID, brand: brand, inst: inst, handshake: .unsupportedExtension)
                    await listener.publishCurrentStatus()
                    return
                case .close: return
                }
            }
            first = false
            await listener.publishCurrentStatus()
        }
    }

    private static func readFrame(
        descriptor: Int32, direction: NativeHostFrameDirection, limits: BrowserHostLimits,
        firstByteTimeoutMs: UInt64?, budget: BrowserHostSessionBudget,
        isCurrent: @escaping @Sendable () -> Bool
    ) async throws -> NativeHostFrame? {
        try await BrowserHostIO.perform {
            try NativeHostFrameIO.readFrame(from: descriptor, direction: direction, limits: limits,
                firstByteTimeoutMs: firstByteTimeoutMs, shouldCancel: { !isCurrent() },
                reserve: { budget.reserveInput($0, large: $1) },
                release: { budget.releaseInput($0, large: $1) })
        }
    }

    private func renewSession(_ sessionID: UUID, inst: String, outbound: BrowserHostOutbound) async -> Bool {
        guard await isCompatibleSession(sessionID: sessionID, inst: inst) else {
            sessionAuthorities[sessionID]?.invalidate()
            await outbound.enqueueBye(Data("{\"type\":\"bye\",\"reason\":\"replaced\"}".utf8))
            return false
        }
        guard refreshLease(sessionID: sessionID) else {
            sessionAuthorities[sessionID]?.invalidate()
            await outbound.enqueueBye(Data("{\"type\":\"bye\",\"reason\":\"replaced\"}".utf8))
            return false
        }
        await publishCurrentStatus()
        return true
    }

    private static func brand(in body: Data, fallback: BrowserBrand = .chrome) -> BrowserBrand? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = object["brand"] as? String,
              let brand = BrowserBrand(rawValue: raw) else { return fallback }
        return brand
    }

    private static func inst(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let inst = object["inst"] as? String else { return nil }
        return inst
    }

    private static func remainingHandshakeMs(connectedAt: UInt64, handshakeMs: UInt64) -> UInt64 {
        let elapsed = (DispatchTime.now().uptimeNanoseconds &- connectedAt) / 1_000_000
        return elapsed >= handshakeMs ? 0 : handshakeMs - elapsed
    }

    private static func limits(_ limits: BrowserHostLimits, partialFrameMs: UInt64) -> BrowserHostLimits {
        BrowserHostLimits(
            extensionToHost: limits.extensionToHost,
            hostToExtension: limits.hostToExtension,
            control: limits.control,
            partialFrameMs: partialFrameMs,
            handshakeMs: limits.handshakeMs,
            sessions: limits.sessions,
            simultaneousLargeAssemblies: limits.simultaneousLargeAssemblies,
            retainedInputBytes: limits.retainedInputBytes,
            pendingReplyPerSession: limits.pendingReplyPerSession,
            pendingReplyTotal: limits.pendingReplyTotal
        )
    }
}

#endif
