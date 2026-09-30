// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Darwin
import Dispatch
import Foundation

public struct BrowserHostLimits: Sendable, Equatable {
    public let extensionToHost: Int
    public let hostToExtension: Int
    public let control: Int
    public let partialFrameMs: UInt64
    public let handshakeMs: UInt64
    public let sessions: Int
    public let simultaneousLargeAssemblies: Int
    public let retainedInputBytes: Int
    public let pendingReplyPerSession: Int
    public let pendingReplyTotal: Int

    public init(
        extensionToHost: Int,
        hostToExtension: Int,
        control: Int,
        partialFrameMs: UInt64,
        handshakeMs: UInt64 = 5_000,
        sessions: Int = 16,
        simultaneousLargeAssemblies: Int = 4,
        retainedInputBytes: Int = 128 * 1024 * 1024,
        pendingReplyPerSession: Int = 128 * 1024,
        pendingReplyTotal: Int = 1024 * 1024
    ) {
        self.extensionToHost = extensionToHost
        self.hostToExtension = hostToExtension
        self.control = control
        self.partialFrameMs = partialFrameMs
        self.handshakeMs = handshakeMs
        self.sessions = sessions
        self.simultaneousLargeAssemblies = simultaneousLargeAssemblies
        self.retainedInputBytes = retainedInputBytes
        self.pendingReplyPerSession = pendingReplyPerSession
        self.pendingReplyTotal = pendingReplyTotal
    }

    public static let helperFallback = BrowserHostLimits(
        extensionToHost: 33_554_432,
        hostToExtension: 65_536,
        control: 65_536,
        partialFrameMs: 30_000,
        handshakeMs: 5_000
    )
}

public enum NativeHostFrameDirection: Sendable {
    case extensionToHost
    case hostToExtension
    case control

    fileprivate func maximum(using limits: BrowserHostLimits) -> Int {
        switch self {
        case .extensionToHost: limits.extensionToHost
        case .hostToExtension: limits.hostToExtension
        case .control: limits.control
        }
    }
}

public enum NativeHostFrameError: Error, Equatable, Sendable {
    case oversized
    case invalidUTF8
    case truncatedPrefix
    case truncatedBody
    case timedOut
}

public struct NativeHostFrame: Sendable, Equatable {
    public let body: Data
    public let reservedByteCount: Int
    public let isLargeAssembly: Bool
}

/// Strict UTF-8 validation without materializing a second body-sized string.
public enum NativeHostUTF8 {
    public static func isValid(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let first = bytes[i]
                if first < 0x80 { i += 1; continue }
                let remaining: Int
                let lower: UInt8
                let upper: UInt8
                switch first {
                case 0xC2...0xDF: remaining = 1; lower = 0x80; upper = 0xBF
                case 0xE0: remaining = 2; lower = 0xA0; upper = 0xBF
                case 0xE1...0xEC, 0xEE...0xEF: remaining = 2; lower = 0x80; upper = 0xBF
                case 0xED: remaining = 2; lower = 0x80; upper = 0x9F
                case 0xF0: remaining = 3; lower = 0x90; upper = 0xBF
                case 0xF1...0xF3: remaining = 3; lower = 0x80; upper = 0xBF
                case 0xF4: remaining = 3; lower = 0x80; upper = 0x8F
                default: return false
                }
                guard i + remaining < bytes.count, bytes[i + 1] >= lower, bytes[i + 1] <= upper else { return false }
                if remaining > 1 {
                    for offset in 2...remaining where bytes[i + offset] < 0x80 || bytes[i + offset] > 0xBF { return false }
                }
                i += remaining + 1
            }
            return true
        }
    }
}

public enum NativeHostSocketPath {
    public static let sunPathBytes = 104

    public static func fits(_ path: String) -> Bool {
        path.utf8.count + 1 <= sunPathBytes
    }
}

/// Incremental parser for native-messaging's four-byte little-endian length prefix.
public struct NativeHostFrameDecoder: Sendable {
    private var direction: NativeHostFrameDirection
    private let initialControl: Bool
    private var completedFirstFrame = false
    private let limits: BrowserHostLimits
    private var prefix = Data()
    private var body = Data()
    private var expectedLength: Int?
    private var assemblyStartedAt: Date?

    public init(direction: NativeHostFrameDirection, limits: BrowserHostLimits = .helperFallback, initialControl: Bool = false) {
        self.direction = direction
        self.limits = limits
        self.initialControl = initialControl
    }

    public var retainedByteCount: Int { prefix.count + body.count }
    public var declaredLength: Int? { expectedLength }
    public var isAssemblingLargeFrame: Bool {
        guard let expectedLength else { return false }
        return expectedLength > limits.control
    }

