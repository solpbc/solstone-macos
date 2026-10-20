// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SetupChrome

/// 2026-09-23 amendment (spec § 2, § 6, § 10, § 12): the sun arc follows the owner's system
/// appearance and nothing sets the appearance by clock. Two halves: the background view draws
/// the ground of whichever appearance its window is in, at noon and in the middle of the night;
/// and no source in the journal app sets an appearance at all. The shared modules it draws with
/// are scanned by the same rule in the capture package.
@Suite("SunArc — the appearance follows the system")
@MainActor
struct SunArcAppearanceFollowsSystemTests {
    static let size = CGSize(width: 720, height: 500)
    static let denver = TimeZone(identifier: "America/Denver")!
    static let noon = Date(timeIntervalSince1970: 1_790_190_000) // 2026-09-23 13:00 MDT
    static let oneAM = Date(timeIntervalSince1970: 1_790_146_800) // 2026-09-23 01:00 MDT, true dark

    init() {
        _ = NSApplication.shared
    }

    /// Renders the background in a hosting view whose `NSAppearance` is set, the way a window
    /// inherits the system's, with no SwiftUI override; returns the sRGB pixel at the
    /// bottom-left corner, clear of the sun at 13:00 and bare ground at 01:00.
    private func cornerPixel(date: Date, appearance: NSAppearance.Name) throws -> (r: Double, g: Double, b: Double) {
        let view = SunArcBackgroundView(fixedDate: date, timeZone: Self.denver)
            .frame(width: Self.size.width, height: Self.size.height)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let color = try #require(rep.colorAt(x: 2, y: rep.pixelsHigh - 3)?.usingColorSpace(.sRGB))
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    private func isClose(_ pixel: (r: Double, g: Double, b: Double), to hex: String, within levels: Double = 8) -> Bool {
        let want = SunArcOKLab.rgb(fromHex: hex)
        return abs(pixel.r - want.r) * 255 <= levels && abs(pixel.g - want.g) * 255 <= levels && abs(pixel.b - want.b) * 255 <= levels
    }

    @Test func aLightWindowDrawsTheLightGroundAtNoonAndAtOneInTheMorning() throws {
        let noon = try cornerPixel(date: Self.noon, appearance: .aqua)
        #expect(isClose(noon, to: SunArcAppearance.light.grounds.day), "noon light pixel \(noon)")
        let night = try cornerPixel(date: Self.oneAM, appearance: .aqua)
        #expect(isClose(night, to: SunArcAppearance.light.grounds.trueDark), "01:00 light pixel \(night)")
    }

    @Test func aDarkWindowDrawsTheDarkGroundAtNoonAndAtOneInTheMorning() throws {
        let noon = try cornerPixel(date: Self.noon, appearance: .darkAqua)
        #expect(isClose(noon, to: SunArcAppearance.dark.grounds.day), "noon dark pixel \(noon)")
        let night = try cornerPixel(date: Self.oneAM, appearance: .darkAqua)
        #expect(isClose(night, to: SunArcAppearance.dark.grounds.trueDark), "01:00 dark pixel \(night)")
    }

    @Test func flippingTheWindowsAppearanceRedrawsTheOtherGround() throws {
        // The production path: no SwiftUI override, one hosting view, its AppKit appearance
        // flipped the way a System Settings change flips a window's effective appearance.
        // 01:00 is uniform true dark, so the pixel is the ground exactly (spec § 12).
        let view = SunArcBackgroundView(fixedDate: Self.oneAM, timeZone: Self.denver)
            .frame(width: Self.size.width, height: Self.size.height)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Self.size)
        func sample() throws -> (r: Double, g: Double, b: Double) {
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
        }
        host.appearance = NSAppearance(named: .aqua)
        let light = try sample()
        #expect(isClose(light, to: SunArcAppearance.light.grounds.trueDark, within: 2), "light pixel \(light)")
        host.appearance = NSAppearance(named: .darkAqua)
        let dark = try sample()
        #expect(isClose(dark, to: SunArcAppearance.dark.grounds.trueDark, within: 2), "dark pixel \(dark)")
        host.appearance = NSAppearance(named: .aqua)
        let back = try sample()
        #expect(isClose(back, to: SunArcAppearance.light.grounds.trueDark, within: 2), "light again \(back)")
    }
}
