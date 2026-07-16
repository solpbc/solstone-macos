// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

public struct JournalChildIdentity: Equatable, Sendable {
    public let pid: pid_t
    public let startTime: TimeInterval
    public let generation: UInt64

    public init(pid: pid_t, startTime: TimeInterval, generation: UInt64) {
        self.pid = pid
        self.startTime = startTime
        self.generation = generation
    }
}

public typealias ProcessEnvironmentReading = @Sendable (pid_t) -> [String: String]?
public typealias ProcessStartTimeReading = @Sendable (pid_t) -> TimeInterval?

internal let journalStartTimeToleranceS: TimeInterval = 1.5

public func defaultProcessStartTime(pid: pid_t) -> TimeInterval? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var length = MemoryLayout<kinfo_proc>.stride
    errno = 0
    let result = sysctl(&mib, u_int(mib.count), &info, &length, nil, 0)
    guard result == 0, length >= MemoryLayout<kinfo_proc>.stride else {
        return nil
    }
    let start = info.kp_proc.p_starttime
    return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
}

public func defaultProcessEnvironment(pid: pid_t) -> [String: String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var length = 0
    errno = 0
    guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
        return nil
    }

    var buffer = [UInt8](repeating: 0, count: length)
    errno = 0
    let readResult = buffer.withUnsafeMutableBufferPointer { pointer in
        sysctl(&mib, u_int(mib.count), pointer.baseAddress, &length, nil, 0)
    }
    guard readResult == 0, length >= MemoryLayout<Int32>.stride else {
        return nil
    }

    let argc = buffer.withUnsafeBytes { rawBuffer in
        rawBuffer.load(as: Int32.self)
    }
    guard argc >= 0 else { return nil }

    var offset = MemoryLayout<Int32>.stride
    func readCString() -> String {
        let start = offset
        while offset < length, buffer[offset] != 0 {
            offset += 1
        }
        let data = Data(buffer[start..<offset])
        if offset < length {
            offset += 1
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    _ = readCString()
    while offset < length, buffer[offset] == 0 {
        offset += 1
    }
    for _ in 0..<Int(argc) {
        _ = readCString()
    }
    while offset < length, buffer[offset] == 0 {
        offset += 1
    }

    var environment: [String: String] = [:]
    while offset < length {
        let entry = readCString()
        if entry.isEmpty {
            while offset < length, buffer[offset] == 0 {
                offset += 1
            }
            continue
        }
        let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        environment[String(parts[0])] = String(parts[1])
    }
    return environment
}