    public mutating func checkDeadline(now: Date = Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime)) throws {
        if let started = assemblyStartedAt,
           now.timeIntervalSince(started) * 1000 > Double(limits.partialFrameMs) {
            reset()
            throw NativeHostFrameError.timedOut
        }
    }

    public mutating func append(_ bytes: Data, now: Date = Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime)) throws -> [Data] {
        try checkDeadline(now: now)

        var output: [Data] = []
        var offset = 0
        while offset < bytes.count {
            if expectedLength == nil {
                let amount = min(4 - prefix.count, bytes.count - offset)
                prefix.append(bytes.subdata(in: offset..<(offset + amount)))
                offset += amount
                if prefix.count < 4 {
                    if assemblyStartedAt == nil { assemblyStartedAt = now }
                    continue
                }
                let declared = prefix.withUnsafeBytes { raw -> UInt32 in
                    let b = raw.bindMemory(to: UInt8.self)
                    return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
                }
                let cap = initialControl && !completedFirstFrame ? limits.control : direction.maximum(using: limits)
                guard Int(declared) <= cap else {
                    reset()
                    throw NativeHostFrameError.oversized
                }
                expectedLength = Int(declared)
                prefix.removeAll(keepingCapacity: false)
                if assemblyStartedAt == nil { assemblyStartedAt = now }
                if declared == 0 {
                    output.append(Data())
                    completedFirstFrame = true
                    reset()
                }
                continue
            }

            guard let expectedLength else { continue }
            let amount = min(expectedLength - body.count, bytes.count - offset)
            body.append(bytes.subdata(in: offset..<(offset + amount)))
            offset += amount
            if body.count == expectedLength {
                guard NativeHostUTF8.isValid(body) else {
                    reset()
                    throw NativeHostFrameError.invalidUTF8
                }
                output.append(body)
                completedFirstFrame = true
                reset()
            }
        }
        return output
    }

    public mutating func disconnect() throws {
        let hadPrefix = !prefix.isEmpty
        let hadBody = expectedLength != nil
        reset()
        if hadPrefix { throw NativeHostFrameError.truncatedPrefix }
        if hadBody { throw NativeHostFrameError.truncatedBody }
    }

    public mutating func reset() {
        prefix.removeAll(keepingCapacity: false)
        body.removeAll(keepingCapacity: false)
        expectedLength = nil
        assemblyStartedAt = nil
    }
}

