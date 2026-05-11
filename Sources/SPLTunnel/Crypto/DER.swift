// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum DER {
    static func length(_ count: Int) -> [UInt8] {
        precondition(count >= 0)
        if count < 0x80 {
            return [UInt8(count)]
        }

        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(tag: UInt8, value: [UInt8]) -> [UInt8] {
        [tag] + length(value.count) + value
    }

    static func sequence(_ elements: [[UInt8]]) -> [UInt8] {
        tlv(tag: 0x30, value: elements.flatMap { $0 })
    }

    static func set(_ elements: [[UInt8]]) -> [UInt8] {
        tlv(tag: 0x31, value: elements.flatMap { $0 })
    }

    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var value = bytes
        while value.count > 1, value.first == 0x00, let next = value.dropFirst().first, next & 0x80 == 0 {
            value.removeFirst()
        }

        if value.isEmpty {
            value = [0x00]
        } else if let first = value.first, first & 0x80 != 0 {
            value.insert(0x00, at: 0)
        }

        return tlv(tag: 0x02, value: value)
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(tag: 0x04, value: bytes)
    }

    static func bitString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(tag: 0x03, value: [0x00] + bytes)
    }

    static func utf8String(_ string: String) -> [UInt8] {
        tlv(tag: 0x0c, value: Array(string.utf8))
    }

    static func objectIdentifier(_ arcs: [UInt64]) -> [UInt8] {
        precondition(arcs.count >= 2)
        precondition(arcs[0] <= 2)
        precondition(arcs[0] == 2 || arcs[1] < 40)

        var bytes = [UInt8(40 * arcs[0] + arcs[1])]
        for arc in arcs.dropFirst(2) {
            bytes += base128(arc)
        }
        return tlv(tag: 0x06, value: bytes)
    }

    static func contextSpecific(tag: UInt8, value: [UInt8]) -> [UInt8] {
        tlv(tag: 0xa0 | (tag & 0x1f), value: value)
    }

    static func null() -> [UInt8] {
        [0x05, 0x00]
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var stack = [UInt8(value & 0x7f)]
        var remaining = value >> 7
        while remaining > 0 {
            stack.insert(UInt8(remaining & 0x7f) | 0x80, at: 0)
            remaining >>= 7
        }
        return stack
    }
}
