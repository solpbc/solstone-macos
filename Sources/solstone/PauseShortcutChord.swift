// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Value type representing a keyboard shortcut chord using Carbon key code and modifier bits.
public struct PauseShortcutChord: Hashable, Sendable, Codable {
    // Carbon Events.h modifier bits
    public static let cmdKey: UInt32 = 1 << 8       // 256
    public static let shiftKey: UInt32 = 1 << 9     // 512
    public static let optionKey: UInt32 = 1 << 11   // 2048
    public static let controlKey: UInt32 = 1 << 12  // 4096

    public static let allowedModifiersMask = cmdKey | shiftKey | optionKey | controlKey

    public static let rejectedModifierKeyCodes: Set<UInt32> = [
        0x37, // command (55)
        0x38, // shift (56)
        0x39, // caps lock (57)
        0x3A, // option (58)
        0x3B, // control (59)
        0x36, // right command (54)
        0x3C, // right shift (60)
        0x3D, // right option (61)
        0x3E, // right control (62)
        0x3F  // function (63)
    ]

    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public init?(keyCode: UInt32, carbonModifiers: UInt32) {
        guard !Self.rejectedModifierKeyCodes.contains(keyCode) else { return nil }
        guard (carbonModifiers & ~Self.allowedModifiersMask) == 0 else { return nil }
        guard (carbonModifiers & (Self.cmdKey | Self.controlKey)) != 0 else { return nil }
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    public var serialized: String {
        "\(keyCode),\(carbonModifiers)"
    }

    public var encodedString: String {
        serialized
    }

    public static func decode(from string: String) -> PauseShortcutChord? {
        PauseShortcutChord(serialized: string)
    }

    public init?(serialized: String) {
        let parts = serialized.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let code = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: code, carbonModifiers: mods)
    }

    public var displayString: String {
        var result = ""
        if (carbonModifiers & Self.controlKey) != 0 { result += "⌃" }
        if (carbonModifiers & Self.optionKey) != 0 { result += "⌥" }
        if (carbonModifiers & Self.shiftKey) != 0 { result += "⇧" }
        if (carbonModifiers & Self.cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    public static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F10"
        case 111: return "F12"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }
}
