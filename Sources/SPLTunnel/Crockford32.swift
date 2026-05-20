// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum Crockford32 {
    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func decode(_ value: String) throws -> [UInt8] {
        var accumulator: UInt64 = 0
        var bitCount = 0
        var output: [UInt8] = []

        for character in value {
            guard let folded = foldedCharacter(character) else {
                continue
            }
            guard let index = alphabet.firstIndex(of: folded) else {
                throw PairURLError.Base32Reason.outOfAlphabet(character)
            }

            accumulator = (accumulator << 5) | UInt64(index)
            bitCount += 5

            while bitCount >= 8 {
                bitCount -= 8
                let byte = UInt8((accumulator >> UInt64(bitCount)) & 0xff)
                output.append(byte)
                accumulator &= (1 << UInt64(bitCount)) - 1
            }
        }

        if bitCount > 0, accumulator != 0 {
            throw PairURLError.Base32Reason.nonCanonicalPadBits
        }

        return output
    }

    private static func foldedCharacter(_ character: Character) -> Character? {
        if character == "-" || character.isWhitespace {
            return nil
        }

        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return Character(character.uppercased())
        }

        switch scalar.value {
        case 0x49, 0x69, 0x4c, 0x6c:
            return "1"
        case 0x4f, 0x6f:
            return "0"
        default:
            return Character(character.uppercased())
        }
    }
}
