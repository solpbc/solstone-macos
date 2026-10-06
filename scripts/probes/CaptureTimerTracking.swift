// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreFoundation
import Foundation

private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func record(_ name: String) { lock.lock(); defer { lock.unlock() }; values[name, default: 0] += 1 }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[name, default: 0] }
}

@main
private enum CaptureTimerTrackingProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let observed = Observations()
        let mode = RunLoop.Mode.eventTracking
        // Enter tracking from a run-loop timer, rather than from a MainActor task that
        // itself holds the dispatch queue and would prevent its continuations running.
        let enter = Timer(timeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                let oneShot = CaptureTimer.schedule(interval: 0.02, repeats: false) { _ in
                    observed.record("oneShotCallback")
                    Task { @MainActor in
                        if let currentMode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()),
                           CFEqual(currentMode.rawValue, mode.rawValue as CFString) {
                            observed.record("mainActorWhileTracking")
                        }
                    }
                }
                let repeating = CaptureTimer.schedule(interval: 0.02, repeats: true) { _ in
                    observed.record("repeating")
                }
                let canceled = CaptureTimer.schedule(interval: 0.02, repeats: false) { _ in
                    observed.record("canceled")
                }
                canceled.invalidate()
                let control = Timer(timeInterval: 0.02, repeats: false) { _ in
                    observed.record("defaultControl")
                }
                RunLoop.main.add(control, forMode: .default)
                // Keep the tracking mode alive even if a mutation removes its timers.
                var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil,
                    release: nil, copyDescription: nil, equal: nil, hash: nil,
                    schedule: nil, cancel: nil, perform: { _ in })
                let source = CFRunLoopSourceCreate(nil, 0, &context)!
                CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode(rawValue: mode.rawValue as CFString))
                CFRunLoopRunInMode(CFRunLoopMode(rawValue: mode.rawValue as CFString), 0.25, false)
                var result = ["oneShotCallback": observed.count("oneShotCallback"),
                    "mainActorWhileTracking": observed.count("mainActorWhileTracking"),
                    "repeating": observed.count("repeating"),
                    "canceled": observed.count("canceled"),
                    "defaultControl": observed.count("defaultControl")]
                CFRunLoopRunInMode(CFRunLoopMode(rawValue: RunLoop.Mode.default.rawValue as CFString), 0.05, false)
                result["defaultAfterTracking"] = observed.count("defaultControl")
                result["canceledAfterTracking"] = observed.count("canceled")
                for timer in [oneShot, repeating, canceled, control] { timer.invalidate() }
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode(rawValue: mode.rawValue as CFString))
                let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                let passed = result["oneShotCallback"] == 1 && result["mainActorWhileTracking"] == 1
                    && result["repeating", default: 0] >= 2 && result["canceled"] == 0
                    && result["defaultControl"] == 0 && result["defaultAfterTracking"] == 1
                    && result["canceledAfterTracking"] == 0
                exit(passed ? 0 : 1)
            }
        }
        RunLoop.main.add(enter, forMode: .default)
        CFRunLoopRun()
        exit(2)
    }
}
