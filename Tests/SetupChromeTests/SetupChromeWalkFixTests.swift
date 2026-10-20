// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SetupChrome

/// The by-eye walk of the released setup windows (2026-10-20) found these in the shared chrome.
/// Each test fails on the code the walk ran.
@Suite("SetupChrome — walk fixes")
@MainActor
struct SetupChromeWalkFixTests {
    init() {
        _ = NSApplication.shared
    }

    private static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SetupChrome/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func host<V: View>(_ view: V, size: NSSize) -> (window: NSWindow, view: NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return (window, hosting)
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
            if let event { window.sendEvent(event) }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    // The founder's 2026-10-20 ruling: the band label sits on a chip of the sheet's fill with the
    // sheet's hairline, in place of the bare rule beside it.
    @Test func theBandLabelSitsOnASheetChip() throws {
        for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let view = SetupBandLabel("the solstone app")
                .padding(6)
                .background(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
                .environment(\.colorScheme, scheme)
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
            // Inside the chip, in its 10 pt side padding, at mid height.
            let inside = try #require(rep.colorAt(x: Int((6 + 4) * scale), y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            let sheet = try #require(NSColor(SetupChromeColor.sheet(for: scheme)).usingColorSpace(.sRGB))
            #expect(abs(inside.redComponent - sheet.redComponent) < 0.02)
            #expect(abs(inside.greenComponent - sheet.greenComponent) < 0.02)
            #expect(abs(inside.blueComponent - sheet.blueComponent) < 0.02)
        }

        let window = try Self.source("SetupWindow.swift")
        #expect(window.contains("SetupBandLabel(appLabel)"))
        #expect(!window.contains(".frame(width: 1, height: 16)"), "the bare vertical rule is still in the band")
    }
}
