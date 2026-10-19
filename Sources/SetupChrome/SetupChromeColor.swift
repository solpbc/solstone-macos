// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public enum SetupChromeColor {
    public static let solOrange = parseHex("#E8913A")
    public static let gold = parseHex("#FFCC33")
    public static let primaryLabel = parseHex("#1A1A1A")

    public static func sheet(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#221C19") : parseHex("#FEFCF8")
    }

    public static func card(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#2B231C") : parseHex("#FFFFFF")
    }

    public static func footer(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#1C1714") : parseHex("#FCF3E4")
    }

    public static func ink(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#FCF3E4") : parseHex("#1A1A1A")
    }

    public static func softInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#D0C6B8") : parseHex("#5B5246")
    }

    public static func faintInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#B0A699") : parseHex("#6E6453")
    }

    public static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#484038") : parseHex("#ECE3D0")
    }

    public static func hairline2(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#514840") : parseHex("#E2D7BF")
    }

    public static func orangeText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#F2A451") : parseHex("#A15F17")
    }

    public static func orangeWash(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#493524") : parseHex("#FBEFDD")
    }

    public static func successDot(for scheme: ColorScheme) -> Color {
        parseHex("#3F9D6A")
    }

    public static func successInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? parseHex("#7AB58B") : parseHex("#166534")
    }

    public static func pausedDot(for scheme: ColorScheme) -> Color {
        parseHex("#C99A2E")
    }

    private static func parseHex(_ hex: String) -> Color {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let r, g, b: Double
        switch clean.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
