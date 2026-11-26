// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Darwin
import Foundation
import os

/// A moment on the kernel's clock, to the nanosecond.
struct FirefoxTimestamp: Comparable, Hashable, Sendable {
    let seconds: Int64
    let nanoseconds: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }
}

/// What the eligibility check reads about one running process. Each read is a seam, so tests drive
/// it without a real Firefox.
struct FirefoxProcessProbe: Sendable {
    /// The kernel's start time for the process (`proc_pidinfo` `PROC_PIDTBSDINFO`), which every
    /// process has, however it was launched.
    var startTime: @Sendable (pid_t) -> FirefoxTimestamp?
    /// The running application's own bundle.
    var bundleURL: @Sendable (pid_t) -> URL?
    /// The bundle's `Info.plist`, read from disk now, never from a cache.
    var readPropertyList: @Sendable (URL) -> [String: any Sendable]?
    /// The file's status-change time (`st_ctime`). A copy, a rename or a replacement resets it, even
    /// when the modification time is preserved.
    var statusChangeTime: @Sendable (URL) -> FirefoxTimestamp?

    static let production = FirefoxProcessProbe(
        startTime: { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return FirefoxTimestamp(seconds: Int64(info.pbi_start_tvsec), nanoseconds: Int64(info.pbi_start_tvusec) * 1000)
        },
        bundleURL: { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleURL
        },
        readPropertyList: { url in
            guard let data = try? Data(contentsOf: url),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return nil
            }
            var strings: [String: any Sendable] = [:]
            for (key, value) in object {
                if let s = value as? String { strings[key] = s }
            }
            return strings
        },
        statusChangeTime: { url in
            var st = stat()
            guard stat(url.path, &st) == 0 else { return nil }
            return FirefoxTimestamp(seconds: Int64(st.st_ctimespec.tv_sec), nanoseconds: Int64(st.st_ctimespec.tv_nsec))
        }
    )
}

/// Whether a running Firefox may be read for the website rule.
///
/// Firefox 162 lets one `AXRole` read on its application element turn its accessibility engine on
/// by itself. Through 161 that same read also turned on a mode that doubled Firefox's memory and
/// broke window moves, so no Firefox below 162 is ever read, and nothing that can't be shown to be
/// 162 or later is either. A process is judged once for its pid and start time: by its own bundle's
/// version, and only when neither that bundle's `Info.plist` nor its main executable changed after
/// the process started (a newer bundle put in place under a running older Firefox).
final class FirefoxEligibility: Sendable {
    static let bundleIdentifier = "org.mozilla.firefox"
    static let minimumMajorVersion = 162

    static let shared = FirefoxEligibility()

    private let probe: FirefoxProcessProbe
    private let cache = OSAllocatedUnfairLock(initialState: [pid_t: (start: FirefoxTimestamp, eligible: Bool)]())

    init(probe: FirefoxProcessProbe = .production) {
        self.probe = probe
    }

    /// Eligible only from the version's leading integer, 162 or more. Empty, unparseable or lower is not.
    static func versionIsEligible(_ shortVersion: String?) -> Bool {
        guard let shortVersion else { return false }
        let digits = shortVersion.trimmingCharacters(in: .whitespaces).prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let major = Int(digits) else { return false }
        return major >= minimumMajorVersion
    }

    func isEligible(pid: pid_t) -> Bool {
        guard pid > 0, let start = probe.startTime(pid) else { return false }
        if let cached = cache.withLock({ $0[pid] }), cached.start == start {
            return cached.eligible
        }
        let eligible = judge(pid: pid, start: start)
        cache.withLock { entries in
            if entries.count > 64 { entries.removeAll() }
            entries[pid] = (start, eligible)
        }
        return eligible
    }

    private func judge(pid: pid_t, start: FirefoxTimestamp) -> Bool {
        guard let bundle = probe.bundleURL(pid) else { return false }
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let plistURL = contents.appendingPathComponent("Info.plist")
        // The property list is read before either file's change time, so a bundle replaced after the
        // read still shows a change time later than the start.
        guard let plist = probe.readPropertyList(plistURL),
              plist["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
              Self.versionIsEligible(plist["CFBundleShortVersionString"] as? String),
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/") else { return false }
        let executableURL = contents.appendingPathComponent("MacOS", isDirectory: true).appendingPathComponent(executable)
        guard let plistChanged = probe.statusChangeTime(plistURL), plistChanged <= start,
              let executableChanged = probe.statusChangeTime(executableURL), executableChanged <= start else { return false }
        return true
    }
}
