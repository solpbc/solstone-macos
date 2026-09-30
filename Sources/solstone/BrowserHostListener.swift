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
}

final class FDByteSink: BrowserHostByteSink, @unchecked Sendable {
    private let fd: Int32
    private let limits: BrowserHostLimits

    init(fd: Int32, limits: BrowserHostLimits) {
        self.fd = fd
        self.limits = limits
    }

    func write(_ data: Data) async throws {
        try NativeHostFrameIO.writeFrame(
            data,
            to: fd,
            direction: .hostToExtension,
            limits: limits,
            timeoutMs: limits.handshakeMs,
            shouldCancel: { Task.isCancelled }
        )
    }
}

public actor BrowserHostOutbound {
    private let sink: any BrowserHostByteSink
    private var pendingState: Data?
    private var pendingBoundary: Data?
    private var pendingReplies: [(Data, @Sendable () -> Void)] = []
    private var pendingBye: Data?
    private var isWriting = false
    private var isClosed = false

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
        pendingBye = data
        drainIfNeeded()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        for (_, release) in pendingReplies {
            release()
        }
        pendingReplies.removeAll()
        pendingState = nil
        pendingBoundary = nil
        pendingBye = nil
    }

    private func drainIfNeeded() {
        guard !isWriting, !isClosed else { return }
        isWriting = true
        Task { [weak self] in
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
                if let bye = pendingBye {
                    pendingBye = nil
                    _ = try? await sink.write(bye)
                }
                close()
                break
            }
        }
        isWriting = false
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
        if let state = pendingState {
            pendingState = nil
            return .state(state)
        }
        if let boundary = pendingBoundary {
            pendingBoundary = nil
            return .boundary(boundary)
        }
        if !pendingReplies.isEmpty {
            let (reply, release) = pendingReplies.removeFirst()
            return .reply(reply, release)
        }
        return nil
    }
}

/// Owns the root fence lock for the listener lifetime and unlinks only its socket inode.
final class BrowserHostEndpointFence: @unchecked Sendable {
    private let rootURL: URL
    private var rootFD: Int32 = -1
    private var fenceFD: Int32 = -1
    private var listenerFD: Int32 = -1
    private var createdSocket: BrowserHostSocketIdentity?
    private let euid = geteuid()

    init(rootURL: URL) { self.rootURL = rootURL }

    deinit { release() }

