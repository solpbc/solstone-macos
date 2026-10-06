// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreFoundation
import Foundation

/// Holds the main run loop in the menu-tracking mode for several seconds while a
/// timed pause is active, and requires the countdown refresh to keep advancing.
@main
private enum PauseCountdownTrackingProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let mode = CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString)
        let enter = Timer(timeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated {
                let manager = PauseManager()
                manager.pause(for: .minutes(2))
                let before = manager.refreshTick
                // Keep the tracking mode alive even if a mutation removes its timers.
                var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil,
                    release: nil, copyDescription: nil, equal: nil, hash: nil,
                    schedule: nil, cancel: nil, perform: { _ in })
                let source = CFRunLoopSourceCreate(nil, 0, &context)!
                CFRunLoopAddSource(CFRunLoopGetMain(), source, mode)
                CFRunLoopRunInMode(mode, 3.4, false)
                let whileTracking = manager.refreshTick - before
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, mode)
                manager.resume()
                // Let a tick that fired just before resume finish its MainActor hop.
                CFRunLoopRunInMode(CFRunLoopMode(rawValue: RunLoop.Mode.default.rawValue as CFString), 0.05, false)
                let afterResume = manager.refreshTick
                CFRunLoopRunInMode(CFRunLoopMode(rawValue: RunLoop.Mode.default.rawValue as CFString), 1.6, false)
                let result = ["ticksWhileTracking": whileTracking,
                              "ticksAfterResume": manager.refreshTick - afterResume]
                let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                // A one-second timer with 0.5 s tolerance fires at least twice in 3.4 s,
                // and a resumed pause stops refreshing.
                exit(whileTracking >= 2 && result["ticksAfterResume"] == 0 ? 0 : 1)
            }
        }
        RunLoop.main.add(enter, forMode: .default)
        CFRunLoopRun()
        exit(2)
    }
}