/// Blocking descriptor adapter used by the helper and the app listener. The first byte may
/// wait indefinitely; once a prefix begins, the contract partial-frame deadline applies.
public enum NativeHostFrameIO {
    public static func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    public static func readFrame(
        from descriptor: Int32,
        direction: NativeHostFrameDirection,
        limits: BrowserHostLimits = .helperFallback,
        firstByteTimeoutMs: UInt64? = nil,
        shouldCancel: @Sendable () -> Bool = { false },
        reserve: (_ byteCount: Int, _ large: Bool) -> Bool = { _, _ in true },
        release: (_ byteCount: Int, _ large: Bool) -> Void = { _, _ in }
    ) throws -> NativeHostFrame? {
        try makeNonblocking(descriptor)
        var prefix = [UInt8](repeating: 0, count: 4)
        var prefixCount = 0
        var startedAt: UInt64?
        let firstByteWaitStartedAt = DispatchTime.now().uptimeNanoseconds
        while prefixCount < 4 {
            if shouldCancel() { throw NativeHostFrameError.timedOut }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let totalTimeout: Int32
            if let startedAt {
                totalTimeout = remainingMilliseconds(startedAt: startedAt, timeoutMs: limits.partialFrameMs)
                if totalTimeout == 0 { throw NativeHostFrameError.timedOut }
            } else if prefixCount == 0, let firstByteTimeoutMs {
                totalTimeout = remainingMilliseconds(startedAt: firstByteWaitStartedAt, timeoutMs: firstByteTimeoutMs)
                if totalTimeout == 0 { throw NativeHostFrameError.timedOut }
            } else {
                totalTimeout = -1
            }
            let sliceTimeout = totalTimeout >= 0 ? min(totalTimeout, 250) : 250
            let pollResult = poll(&pollDescriptor, 1, sliceTimeout)
            if shouldCancel() { throw NativeHostFrameError.timedOut }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if pollResult == 0 {
                if totalTimeout >= 0 {
                    let recheck = letRefStarted(startedAt, firstByteWaitStartedAt, prefixCount, firstByteTimeoutMs, limits.partialFrameMs)
                    if recheck == 0 { throw NativeHostFrameError.timedOut }
                }
                continue
            }
            let amount = prefix.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress!.advanced(by: prefixCount), 4 - prefixCount)
            }
            if amount == 0 {
                if prefixCount == 0 { return nil }
                throw NativeHostFrameError.truncatedPrefix
            }
            if amount < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if startedAt == nil { startedAt = DispatchTime.now().uptimeNanoseconds }
            prefixCount += amount
        }

        let length = Int(UInt32(prefix[0]) | (UInt32(prefix[1]) << 8) | (UInt32(prefix[2]) << 16) | (UInt32(prefix[3]) << 24))
        guard length <= direction.maximum(using: limits) else { throw NativeHostFrameError.oversized }
        let large = length > limits.control
        guard reserve(length, large) else { throw NativeHostFrameError.oversized }
        do {
            var body = Data(count: length)
            var bodyCount = 0
            while bodyCount < length {
                if shouldCancel() { throw NativeHostFrameError.timedOut }
                guard let startedAt else { throw NativeHostFrameError.truncatedBody }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let timeout = remainingMilliseconds(startedAt: startedAt, timeoutMs: limits.partialFrameMs)
                if timeout == 0 { throw NativeHostFrameError.timedOut }
                let sliceTimeout = min(timeout, 250)
                let pollResult = poll(&pollDescriptor, 1, sliceTimeout)
                if shouldCancel() { throw NativeHostFrameError.timedOut }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                if pollResult == 0 {
                    if remainingMilliseconds(startedAt: startedAt, timeoutMs: limits.partialFrameMs) == 0 {
                        throw NativeHostFrameError.timedOut
                    }
                    continue
                }
                let amount = body.withUnsafeMutableBytes { raw in
                    Darwin.read(descriptor, raw.baseAddress!.advanced(by: bodyCount), length - bodyCount)
                }
                if amount == 0 { throw NativeHostFrameError.truncatedBody }
                if amount < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bodyCount += amount
            }
            guard NativeHostUTF8.isValid(body) else { throw NativeHostFrameError.invalidUTF8 }
            return NativeHostFrame(body: body, reservedByteCount: length, isLargeAssembly: large)
        } catch {
            release(length, large)
            throw error
        }
    }

    private static func letRefStarted(
        _ startedAt: UInt64?,
        _ firstByteWaitStartedAt: UInt64,
        _ prefixCount: Int,
        _ firstByteTimeoutMs: UInt64?,
        _ partialFrameMs: UInt64
    ) -> Int32 {
        if let startedAt {
            return remainingMilliseconds(startedAt: startedAt, timeoutMs: partialFrameMs)
        } else if prefixCount == 0, let firstByteTimeoutMs {
            return remainingMilliseconds(startedAt: firstByteWaitStartedAt, timeoutMs: firstByteTimeoutMs)
        }
        return -1
    }

    public static func writeFrame(
        _ body: Data,
        to descriptor: Int32,
        direction: NativeHostFrameDirection,
        limits: BrowserHostLimits = .helperFallback,
        timeoutMs: UInt64 = 30_000,
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws {
        try makeNonblocking(descriptor)
        let framed = try NativeHostFrameCodec.encode(body, direction: direction, limits: limits)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        try framed.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                if shouldCancel() { throw NativeHostFrameError.timedOut }
                let remaining = remainingMilliseconds(startedAt: startedAt, timeoutMs: timeoutMs)
                if remaining == 0 { throw NativeHostFrameError.timedOut }
                let sliceTimeout = min(remaining, 250)
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let pollResult = poll(&pollDescriptor, 1, sliceTimeout)
                if shouldCancel() { throw NativeHostFrameError.timedOut }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                if pollResult == 0 {
                    if remainingMilliseconds(startedAt: startedAt, timeoutMs: timeoutMs) == 0 {
                        throw NativeHostFrameError.timedOut
                    }
                    continue
                }
                let amount = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                if amount < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                guard amount > 0 else { throw POSIXError(.EIO) }
                written += amount
            }
        }
    }


    private static func remainingMilliseconds(startedAt: UInt64, timeoutMs: UInt64) -> Int32 {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        let budget = timeoutMs &* 1_000_000
        guard elapsed < budget else { return 0 }
        let remaining = (budget - elapsed + 999_999) / 1_000_000
        return Int32(min(remaining, UInt64(Int32.max)))
    }
}

public enum NativeHostFrameCodec {
    public static func encode(
        _ body: Data,
        direction: NativeHostFrameDirection,
        limits: BrowserHostLimits = .helperFallback
    ) throws -> Data {
        guard body.count <= direction.maximum(using: limits), body.count <= Int(UInt32.max) else {
            throw NativeHostFrameError.oversized
        }
        guard NativeHostUTF8.isValid(body) else { throw NativeHostFrameError.invalidUTF8 }
        let length = UInt32(body.count)
        var result = Data([
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 24)
        ])
        result.append(body)
        return result
    }
}

#endif