    func repairStaleEndpoint() throws -> BrowserHostEndpointDisposition {
        try verifyOrCreateRoot()
        let acquired = try acquireFence(create: false)
        if !acquired {
            if fenceFD < 0 {
                if (try? endpointInfo()) != nil {
                    return .refused
                } else {
                    guard rootStillVerified() else { return .refused }
                    return .absent
                }
            } else {
                release()
                return .live
            }
        }
        defer { release() }
        guard let first = try endpointInfo() else {
            guard rootStillVerified(), (try? endpointInfo()) == nil else { return .refused }
            return .absent
        }

        let path = rootURL.appendingPathComponent("host.sock").path
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            let flags = fcntl(probe, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(probe, F_SETFL, flags | O_NONBLOCK) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                    for (index, byte) in pathBytes.enumerated() { chars[index] = CChar(bitPattern: byte) }
                    chars[pathBytes.count] = 0
                }
            }
            let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
            let connectResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, addressLength) }
            }
            let connectErrno = errno
            Darwin.close(probe)
            if connectResult == 0 || connectErrno == EINPROGRESS || connectErrno == EWOULDBLOCK || connectErrno == EALREADY {
                return .live
            }
        }

        var fenceBuffer = [CChar](repeating: 0, count: 64)
        let bytesRead = pread(fenceFD, &fenceBuffer, 63, 0)
        guard bytesRead > 0 else { return .refused }
        fenceBuffer[bytesRead] = 0
        let fenceContent = String(cString: fenceBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedRecord = "\(first.device):\(first.inode)"
        guard fenceContent == expectedRecord else { return .refused }

        guard let second = try endpointInfo(),
              BrowserHostEndpointRepairPolicy.mayRemove(
                first: BrowserHostEndpointIdentity(first),
                rechecked: BrowserHostEndpointIdentity(second),
                rootVerified: rootStillVerified(),
                effectiveUID: euid
              ),
              second.inode == first.inode, second.device == first.device else { return .refused }
        guard unlinkat(rootFD, "host.sock", 0) == 0 else { return .refused }
        return .removed
    }

    /// Read-only endpoint classification. Does not create, chmod, or unlink.
    func inspectEndpoint() -> BrowserHostEndpointDisposition {
        var rootInfo = stat()
        guard lstat(rootURL.path, &rootInfo) == 0 else { return .absent }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR, rootInfo.st_uid == euid,
              (rootInfo.st_mode & 0o777) == 0o700 else { return .refused }
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { return .refused }
        defer { Darwin.close(root) }
        var socketInfo = stat()
        if fstatat(root, "host.sock", &socketInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            return errno == ENOENT ? .absent : .refused
        }
        guard (socketInfo.st_mode & S_IFMT) == S_IFSOCK, socketInfo.st_uid == euid,
              (socketInfo.st_mode & 0o777) == 0o600 else { return .refused }
        return .live
    }

    func bindListener() throws -> Int32 {
        try verifyOrCreateRoot()
        guard try acquireFence(create: true) else {
            release()
            throw BrowserHostListenerError.endpointCollision
        }
        guard rootStillVerified() else { throw BrowserHostListenerError.unsafeEndpoint }
        guard try endpointInfo() == nil else { throw BrowserHostListenerError.endpointCollision }

        let path = rootURL.appendingPathComponent("host.sock").path
        guard NativeHostSocketPath.fits(path) else {
            throw BrowserHostListenerError.socketPathTooLong
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrowserHostListenerError.socketFailure }
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                for (index, byte) in bytes.enumerated() { chars[index] = CChar(bitPattern: byte) }
                chars[bytes.count] = 0
            }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, addressLength) }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            if errno == EADDRINUSE { throw BrowserHostListenerError.endpointCollision }
            throw BrowserHostListenerError.socketFailure
        }
        var descStat = stat()
        guard fstat(descriptor, &descStat) == 0,
              fchmodat(rootFD, "host.sock", 0o600, 0) == 0,
              listen(descriptor, 16) == 0,
              let info = try? endpointInfo(), info.kind == S_IFSOCK, info.uid == euid,
              (info.mode & 0o777) == 0o600,
              descStat.st_dev == info.st_dev, descStat.st_ino == info.st_ino else {
            Darwin.close(descriptor)
            if let current = try? endpointInfo(),
               current.kind == S_IFSOCK, current.uid == euid,
               descStat.st_dev == current.st_dev, descStat.st_ino == current.st_ino {
                _ = unlinkat(rootFD, "host.sock", 0)
            }
            throw BrowserHostListenerError.unsafeEndpoint
        }
        listenerFD = descriptor
        createdSocket = BrowserHostSocketIdentity(device: info.device, inode: info.inode)
        let payload = "\(info.device):\(info.inode)\n"
        _ = ftruncate(fenceFD, 0)
        payload.utf8CString.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = pwrite(fenceFD, base, buffer.count - 1, 0)
        }
        return descriptor
    }

    func closeListener() {
        guard listenerFD >= 0 else { return }
        _ = shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        listenerFD = -1
    }

    func cleanupOwnedSocket() {
        guard fenceFD >= 0, rootFD >= 0, let createdSocket,
              let info = try? endpointInfo(),
              BrowserHostEndpointRepairPolicy.mayCleanup(
                created: createdSocket,
                current: BrowserHostEndpointIdentity(info),
                rootVerified: rootStillVerified(),
                effectiveUID: euid
              ) else { return }
        _ = unlinkat(rootFD, "host.sock", 0)
        self.createdSocket = nil
    }

    func release() {
        closeListener()
        cleanupOwnedSocket()
        if rootFD >= 0 { Darwin.close(rootFD); rootFD = -1 }
        if fenceFD >= 0 { Darwin.close(fenceFD); fenceFD = -1 }
    }

    private func verifyOrCreateRoot() throws {
        var cursor = URL(fileURLWithPath: "/")
        for component in rootURL.standardizedFileURL.pathComponents.dropFirst() {
            cursor.appendPathComponent(component)
            var ancestor = stat()
            if lstat(cursor.path, &ancestor) == 0 {
                guard (ancestor.st_mode & S_IFMT) != S_IFLNK else { throw BrowserHostListenerError.unsafeEndpoint }
            } else if errno != ENOENT {
                throw BrowserHostListenerError.unsafeEndpoint
            }
        }
        if lstat(rootURL.path, &rootStat) != 0 {
            guard errno == ENOENT else { throw BrowserHostListenerError.unsafeEndpoint }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        guard lstat(rootURL.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR, rootStat.st_uid == euid else {
            throw BrowserHostListenerError.unsafeEndpoint
        }
        if rootFD < 0 {
            rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard rootFD >= 0 else { throw BrowserHostListenerError.unsafeEndpoint }
        }
        guard fchmod(rootFD, 0o700) == 0,
              fstat(rootFD, &rootStat) == 0,
              (rootStat.st_mode & 0o777) == 0o700,
              rootStat.st_uid == euid else { throw BrowserHostListenerError.unsafeEndpoint }
    }

    private var rootStat = stat()

    private func acquireFence(create: Bool) throws -> Bool {
        guard fenceFD < 0 else { return true }
        let flags = create ? (O_CREAT | O_RDWR | O_NOFOLLOW) : (O_RDWR | O_NOFOLLOW)
        fenceFD = openat(rootFD, "host.fence", flags, 0o600)
        guard fenceFD >= 0 else {
            if !create && errno == ENOENT { return false }
            throw BrowserHostListenerError.unsafeEndpoint
        }
        var info = stat()
        guard fstat(fenceFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == euid else {
            throw BrowserHostListenerError.unsafeEndpoint
        }
        if flock(fenceFD, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK || errno == EAGAIN { return false }
        throw BrowserHostListenerError.socketFailure
    }

    private func endpointInfo() throws -> stat? {
        var info = stat()
        if fstatat(rootFD, "host.sock", &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw BrowserHostListenerError.unsafeEndpoint
    }

    private func rootStillVerified() -> Bool {
        var info = stat()
        guard fstat(rootFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700, info.st_uid == euid else { return false }
        let freshFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard freshFD >= 0 else { return false }
        defer { Darwin.close(freshFD) }
        var freshInfo = stat()
        guard fstat(freshFD, &freshInfo) == 0 else { return false }
        return freshInfo.st_dev == info.st_dev && freshInfo.st_ino == info.st_ino
    }
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

    func install(listenerFD: Int32, generation: Int) {
        lock.withLock {
            self.listenerFD = listenerFD
            self.generation = generation
            closeRequest = nil
            accepting = true
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
            guard generation == self.generation &+ 1, accepting else { return nil }
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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
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
            handshake: .unsupportedExtension,
            byeReason: profile.byeReason,
            leaseExpiry: profile.leaseExpiry
        )
    }

    mutating func disconnect(sessionID: UUID) {
        sessionEpochs.removeValue(forKey: sessionID)
        if let key = sessionKeys.removeValue(forKey: sessionID) {
            if !sessionKeys.values.contains(key) {
                entries.removeValue(forKey: key)
            }
        }
    }

    func sessionID(for inst: String) -> UUID? {
        sessionKeys.first(where: { $0.value.inst == inst })?.key
    }

    func sessionKey(for sessionID: UUID) -> BrowserProfileKey? {
        sessionKeys[sessionID]
    }

    func count(_ brand: BrowserBrand) -> Int {
        entries.keys.filter { $0.brand == brand }.count
    }
}

public actor BrowserHostListener {
    public typealias Sleeper = @Sendable (Duration) async -> Void

    private let admissionGate = BrowserHostAdmissionGate()
    private let budget: BrowserHostSessionBudget
    private let limits: BrowserHostLimits
    private let snapshot: BrowserHostSnapshot
    private let updateGate: BrowserHostUpdateGate
    private let sleeper: Sleeper
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
    private var quiescenceTask: Task<Void, Never>?
    private var currentSnapshot = BrowserHostSnapshotValue()
    private var lastEmittedPeriodID: String?
    private var lastEmittedDestinationGeneration: String?

    public init(
        limits: BrowserHostLimits,
        snapshot: BrowserHostSnapshot,
        updateGate: BrowserHostUpdateGate,
        sleeper: @escaping Sleeper = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.limits = limits
        self.budget = BrowserHostSessionBudget(limits: limits)
        self.snapshot = snapshot
        self.updateGate = updateGate
        self.sleeper = sleeper
    }

    public func start(
        rootURL: URL,
        owner: BrowserIntakeOwner,
        projection: BrowserContractProjection,
        registration: BrowserHostRegistrationReport,
        generation: Int,
        mode: NativeHostMode = .production
    ) async {
        await start(
            rootURL: rootURL,
            owner: owner,
            projection: projection,
            registration: registration,
            generation: generation,
            modes: [mode]
        )
    }

    public func start(
        rootURL: URL,
        owner: BrowserIntakeOwner,
        projection: BrowserContractProjection,
        registration: BrowserHostRegistrationReport,
        generation: Int,
        modes: Set<NativeHostMode>
    ) async {
        guard listeningFD < 0 else { return }
        self.rootURL = rootURL
        self.owner = owner
        self.projection = projection
        self.acceptingModes = modes
        if !registration.outcomes.isEmpty || self.registration.isEmpty {
            self.registration = Dictionary(uniqueKeysWithValues: registration.outcomes.map { key, value in
                (key, BrowserHostRegistrationSummary(state: value.state, reasonCode: value.reasonCode))
            })
        }
        await owner.setStatusChangeHandler { [weak self] in await self?.refreshSnapshot() }
        let endpointFence = BrowserHostEndpointFence(rootURL: rootURL)
        fence = endpointFence
        do {
            let fd = try endpointFence.bindListener()
            listeningFD = fd
            lifecycle.install(generation: generation)
            admissionGate.install(listenerFD: fd, generation: generation)
            await owner.setAdmissionOpen { [admissionGate] in admissionGate.isOpen() }
            publishStatus(.available)
            let gate = admissionGate
            let budget = budget
            let limits = limits
            let updateGate = updateGate
            let projection = projection
            Task.detached(priority: .userInitiated) { [weak self] in
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

    func repairStaleEndpoint(rootURL: URL) -> BrowserHostEndpointDisposition {
        do { return try BrowserHostEndpointFence(rootURL: rootURL).repairStaleEndpoint() }
        catch { return .refused }
    }

    public var holdsEndpointFence: Bool { fence != nil }

    public func noteRegistration(_ report: BrowserHostRegistrationReport) async {
        registration = Dictionary(uniqueKeysWithValues: report.outcomes.map { brand, outcome in
            (brand, BrowserHostRegistrationSummary(state: outcome.state, reasonCode: outcome.reasonCode))
        })
        await publishCurrentStatus()
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
        guard lifecycle.beginClose(reason: reason, generation: generation) else { return }
        admissionGate.close()
        let byeReason: String
        switch reason {
        case .ordinaryQuit, .externalQuit, .placementRepair, .journalUpdaterInstall: byeReason = "shutdown"
        case .settingsRestart: byeReason = "replaced"
        case .updaterInstall: byeReason = "update"
        }
        let bye = Data("{\"type\":\"bye\",\"reason\":\"\(byeReason)\"}".utf8)
        for (descriptor, outbound) in sessions.values {
            await outbound.enqueueBye(bye)
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        if lifecycle.quiescence {
            await publishCurrentStatus()
            quiescenceTask?.cancel()
            let sleeper = sleeper
            let handshakeMs = limits.handshakeMs
            let wait = Task { await sleeper(.milliseconds(Int64(handshakeMs))) }
            quiescenceTask = wait
            await wait.value
            quiescenceTask = nil
            guard lifecycle.finishQuiescence(generation: generation) else { return }
            cleanup(generation: generation)
        }
        await publishCurrentStatus()
    }

    public func resumeAfterFailedUpdaterInstall(generation: Int) async {
        quiescenceTask?.cancel()
        quiescenceTask = nil
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
            modes: acceptingModes
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

    public func startIfNeeded(rootURL: URL) async {
        guard listeningFD < 0, let owner, let projection else { return }
        await start(
            rootURL: rootURL,
            owner: owner,
            projection: projection,
            registration: BrowserHostRegistrationReport(outcomes: [:], changedAny: false),
            generation: lifecycle.generation,
            modes: acceptingModes
        )
    }

    func isCompatibleSession(sessionID: UUID, inst: String) async -> Bool {
        guard admissionGate.isOpen() else { return false }
        guard let key = profiles.sessionKey(for: sessionID), key.inst == inst else { return false }
        guard let profile = profiles.entries[key] else { return false }
        guard profile.handshake == .compatible, profile.byeReason == nil else { return false }
        guard let leaseExpiry = profile.leaseExpiry, leaseExpiry > Date() else { return false }
        guard let storedEpoch = profiles.epoch(for: sessionID) else { return false }
        let currentDestGen = await owner?.currentFacts().destinationGeneration
        guard let currentDestGen, storedEpoch == currentDestGen else { return false }
        return true
    }

    func refreshLease(sessionID: UUID) {
        let now = Date()
        let expiry = now.addingTimeInterval(Double(projection?.policy.stateRenewalMs ?? 5_000) / 1000)
        profiles.refreshLease(sessionID: sessionID, expiry: expiry)
    }

    public static func emitRenewalState(
        isCompatible: Bool,
        outbound: BrowserHostOutbound,
        state: Data?
    ) async {
        guard isCompatible, let state else { return }
        await outbound.enqueueState(state)
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
        Task { @MainActor [snapshot] in snapshot.publish(value) }
    }

    private func publishCurrentStatus() async {
        let facts = await owner?.currentFacts() ?? BrowserHostOwnerFacts(status: [:], intakeEnabled: true)
        currentSnapshot = BrowserHostSnapshotValue(
            intakeEnabled: facts.intakeEnabled,
            capture: facts.capture,
            delivery: facts.delivery,
            failureCode: facts.failureCode,
            custodyFull: facts.custodyFull,
            custodyStale: facts.custodyStale,
            custodyPresent: facts.custodyPresent,
            profiles: profileGroups(),
            registration: registration,
            listener: currentSnapshot.listener,
            shutdown: lifecycle.shutdown,
            quiescence: lifecycle.quiescence
        )
        let value = currentSnapshot
        await MainActor.run { snapshot.publish(value) }

        let currentPeriodID = facts.periodId
        let currentDestGen = facts.destinationGeneration

        guard let stateData = await formatState() else {
            for (sessionID, _) in sessions {
                profiles.dropCompatible(sessionID: sessionID)
            }
            return
        }

        for (sessionID, _) in sessions {
            if let storedEpoch = profiles.epoch(for: sessionID) {
                if currentDestGen == nil || storedEpoch != currentDestGen {
                    profiles.dropCompatible(sessionID: sessionID)
                }
            } else {
                profiles.dropCompatible(sessionID: sessionID)
            }
        }

        let periodChanged = (lastEmittedPeriodID != nil && currentPeriodID != nil && currentPeriodID != lastEmittedPeriodID)
        let sameEpoch = (lastEmittedDestinationGeneration != nil && currentDestGen != nil && currentDestGen == lastEmittedDestinationGeneration)

        var boundaryData: Data?
        var boundaryValidationFailed = false
        if periodChanged && sameEpoch, let currentPeriodID, let currentDestGen, let projection {
            let boundaryDict: [String: Any] = [
                "type": "boundary",
                "destination_generation": currentDestGen,
                "period_id": currentPeriodID
            ]
            do {
                let msg = try BrowserPayloadDecoder.validatedHostMessage(boundaryDict, projection: projection)
                boundaryData = BrowserPayloadDecoder.encodeHostToExtension(msg)
            } catch {
                boundaryValidationFailed = true
            }
        }

        for (sessionID, (_, outbound)) in sessions {
            guard let key = profiles.sessionKey(for: sessionID) else { continue }
            if boundaryValidationFailed {
                profiles.dropCompatible(sessionID: sessionID)
                continue
            }
            guard await isCompatibleSession(sessionID: sessionID, inst: key.inst) else { continue }
            if let boundaryData {
                await outbound.enqueueBoundary(boundaryData)
            }
            await outbound.enqueueState(stateData)
        }

        if let currentPeriodID { lastEmittedPeriodID = currentPeriodID }
        if let currentDestGen { lastEmittedDestinationGeneration = currentDestGen }
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
            switch key.brand {
            case .chrome: chrome.append(profile)
            case .edge: edge.append(profile)
            case .firefox: firefox.append(profile)
            }
        }
        return BrowserHostProfileGroup(chrome: chrome, edge: edge, firefox: firefox)
    }

    func recordProfile(_ id: UUID, brand: BrowserBrand, inst: String, epoch: String? = nil, handshake: BrowserHostHandshake, bye: String? = nil) {
        let now = Date()
        profiles.record(sessionID: id, brand: brand, inst: inst, epoch: epoch, profile: BrowserHostProfile(
            lastSeen: now,
            handshake: handshake,
            byeReason: bye,
            leaseExpiry: now.addingTimeInterval(Double(projection?.policy.stateRenewalMs ?? 5_000) / 1000)
        ))
    }

    private func admit(_ descriptor: Int32, outbound: BrowserHostOutbound, generation: Int) -> UUID? {
        guard admissionGate.isOpen(generation: generation) else { return nil }
        let id = UUID()
        guard budget.open(id) else { return nil }
        sessions[id] = (descriptor, outbound)
        return id
    }

    private func finishSession(_ id: UUID) async {
        if let (_, outbound) = sessions.removeValue(forKey: id) {
            await outbound.close()
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
        updateGate: BrowserHostUpdateGate
    ) async -> BrowserHostFirstMessageDecision {
        guard isFresh else { return .close }
        guard acceptingModes.contains(context.mode) else { return .close }
        let decoded = BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection)
        switch decoded {
        case .accept(.hello(let hello)):
            guard let brand = BrowserBrand(rawValue: hello.brand),
                  (context.brandHint == .firefox) == (brand == .firefox) else { return .close }
            guard isAllowlisted(mode: context.mode, brand: brand, projection: projection) else { return .close }
            return .compatible(brand: brand, inst: hello.inst, hello: hello)
        case .unsupported(let proto, let behind):
            guard let brand = brand(in: body),
                  (context.brandHint == .firefox) == (brand == .firefox) else { return .close }
            let allowlisted = isAllowlisted(mode: context.mode, brand: brand, projection: projection)
            let inst = inst(in: body) ?? UUID().uuidString
            let isAppBehind = behind == "app"
            let obsolete = !isAppBehind
            if BrowserHostUpdateEligibility.shouldRequest(
                decoded: decoded,
                firstMessage: true,
                fresh: isFresh,
                allowlisted: allowlisted,
                modeMatches: acceptingModes.contains(context.mode),
                obsolete: obsolete
            ) {
                _ = await updateGate.requestForAppBehindHello()
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
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &peerLength) }
            }
            guard client >= 0 else {
                if errno == EINTR { continue }
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
            guard let sessionID = await listener.admit(client, outbound: outbound, generation: generation) else {
                Darwin.close(client)
                continue
            }
            guard let owner = await listener.owner else {
                Darwin.close(client)
                await listener.finishSession(sessionID)
                continue
            }
            let acceptingModes = await listener.acceptingModes
            Task.detached(priority: .userInitiated) {
                defer {
                    Darwin.close(client)
                    Task { await listener.finishSession(sessionID) }
                }
                await Self.serve(
                    descriptor: client,
                    sessionID: sessionID,
                    outbound: outbound,
                    acceptingModes: acceptingModes,
                    owner: owner,
                    projection: projection,
                    limits: limits,
                    budget: budget,
                    updateGate: updateGate,
                    gate: gate,
                    generation: generation,
                    listener: listener,
                    connectedAt: connectedAt
                )
            }
        }
    }

    private static func serve(
        descriptor: Int32,
        sessionID: UUID,
        outbound: BrowserHostOutbound,
        acceptingModes: Set<NativeHostMode>,
        owner: BrowserIntakeOwner,
        projection: BrowserContractProjection,
        limits: BrowserHostLimits,
        budget: BrowserHostSessionBudget,
        updateGate: BrowserHostUpdateGate,
        gate: BrowserHostAdmissionGate,
        generation: Int,
        listener: BrowserHostListener,
        connectedAt: UInt64
    ) async {
        let handshakeLimits = Self.limits(limits, partialFrameMs: min(limits.partialFrameMs, limits.handshakeMs))
        let contextFrame: NativeHostFrame?
        do {
            contextFrame = try NativeHostFrameIO.readFrame(
                from: descriptor, direction: .control, limits: handshakeLimits,
                firstByteTimeoutMs: limits.handshakeMs,
                reserve: { amount, large in budget.reserveInput(amount, large: large) },
                release: { amount, large in budget.releaseInput(amount, large: large) }
            )
        } catch { return }
        guard let contextFrame else { return }
        let decodedContext = BrowserHostConnectionContext.decode(contextFrame.body)
        budget.releaseInput(contextFrame.reservedByteCount, large: contextFrame.isLargeAssembly)
        guard let context = decodedContext, acceptingModes.contains(context.mode),
              gate.isOpen(generation: generation) else { return }

        var didHandleFirstMessage = false
        var sessionInst: String?
        var renewalTask: Task<Void, Never>?
        defer { renewalTask?.cancel() }

        while gate.isOpen(generation: generation) {
            let frame: NativeHostFrame
            do {
                guard let read = try NativeHostFrameIO.readFrame(
                    from: descriptor,
                    direction: didHandleFirstMessage ? .extensionToHost : .control,
                    limits: didHandleFirstMessage ? limits : Self.limits(
                        limits,
                        partialFrameMs: min(limits.partialFrameMs, remainingHandshakeMs(connectedAt: connectedAt, handshakeMs: limits.handshakeMs))
                    ),
                    firstByteTimeoutMs: didHandleFirstMessage ? nil : remainingHandshakeMs(connectedAt: connectedAt, handshakeMs: limits.handshakeMs),
                    reserve: { amount, large in budget.reserveInput(amount, large: large) },
                    release: { amount, large in budget.releaseInput(amount, large: large) }
                ) else { return }
                frame = read
            } catch {
                return
            }
            defer { budget.releaseInput(frame.reservedByteCount, large: frame.isLargeAssembly) }

            let body = frame.body
            let decoded = BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection)
            if !didHandleFirstMessage {
                let isFresh = remainingHandshakeMs(connectedAt: connectedAt, handshakeMs: projection.policy.handshakeMs) > 0
                let decision = await Self.decideFirstMessage(
                    body: body,
                    context: context,
                    acceptingModes: acceptingModes,
                    isFresh: isFresh,
                    projection: projection,
                    updateGate: updateGate
                )
                switch decision {
                case .compatible(let brand, let inst, _):
                    sessionInst = inst
                    let facts = await owner.currentFacts()
                    let epoch = facts.destinationGeneration
                    await listener.recordProfile(sessionID, brand: brand, inst: inst, epoch: epoch, handshake: .compatible)
                    if let stateData = await listener.formatState() {
                        await outbound.enqueueState(stateData)
                    }
                    let stateRenewalMs = UInt64(projection.policy.stateRenewalMs)
                    let sleeper = await listener.sleeper
                    renewalTask = Task { [weak listener, weak outbound] in
                        while !Task.isCancelled {
                            await sleeper(.milliseconds(Int64(stateRenewalMs)))
                            guard !Task.isCancelled, let listener, let outbound else { break }
                            let compatible = await listener.isCompatibleSession(sessionID: sessionID, inst: inst)
                            guard compatible else { break }
                            await listener.refreshLease(sessionID: sessionID)
                            let renewedState = await listener.formatState()
                            await Self.emitRenewalState(
                                isCompatible: compatible,
                                outbound: outbound,
                                state: renewedState
                            )
                        }
                    }
                case .unsupportedApp(let brand, let inst):
                    guard gate.isOpen(generation: generation) else { return }
                    await listener.recordProfile(sessionID, brand: brand, inst: inst, handshake: .unsupportedApp)
                case .unsupportedExtension(let brand, let inst):
                    await listener.recordProfile(sessionID, brand: brand, inst: inst, handshake: .unsupportedExtension)
                case .close:
                    return
                }
                didHandleFirstMessage = true
            } else {
                if case .accept(.batch(let batch)) = decoded {
                    if let sessionInst, batch.inst != sessionInst {
                        return
                    }
                }
            }

            guard budget.reserveReply(limits.hostToExtension, for: sessionID) else { return }
            guard gate.isOpen(generation: generation) else {
                budget.releaseReply(limits.hostToExtension, for: sessionID)
                return
            }
            let result = await owner.accept(bytes: body, direction: "extension_to_host")
            guard gate.isOpen(generation: generation) else {
                budget.releaseReply(limits.hostToExtension, for: sessionID)
                return
            }
            switch result {
            case .message(let reply):
                await outbound.enqueueReply(reply) { [budget] in
                    budget.releaseReply(limits.hostToExtension, for: sessionID)
                }
                await listener.publishCurrentStatus()
                if case .unsupported = decoded { return }
            case .refusal:
                budget.releaseReply(limits.hostToExtension, for: sessionID)
                return
            }
        }
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
