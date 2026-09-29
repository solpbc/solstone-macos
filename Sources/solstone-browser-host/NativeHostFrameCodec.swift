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

public enum NativeHostSocketPath {
    public static let sunPathBytes = 104

    public static func fits(_ path: String) -> Bool {
        path.utf8.count + 1 <= sunPathBytes
    }
}

/// Incremental parser for native-messaging's four-byte little-endian length prefix.
public struct NativeHostFrameDecoder: Sendable {
    private let direction: NativeHostFrameDirection
    private let limits: BrowserHostLimits
    private var prefix = Data()
    private var body = Data()
    private var expectedLength: Int?
    private var assemblyStartedAt: Date?

    public init(direction: NativeHostFrameDirection, limits: BrowserHostLimits = .helperFallback) {
        self.direction = direction
        self.limits = limits
    }

    public var retainedByteCount: Int { prefix.count + body.count }
    public var declaredLength: Int? { expectedLength }
    public var isAssemblingLargeFrame: Bool {
        guard let expectedLength else { return false }
        return expectedLength > limits.control
    }

    public mutating func append(_ bytes: Data, now: Date = Date()) throws -> [Data] {
        if let started = assemblyStartedAt,
           now.timeIntervalSince(started) * 1000 > Double(limits.partialFrameMs) {
            reset()
            throw NativeHostFrameError.timedOut
        }

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
                guard Int(declared) <= direction.maximum(using: limits) else {
                    reset()
                    throw NativeHostFrameError.oversized
                }
                expectedLength = Int(declared)
                prefix.removeAll(keepingCapacity: false)
                if assemblyStartedAt == nil { assemblyStartedAt = now }
                if declared == 0 {
                    output.append(Data())
                    reset()
                }
                continue
            }

            guard let expectedLength else { continue }
            let amount = min(expectedLength - body.count, bytes.count - offset)
            body.append(bytes.subdata(in: offset..<(offset + amount)))
            offset += amount
            if body.count == expectedLength {
                guard String(data: body, encoding: .utf8) != nil else {
                    reset()
                    throw NativeHostFrameError.invalidUTF8
                }
                output.append(body)
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
    public static func readFrame(
        from descriptor: Int32,
        direction: NativeHostFrameDirection,
        limits: BrowserHostLimits = .helperFallback,
        firstByteTimeoutMs: UInt64? = nil,
        reserve: (_ byteCount: Int, _ large: Bool) -> Bool = { _, _ in true },
        release: (_ byteCount: Int, _ large: Bool) -> Void = { _, _ in }
    ) throws -> NativeHostFrame? {
        var prefix = [UInt8](repeating: 0, count: 4)
        var prefixCount = 0
        var startedAt: UInt64?
        let firstByteWaitStartedAt = DispatchTime.now().uptimeNanoseconds
        while prefixCount < 4 {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let timeout: Int32
            if let startedAt {
                timeout = remainingMilliseconds(startedAt: startedAt, timeoutMs: limits.partialFrameMs)
                if timeout == 0 { throw NativeHostFrameError.timedOut }
            } else if prefixCount == 0, let firstByteTimeoutMs {
                timeout = remainingMilliseconds(startedAt: firstByteWaitStartedAt, timeoutMs: firstByteTimeoutMs)
                if timeout == 0 { throw NativeHostFrameError.timedOut }
            } else {
                timeout = -1
            }
            let pollResult = poll(&pollDescriptor, 1, timeout)
            if pollResult == 0 { throw NativeHostFrameError.timedOut }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
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
                guard let startedAt else { throw NativeHostFrameError.truncatedBody }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let timeout = remainingMilliseconds(startedAt: startedAt, timeoutMs: limits.partialFrameMs)
                if timeout == 0 { throw NativeHostFrameError.timedOut }
                let pollResult = poll(&pollDescriptor, 1, timeout)
                if pollResult == 0 { throw NativeHostFrameError.timedOut }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
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
            guard String(data: body, encoding: .utf8) != nil else { throw NativeHostFrameError.invalidUTF8 }
            return NativeHostFrame(body: body, reservedByteCount: length, isLargeAssembly: large)
        } catch {
            release(length, large)
            throw error
        }
    }

    public static func writeFrame(
        _ body: Data,
        to descriptor: Int32,
        direction: NativeHostFrameDirection,
        limits: BrowserHostLimits = .helperFallback
    ) throws {
        let framed = try NativeHostFrameCodec.encode(body, direction: direction, limits: limits)
        try framed.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let amount = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                if amount < 0 {
                    if errno == EINTR { continue }
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
        guard String(data: body, encoding: .utf8) != nil else { throw NativeHostFrameError.invalidUTF8 }
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
