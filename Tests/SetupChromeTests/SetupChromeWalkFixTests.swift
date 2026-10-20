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

    // D3: a thinking card takes a click anywhere on it, not only on its radio and text.
    @Test func anOptionRowTakesClicksOnItsEmptySpace() {
        final class Counter { var n = 0 }
        let counter = Counter()
        let size = NSSize(width: 420, height: 120)
        let row = SetupOptionRow(
            isSelected: false,
            label: "your own model",
            subLabel: nil,
            description: "short.",
            action: { counter.n += 1 }
        )
        .frame(width: size.width)
        .frame(maxHeight: .infinity, alignment: .top)
        let hosted = host(row, size: size)
        defer { hosted.window.close() }

        let rowHeight = hosted.view.fittingSize.height
        // Right edge padding, middle of the row, far from any text (window coordinates).
        click(hosted.window, at: NSPoint(x: size.width - 12, y: size.height - rowHeight / 2))
        #expect(counter.n == 1, "a click in the card's empty right side did nothing")
        // Left padding under the radio.
        click(hosted.window, at: NSPoint(x: 6, y: size.height - rowHeight + 6))
        #expect(counter.n == 2, "a click in the card's bottom-left padding did nothing")
    }

    // D4 (shared half): a label and sub-label that fit side by side stay on one line, so the
    // thinking card is not taller than it needs to be.
    @Test func anOptionRowKeepsLabelAndSubLabelOnOneLineWhenTheyFit() {
        let width: CGFloat = 359 // the thinking card's row width at the 880 pt window
        func height(subLabel: String?) -> CGFloat {
            NSHostingView(rootView: SetupOptionRow(
                isSelected: false,
                label: "your own model",
                subLabel: subLabel,
                description: "your journal sends model requests to the provider or endpoint you choose.",
                action: {}
            ).frame(width: width)).fittingSize.height
        }
        let alone = height(subLabel: nil)
        let beside = height(subLabel: "your key, or your own endpoint")
        #expect(abs(beside - alone) <= 1, "sub-label wrapped the header: \(alone) alone, \(beside) with the sub-label")
    }

    // D7: the download row keeps its name and bytes on one line.
    @Test func aDownloadRowStaysOnOneLine() {
        func height(detail: String) -> CGFloat {
            NSHostingView(rootView: SetupDownloadRow(
                name: "speech recognition",
                detail: detail,
                fraction: 0.0,
                indeterminate: false,
                actionTitle: nil,
                actionEnabled: true,
                action: {}
            )).fittingSize.height
        }
        let short = height(detail: "1 MB")
        for detail in ["243 bytes of 483.3 MB", "483.2 MB of 483.3 MB"] {
            #expect(abs(height(detail: detail) - short) <= 1, "\(detail) wrapped the row")
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

    // D1: a SwiftUI window scene writes its title bar back to opaque on scene updates unless the
    // window toolbar's background is declared hidden; the setup window declares it.
    @Test func theSetupWindowKeepsItsTitleBarTransparent() throws {
        let window = try Self.source("SetupWindow.swift")
        #expect(window.contains(".toolbarBackgroundVisibility(.hidden, for: .windowToolbar)"))
        // With SwiftUI owning the bar, the setup window also hides the on-screen title and
        // names the window itself; without these macOS 27 drew the scene's title on the sun.
        #expect(window.contains(".toolbar(removing: .title)"))
        #expect(window.contains("content.navigationTitle(title)"))
    }
}
