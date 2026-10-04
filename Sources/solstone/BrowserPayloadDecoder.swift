// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation

public enum BrowserDecodeStatus: String, Sendable, Equatable {
    case accept
    case refuse
    case unsupported
}

public struct BrowserRefusal: Sendable, Equatable {
    public let code: String
    public let field: String?
    public let cause: String?
    public let row: Int?

    public init(code: String, field: String? = nil, cause: String? = nil, row: Int? = nil) {
        self.code = code
        self.field = field
        self.cause = cause
        self.row = row
    }

    public var receiptReason: String {
        switch code {
        case "oversize":
            return "oversize"
        case "snapshot_required":
            return "snapshot_required"
        case "resource_exhausted":
            return "resource_exhausted"
        case "queue_full":
            return "queue_full"
        case "age_policy":
            return "age_policy"
        case "unaccepted_lost":
            return "unaccepted_lost"
        default:
            return "malformed"
        }
    }

    public var receiptClass: String {
        switch receiptReason {
        case "snapshot_required", "resource_exhausted", "queue_full", "age_policy":
            return "retryable"
        default:
            return "permanent"
        }
    }
}

public struct BrowserIntakeLocalRefusal: Error, Sendable, Equatable {
    public let code: String
    public let field: String?

    public init(code: String, field: String? = nil) {
        self.code = code
        self.field = field
    }
}

public struct BrowserHostToExtensionMessage: Sendable, Equatable {
    fileprivate let bytes: Data
}

public struct BrowserDecodedBatchRecord: Sendable, Equatable {
    public let rawSlice: Data
    public let t: String
    public let ts: UInt64
    public let ctx: String
    public let inst: String?
    public let op: String?
    public let blockId: String?
    public let snapshotReason: String?
}

public struct BrowserDecodedBatch: Sendable, Equatable {
    public let destinationGeneration: String
    public let inst: String
    public let batchId: String
    public let queuedAtMs: UInt64
    public let records: [BrowserDecodedBatchRecord]
}

public struct BrowserDecodedHello: Sendable, Equatable {
    public let protocolVersion: Int
    public let version: String
    public let brand: String
    public let inst: String
}

public struct BrowserDecodedState: Sendable, Equatable {
    public let type: String
    public let capture: String
    public let delivery: String
    public let freshnessMs: UInt64
    public let destinationGeneration: String?
    public let periodId: String?
    public let failure: String?
    public let custodyFull: Bool
    public let custodyStale: Bool
    public let version: String?
}

public struct BrowserDecodedAccepted: Sendable, Equatable {
    public let result: String
    public let destinationGeneration: String
    public let inst: String
    public let batchId: String
    public let periodId: String?
    public let reason: String?
    public let receiptClass: String?
}

public struct BrowserDecodedBoundary: Sendable, Equatable {
    public let destinationGeneration: String
    public let periodId: String
}

public struct BrowserDecodedBye: Sendable, Equatable {
    public let reason: String
}

public struct BrowserDecodedUnsupported: Sendable, Equatable {
    public let protocolVersion: Int
    public let behind: String
}

public enum BrowserDecodedMessage: Sendable, Equatable {
    case hello(BrowserDecodedHello)
    case batch(BrowserDecodedBatch)
    case state(BrowserDecodedState)
    case boundary(BrowserDecodedBoundary)
    case accepted(BrowserDecodedAccepted)
    case unsupported(BrowserDecodedUnsupported)
    case bye(BrowserDecodedBye)
}

public enum BrowserDecodeResult: Sendable, Equatable {
    case accept(BrowserDecodedMessage)
    case refuse(BrowserRefusal)
    case unsupported(protocol: Int, behind: String)
}

public enum BrowserPayloadDecoder {
    private static func exactUTF8(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    private static func parseHex4(_ bytes: Data, from start: Int) -> UInt16? {
        var val: UInt16 = 0
        for offset in 0..<4 {
            let b = bytes[bytes.startIndex + start + offset]
            let digit: UInt16
            if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") {
                digit = UInt16(b - UInt8(ascii: "0"))
            } else if b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f") {
                digit = UInt16(b - UInt8(ascii: "a") + 10)
            } else if b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F") {
                digit = UInt16(b - UInt8(ascii: "A") + 10)
            } else {
                return nil
            }
            val = (val << 4) | digit
        }
        return val
    }

    /// Scan JSON source for a lone `\u` surrogate. A preceding escaped backslash
    /// (`\\uD800`) is literal text and is not a surrogate escape.
    private static func hasLoneSurrogateEscape(_ utf8: Data) -> Bool {
        var i = 0
        let n = utf8.count
        while i < n {
            if utf8[utf8.startIndex + i] != UInt8(ascii: "\\") {
                i += 1
                continue
            }
            if i + 1 >= n { return true }
            let next = utf8[utf8.startIndex + i + 1]
            if next != UInt8(ascii: "u") {
                i += 2
                continue
            }
            if i + 5 >= n { return true }
            guard let hexVal = parseHex4(utf8, from: i + 2) else { return true }
            if (0xD800...0xDBFF).contains(hexVal) {
                if i + 11 < n && utf8[utf8.startIndex + i + 6] == UInt8(ascii: "\\") && utf8[utf8.startIndex + i + 7] == UInt8(ascii: "u") {
                    if let lowVal = parseHex4(utf8, from: i + 8), (0xDC00...0xDFFF).contains(lowVal) {
                        i += 12
                        continue
                    }
                }
                return true
            } else if (0xDC00...0xDFFF).contains(hexVal) {
                return true
            }
            i += 6
        }
        return false
    }

    private static func hasLoneSurrogates(_ string: String) -> Bool {
        let utf16 = string.utf16
        var i = utf16.startIndex
        while i < utf16.endIndex {
            let unit = utf16[i]
            if (0xD800...0xDBFF).contains(unit) {
                let next = utf16.index(after: i)
                if next < utf16.endIndex {
                    let nextUnit = utf16[next]
                    if (0xDC00...0xDFFF).contains(nextUnit) {
                        i = utf16.index(after: next)
                        continue
                    }
                }
                return true
            }
            if (0xDC00...0xDFFF).contains(unit) {
                return true
            }
            i = utf16.index(after: i)
        }
        return false
    }

    private static func exceedsJsonDepth(_ text: Data, maxDepth: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in text {
            let ch = UnicodeScalar(byte)
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" || ch == "[" {
                depth += 1
                if depth > maxDepth { return true }
            } else if ch == "}" || ch == "]" {
                depth -= 1
            }
        }
        return false
    }

    /// One walk of the root object. Record slices come from the root `records`
    /// array (last duplicate key wins, matching JSON object semantics), with
    /// insignificant whitespace removed and string/number lexemes preserved.
    private static func rootRecordSlices(in bytes: Data, maximumRecords: Int) -> [Data]? {
        var lexer = JSONLexer(bytes: bytes)
        return lexer.rootRecordSlices(maximumRecords: maximumRecords)
    }

    private struct JSONLexer {
        let bytes: Data
        var index: Int = 0

        mutating func rootRecordSlices(maximumRecords: Int) -> [Data]? {
            skipWhitespace()
            guard peek() == UInt8(ascii: "{") else { return nil }
            index += 1
            var ranges: [Range<Int>]?
            while index < bytes.count {
                skipWhitespace()
                guard let rawKey = rawString(), let key = jsonStringValue(rawKey) else { return nil }
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else { return nil }
                index += 1
                skipWhitespace()
                if key == "records", peek() == UInt8(ascii: "[") {
                    index += 1
                    var next: [Range<Int>] = []
                    var tooMany = false
                    skipWhitespace()
                    while peek() != UInt8(ascii: "]") {
                        guard let range = skipRawValue() else { return nil }
                        if next.count < maximumRecords { next.append(range) } else { tooMany = true }
                        skipWhitespace()
                        if peek() == UInt8(ascii: ",") { index += 1; skipWhitespace() }
                        else if peek() != UInt8(ascii: "]") { return nil }
                    }
                    index += 1
                    ranges = tooMany ? nil : next
                } else {
                    guard skipRawValue() != nil else { return nil }
                    if key == "records" { ranges = nil }
                }
                skipWhitespace()
                if peek() == UInt8(ascii: ",") { index += 1; continue }
                guard peek() == UInt8(ascii: "}") else { return nil }
                return ranges?.map { compactSlice($0) }
            }
            return nil
        }

        // Input was already parsed and validated. Traverse source ranges without
        // recursive temporary buffers or materializing unrelated root values.
        private mutating func skipRawValue() -> Range<Int>? {
            skipWhitespace()
            let start = index
            var depth = 0
            var quoted = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[bytes.startIndex + index]
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                } else {
                    if byte == 34 { quoted = true }
                    else if byte == 123 || byte == 91 { depth += 1 }
                    else if byte == 125 || byte == 93 {
                        if depth == 0 { break }
                        depth -= 1
                    } else if byte == 44 && depth == 0 { break }
                }
                index += 1
            }
            return index > start && !quoted && depth == 0 ? start..<index : nil
        }

        private func compactSlice(_ range: Range<Int>) -> Data {
            var result = Data()
            result.reserveCapacity(range.count)
            var quoted = false
            var escaped = false
            for index in range {
                let byte = bytes[bytes.startIndex + index]
                if quoted {
                    result.append(byte)
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                } else if byte == 34 {
                    quoted = true; result.append(byte)
                } else if byte != 32 && byte != 9 && byte != 10 && byte != 13 { result.append(byte) }
            }
            return result
        }

        mutating func rootObjectLastWins() -> [String: Any]? {
            skipWhitespace()
            guard peek() == UInt8(ascii: "{") else { return nil }
            index += 1
            skipWhitespace()
            var object: [String: Any] = [:]
            if peek() == UInt8(ascii: "}") {
                index += 1
                skipWhitespace()
                return index == bytes.count ? object : nil
            }
            while index < bytes.count {
                guard let rawKey = rawString(), let key = jsonStringValue(rawKey) else { return nil }
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = jsonValue() else { return nil }
                object[key] = value
                skipWhitespace()
                if peek() == UInt8(ascii: ",") {
                    index += 1
                    skipWhitespace()
                    continue
                }
                guard peek() == UInt8(ascii: "}") else { return nil }
                index += 1
                skipWhitespace()
                return index == bytes.count ? object : nil
            }
            return nil
        }

        private mutating func jsonValue() -> Any? {
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: "{"):
                return jsonObject()
            case UInt8(ascii: "["):
                return jsonArray()
            case UInt8(ascii: "\""):
                guard let raw = rawString() else { return nil }
                return jsonStringValue(raw)
            default:
                guard let raw = compactValue() else { return nil }
                return try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
            }
        }

        private mutating func jsonObject() -> [String: Any]? {
            guard peek() == UInt8(ascii: "{") else { return nil }
            index += 1
            skipWhitespace()
            var object: [String: Any] = [:]
            if peek() == UInt8(ascii: "}") {
                index += 1
                return object
            }
            while index < bytes.count {
                guard let rawKey = rawString(), let key = jsonStringValue(rawKey) else { return nil }
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = jsonValue() else { return nil }
                object[key] = value
                skipWhitespace()
                if peek() == UInt8(ascii: ",") {
                    index += 1
                    skipWhitespace()
                    continue
                }
                guard peek() == UInt8(ascii: "}") else { return nil }
                index += 1
                return object
            }
            return nil
        }

        private mutating func jsonArray() -> [Any]? {
            guard peek() == UInt8(ascii: "[") else { return nil }
            index += 1
            skipWhitespace()
            var values: [Any] = []
            if peek() == UInt8(ascii: "]") {
                index += 1
                return values
            }
            while index < bytes.count {
                guard let value = jsonValue() else { return nil }
                values.append(value)
                skipWhitespace()
                if peek() == UInt8(ascii: ",") {
                    index += 1
                    skipWhitespace()
                    continue
                }
                guard peek() == UInt8(ascii: "]") else { return nil }
                index += 1
                return values
            }
            return nil
        }

        private mutating func compactValue() -> Data? {
            skipWhitespace()
            guard let byte = peek() else { return nil }
            switch byte {
            case UInt8(ascii: "\""): return rawString()
            case UInt8(ascii: "t"): return rawLiteral("true")
            case UInt8(ascii: "f"): return rawLiteral("false")
            case UInt8(ascii: "n"): return rawLiteral("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return rawNumber()
            default: return nil
            }
        }

        private mutating func rawString() -> Data? {
            guard peek() == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[bytes.startIndex + index]
                if byte == UInt8(ascii: "\\") {
                    index += 2
                    if index > bytes.count { return nil }
                } else if byte == UInt8(ascii: "\"") {
                    index += 1
                    return Data(bytes[(bytes.startIndex + start)..<(bytes.startIndex + index)])
                } else {
                    index += 1
                }
            }
            return nil
        }

        private mutating func rawLiteral(_ literal: String) -> Data? {
            let raw = Data(literal.utf8)
            guard index + raw.count <= bytes.count else { return nil }
            guard bytes[(bytes.startIndex + index)..<(bytes.startIndex + index + raw.count)] == raw else { return nil }
            index += raw.count
            return raw
        }

        private mutating func rawNumber() -> Data? {
            let start = index
            if peek() == UInt8(ascii: "-") { index += 1 }
            let numberStart = index
            while index < bytes.count {
                let byte = bytes[bytes.startIndex + index]
                let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
                if isDigit || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") {
                    index += 1
                } else {
                    break
                }
            }
            if index == numberStart { return nil }
            return Data(bytes[(bytes.startIndex + start)..<(bytes.startIndex + index)])
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                let byte = bytes[bytes.startIndex + index]
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                    index += 1
                } else {
                    break
                }
            }
        }

        private func peek() -> UInt8? {
            index < bytes.count ? bytes[bytes.startIndex + index] : nil
        }

        private func jsonStringValue(_ raw: Data) -> String? {
            (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) as? String
        }
    }

    /// Syntax-only bounded scan used before generic container materialization.
    /// Only the tiny final root type value is decoded; duplicate and escaped keys
    /// retain the parser's last-key-wins semantics.
    private struct ControlTypeScanner {
        let bytes: Data
        let maximumDepth: Int
        var index = 0
        var rootType: String?
        private func byte(_ offset: Int) -> UInt8? {
            offset < bytes.count ? bytes[bytes.startIndex + offset] : nil
        }
        private mutating func whitespace() {
            while let b = byte(index), b == 32 || b == 9 || b == 10 || b == 13 { index += 1 }
        }
        mutating func scan() -> Bool {
            whitespace()
            guard byte(index) == 123, object(depth: 1, isRoot: true) else { return false }
            whitespace()
            return index == bytes.count
        }
        private mutating func value(depth: Int) -> Bool {
            // The depth limit counts containers, not scalar leaves.
            whitespace()
            switch byte(index) {
            case 123: return object(depth: depth, isRoot: false)
            case 91: return array(depth: depth)
            case 34: return string() != nil
            case 116: return literal([116, 114, 117, 101])
            case 102: return literal([102, 97, 108, 115, 101])
            case 110: return literal([110, 117, 108, 108])
            default: return number()
            }
        }
        private mutating func object(depth: Int, isRoot: Bool) -> Bool {
            guard depth <= maximumDepth, byte(index) == 123 else { return false }
            index += 1; whitespace()
            if byte(index) == 125 { index += 1; return true }
            while index < bytes.count {
                guard let keyRange = string() else { return false }
                var isType = false
                if isRoot, keyRange.count <= 64 {
                    let raw = Data(bytes[(bytes.startIndex + keyRange.lowerBound)..<(bytes.startIndex + keyRange.upperBound)])
                    isType = (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String) == "type"
                }
                whitespace()
                guard byte(index) == 58 else { return false }
                index += 1; whitespace()
                let start = index
                guard value(depth: depth + 1) else { return false }
                if isType {
                    rootType = nil
                    if index - start <= 64, byte(start) == 34 {
                        let raw = Data(bytes[(bytes.startIndex + start)..<(bytes.startIndex + index)])
                        rootType = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String
                    }
                }
                whitespace()
                if byte(index) == 125 { index += 1; return true }
                guard byte(index) == 44 else { return false }
                index += 1; whitespace()
            }
            return false
        }
        private mutating func array(depth: Int) -> Bool {
            guard depth <= maximumDepth, byte(index) == 91 else { return false }
            index += 1; whitespace()
            if byte(index) == 93 { index += 1; return true }
            while index < bytes.count {
                guard value(depth: depth + 1) else { return false }
                whitespace()
                if byte(index) == 93 { index += 1; return true }
                guard byte(index) == 44 else { return false }
                index += 1; whitespace()
            }
            return false
        }
        private mutating func string() -> Range<Int>? {
            guard byte(index) == 34 else { return nil }
            let start = index; index += 1
            while let b = byte(index) {
                index += 1
                if b == 34 { return start..<index }
                if b < 32 { return nil }
                if b == 92 {
                    guard let escape = byte(index) else { return nil }
                    index += 1
                    if escape == 117 {
                        for _ in 0..<4 {
                            guard let h = byte(index), (48...57).contains(h) || (65...70).contains(h) || (97...102).contains(h) else { return nil }
                            index += 1
                        }
                    } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escape) { return nil }
                }
            }
            return nil
        }
        private mutating func literal(_ expected: [UInt8]) -> Bool {
            for b in expected { guard byte(index) == b else { return false }; index += 1 }
            return true
        }
        private func digit(_ b: UInt8?) -> Bool { b.map { (48...57).contains($0) } ?? false }
        private mutating func number() -> Bool {
            if byte(index) == 45 { index += 1 }
            if byte(index) == 48 { index += 1 }
            else {
                guard let b = byte(index), (49...57).contains(b) else { return false }
                repeat { index += 1 } while digit(byte(index))
            }
            if byte(index) == 46 {
                index += 1; guard digit(byte(index)) else { return false }
                repeat { index += 1 } while digit(byte(index))
            }
            if byte(index) == 101 || byte(index) == 69 {
                index += 1
                if byte(index) == 43 || byte(index) == 45 { index += 1 }
                guard digit(byte(index)) else { return false }
                repeat { index += 1 } while digit(byte(index))
            }
            return true
        }
    }

    /// Accounted input representations are bounded separately from process RSS.
    /// Two body-sized working allowances cover materialized strings / scalar
    /// scratch; after parsing they cover record slices plus the commit bundle.
    /// Each lexical node and slot has a charge;
    /// dense malformed input is refused before building Foundation containers.
    public static func decode(
        bytes: Data, direction: String, projection: BrowserContractProjection,
        reserveWorkingMemory: (Int) -> Bool = { _ in true }
    ) -> BrowserDecodeResult {
        let cap = direction == "host_to_extension" ? projection.caps.control : projection.caps.extensionToHost
        guard bytes.count <= cap else { return .refuse(BrowserRefusal(code: "oversize")) }
        guard direction == "extension_to_host" || direction == "host_to_extension" else {
            return .refuse(BrowserRefusal(code: "bad_direction"))
        }
        guard NativeHostUTF8.isValid(bytes) else { return .refuse(BrowserRefusal(code: "bad_utf8")) }
        var charged = bytes.count * 2
        var quoted = false, escaped = false, literal = false
        for byte in bytes {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            switch byte {
            case 34: charged += 256; quoted = true; literal = false
            case 123, 91: charged += 256; literal = false
            case 44, 58: charged += 128; literal = false
            case 125, 93, 32, 9, 10, 13: literal = false
            default: if !literal { charged += 128; literal = true }
            }
            guard charged <= 128 * 1024 * 1024 - bytes.count else {
                return .refuse(BrowserRefusal(code: "resource_exhausted"))
            }
        }
        if bytes.count > projection.caps.control {
            var scanner = ControlTypeScanner(bytes: bytes, maximumDepth: projection.caps.jsonMaxDepth)
            if scanner.scan(), let type = scanner.rootType, type != "batch" {
                return .refuse(BrowserRefusal(code: "oversize"))
            }
        }
        guard reserveWorkingMemory(charged) else { return .refuse(BrowserRefusal(code: "resource_exhausted")) }
        let metadata = decodeMetadata(bytes: bytes, direction: direction, projection: projection)
        guard case .accept(.batch(let batch)) = metadata else { return metadata }
        guard let slices = rootRecordSlices(in: bytes, maximumRecords: projection.caps.deltaRecords), slices.count == batch.records.count else {
            return .refuse(BrowserRefusal(code: "bad_json"))
        }
        let records = zip(batch.records, slices).map { record, slice in
            BrowserDecodedBatchRecord(rawSlice: slice, t: record.t, ts: record.ts, ctx: record.ctx,
                inst: record.inst, op: record.op, blockId: record.blockId, snapshotReason: record.snapshotReason)
        }
        return .accept(.batch(BrowserDecodedBatch(destinationGeneration: batch.destinationGeneration,
            inst: batch.inst, batchId: batch.batchId, queuedAtMs: batch.queuedAtMs, records: records)))
    }

    private static func decodeMetadata(
        bytes: Data,
        direction: String,
        projection: BrowserContractProjection
    ) -> BrowserDecodeResult {
        if direction != "extension_to_host" && direction != "host_to_extension" {
            return .refuse(BrowserRefusal(code: "bad_direction"))
        }

        let maxCap = direction == "host_to_extension" ? projection.caps.control : projection.caps.extensionToHost
        if bytes.count > maxCap {
            return .refuse(BrowserRefusal(code: "oversize"))
        }

        guard NativeHostUTF8.isValid(bytes) else {
            return .refuse(BrowserRefusal(code: "bad_utf8"))
        }

        if bytes.isEmpty || bytes.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }) {
            return .refuse(BrowserRefusal(code: "empty_payload"))
        }

        if hasLoneSurrogateEscape(bytes) {
            return .refuse(BrowserRefusal(code: "lone_surrogate"))
        }

        if exceedsJsonDepth(bytes, maxDepth: projection.caps.jsonMaxDepth) {
            return .refuse(BrowserRefusal(code: "bad_json"))
        }

        var rootLexer = JSONLexer(bytes: bytes)
        guard let root = rootLexer.rootObjectLastWins() else {
            return .refuse(BrowserRefusal(code: "bad_json"))
        }

        // Check for lone surrogates in JSON tree
        func checkSurrogates(_ val: Any) -> Bool {
            if let s = val as? String {
                return hasLoneSurrogates(s)
            } else if let arr = val as? [Any] {
                for item in arr { if checkSurrogates(item) { return true } }
            } else if let dict = val as? [String: Any] {
                for (k, v) in dict {
                    if hasLoneSurrogates(k) || checkSurrogates(v) { return true }
                }
            }
            return false
        }
        if checkSurrogates(root) {
            return .refuse(BrowserRefusal(code: "lone_surrogate"))
        }

        guard let type = root["type"] as? String else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }

        let knownTypes = ["hello", "batch", "hello_ack", "unsupported", "state", "boundary", "accepted", "bye"]
        if !knownTypes.contains(type) {
            return .refuse(BrowserRefusal(code: "bad_type"))
        }

        let extToHostTypes = ["hello", "batch"]
        let hostToExtTypes = ["hello_ack", "unsupported", "state", "boundary", "accepted", "bye"]
        let allowedTypes = direction == "extension_to_host" ? extToHostTypes : hostToExtTypes
        if !allowedTypes.contains(type) {
            return .refuse(BrowserRefusal(code: "bad_direction"))
        }

        if type != "batch" && bytes.count > projection.caps.control {
            return .refuse(BrowserRefusal(code: "oversize"))
        }

        switch type {
        case "hello":
            return decodeHello(root: root, projection: projection)
        case "batch":
            return decodeBatch(root: root, rawBytes: bytes, projection: projection)
        case "state", "hello_ack":
            return decodeState(root: root, type: type, projection: projection)
        case "boundary":
            return decodeBoundary(root: root, projection: projection)
        case "accepted":
            return decodeAccepted(root: root, projection: projection)
        case "unsupported":
            return decodeUnsupported(root: root, projection: projection)
        case "bye":
            return decodeBye(root: root, projection: projection)
        default:
            return .refuse(BrowserRefusal(code: "bad_type"))
        }
    }

    private static func isBoolean(_ val: Any?) -> Bool {
        guard let num = val as? NSNumber else { return false }
        return CFGetTypeID(num) == CFBooleanGetTypeID()
    }

    private static let maxSafeInteger: Double = 9007199254740991

    private static func scalarCount(_ string: String) -> Int {
        string.unicodeScalars.count
    }

    /// Integral JSON numbers, including `1.0` and `1e3`. Values above the
    /// IEEE safe-integer maximum are refused even when they parse as integers.
    private static func isNonNegativeInteger(_ val: Any?, max: UInt64? = nil) -> Bool {
        guard let num = val as? NSNumber else { return false }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return false }
        let value = num.doubleValue
        if !value.isFinite || value < 0 || value != value.rounded(.towardZero) { return false }
        if value > maxSafeInteger { return false }
        if let max, value > Double(max) { return false }
        return true
    }

    private static func optionalRecordString(
        _ record: [String: Any],
        key: String,
        max: Int,
        row: Int
    ) -> BrowserDecodeResult? {
        guard let value = record[key] else { return nil }
        guard let string = value as? String else {
            return .refuse(BrowserRefusal(code: "bad_record", field: key, row: row))
        }
        if scalarCount(string) > max {
            return .refuse(BrowserRefusal(code: "bad_record", field: key, cause: "too_long", row: row))
        }
        return nil
    }

    private static func decodeHello(root: [String: Any], projection: BrowserContractProjection) -> BrowserDecodeResult {
        guard let version = root["version"] as? String,
              let brand = root["brand"] as? String,
              let inst = root["inst"] as? String else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }

        guard let protocolRaw = root["protocol"] else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }

        guard isNonNegativeInteger(protocolRaw) else {
            return .refuse(BrowserRefusal(code: "bad_number"))
        }
        let protocolVal = (protocolRaw as! NSNumber).intValue

        if !["chrome", "edge", "firefox"].contains(brand) {
            return .refuse(BrowserRefusal(code: "invalid_enum"))
        }
        if scalarCount(version) > projection.stringBounds.version || inst.isEmpty || scalarCount(inst) > projection.stringBounds.instStringMax {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }

        if protocolVal != projection.wireProtocol {
            let behind = protocolVal > projection.wireProtocol ? "app" : "extension"
            return .unsupported(protocol: protocolVal, behind: behind)
        }

        return .accept(.hello(BrowserDecodedHello(
            protocolVersion: protocolVal,
            version: version,
            brand: brand,
            inst: inst
        )))
    }

    private static func decodeState(root: [String: Any], type: String, projection: BrowserContractProjection) -> BrowserDecodeResult {
        guard let capture = root["capture"] as? String,
              let delivery = root["delivery"] as? String else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }

        guard let freshnessRaw = root["freshness_ms"] else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }
        guard isNonNegativeInteger(freshnessRaw, max: projection.policy.freshnessMaxMs) else {
            return .refuse(BrowserRefusal(code: "freshness_range"))
        }
        let freshnessMs = (freshnessRaw as! NSNumber).uint64Value

        let validCaptures = ["unavailable", "not_paired", "permitted", "paused", "intake_off"]
        if !validCaptures.contains(capture) {
            return .refuse(BrowserRefusal(code: "invalid_enum"))
        }

        let validDeliveries = ["unknown", "kept_locally", "delivered", "idle", "failed"]
        if !validDeliveries.contains(delivery) {
            return .refuse(BrowserRefusal(code: "invalid_enum"))
        }

        if delivery == "failed" {
            guard let failure = root["failure"] as? String, !failure.isEmpty else {
                return .refuse(BrowserRefusal(code: "missing_field", field: "failure"))
            }
            if scalarCount(failure) > projection.stringBounds.failureCode {
                return .refuse(BrowserRefusal(code: "invalid_enum", field: "failure"))
            }
        }

        if let failureVal = root["failure"] {
            guard let f = failureVal as? String else {
                return .refuse(BrowserRefusal(code: "invalid_enum"))
            }
            let validFailures = ["relay_unavailable", "journal_rejected", "local_io", "resource_exhausted", "queue_full", "age_policy", "unaccepted_lost"]
            if !validFailures.contains(f) {
                return .refuse(BrowserRefusal(code: "invalid_enum"))
            }
        }

        let genVal = root["destination_generation"]
        let periodVal = root["period_id"]

        let genStr: String? = {
            if let s = genVal as? String { return s }
            return nil
        }()
        let periodStr: String? = {
            if let s = periodVal as? String { return s }
            return nil
        }()

        let hasGen = genStr != nil && !genStr!.isEmpty
        let hasPeriod = periodStr != nil && !periodStr!.isEmpty

        if let genVal, !(genVal is NSNull), !(genVal is String) {
            return .refuse(BrowserRefusal(code: "bad_state_ids"))
        }
        if let periodVal, !(periodVal is NSNull), !(periodVal is String) {
            return .refuse(BrowserRefusal(code: "bad_state_ids"))
        }

        switch capture {
        case "unavailable", "not_paired":
            if (genVal != nil && !(genVal is NSNull)) || (periodVal != nil && !(periodVal is NSNull)) {
                return .refuse(BrowserRefusal(code: "bad_state_ids"))
            }
        case "permitted":
            if !hasGen || !hasPeriod {
                return .refuse(BrowserRefusal(code: "bad_state_ids"))
            }
        case "paused", "intake_off":
            if !hasGen || (periodVal != nil && !(periodVal is NSNull) && !hasPeriod) {
                return .refuse(BrowserRefusal(code: "bad_state_ids"))
            }
        default:
            return .refuse(BrowserRefusal(code: "bad_state_ids"))
        }

        var fullBool = false
        var staleBool = false
        if root.keys.contains("custody") {
            guard let custody = root["custody"] as? [String: Any],
                  isBoolean(custody["full"]),
                  isBoolean(custody["stale"]) else {
                return .refuse(BrowserRefusal(code: "missing_field"))
            }
            fullBool = (custody["full"] as! NSNumber).boolValue
            staleBool = (custody["stale"] as! NSNumber).boolValue
        }

        let failureCode = (root["failure"] as? String)
        if let version = root["version"] {
            guard let versionString = version as? String, scalarCount(versionString) <= projection.stringBounds.version else {
                return .refuse(BrowserRefusal(code: "missing_field", field: "version"))
            }
        }
        if let generation = genStr, generation.isEmpty || scalarCount(generation) > projection.stringBounds.generation {
            return .refuse(BrowserRefusal(code: "bad_state_ids"))
        }
        if let period = periodStr, period.isEmpty || scalarCount(period) > projection.stringBounds.periodId {
            return .refuse(BrowserRefusal(code: "bad_state_ids"))
        }
        let version = root["version"] as? String

        return .accept(.state(BrowserDecodedState(
            type: type,
            capture: capture,
            delivery: delivery,
            freshnessMs: freshnessMs,
            destinationGeneration: genStr,
            periodId: periodStr,
            failure: failureCode,
            custodyFull: fullBool,
            custodyStale: staleBool,
            version: version
        )))
    }

    private static func decodeBoundary(root: [String: Any], projection: BrowserContractProjection) -> BrowserDecodeResult {
        guard let gen = root["destination_generation"] as? String,
              let period = root["period_id"] as? String else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }
        if gen.isEmpty || scalarCount(gen) > projection.stringBounds.generation ||
           period.isEmpty || scalarCount(period) > projection.stringBounds.periodId {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }
        return .accept(.boundary(BrowserDecodedBoundary(destinationGeneration: gen, periodId: period)))
    }

    private static func decodeAccepted(root: [String: Any], projection: BrowserContractProjection) -> BrowserDecodeResult {
        guard let result = root["result"] as? String,
              let gen = root["destination_generation"] as? String,
              let inst = root["inst"] as? String,
              let batchId = root["batch_id"] as? String else {
            return .refuse(BrowserRefusal(code: "invalid_receipt"))
        }

        if !["accepted", "duplicate", "rejected"].contains(result) {
            return .refuse(BrowserRefusal(code: "invalid_receipt"))
        }

        if gen.isEmpty || scalarCount(gen) > projection.stringBounds.generation ||
            inst.isEmpty || scalarCount(inst) > projection.stringBounds.instStringMax {
            return .refuse(BrowserRefusal(code: "invalid_receipt"))
        }

        if batchId.count != projection.caps.batchIdHex ||
           batchId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) == nil {
            return .refuse(BrowserRefusal(code: "invalid_receipt"))
        }

        let periodPresent = root.keys.contains("period_id")
        let reasonPresent = root.keys.contains("reason")
        let classPresent = root.keys.contains("class")
        let periodId: String? = periodPresent ? root["period_id"] as? String : nil
        let reason: String? = reasonPresent ? root["reason"] as? String : nil
        let receiptClass: String? = classPresent ? root["class"] as? String : nil

        if result == "accepted" || result == "duplicate" {
            guard periodPresent, let period = periodId,
                  !period.isEmpty,
                  scalarCount(period) <= projection.stringBounds.periodId,
                  !reasonPresent,
                  !classPresent else {
                return .refuse(BrowserRefusal(code: "invalid_receipt"))
            }
            return .accept(.accepted(BrowserDecodedAccepted(
                result: result,
                destinationGeneration: gen,
                inst: inst,
                batchId: batchId,
                periodId: period,
                reason: nil,
                receiptClass: nil
            )))
        } else {
            guard !periodPresent, reasonPresent, classPresent,
                  let r = reason, let c = receiptClass else {
                return .refuse(BrowserRefusal(code: "invalid_receipt"))
            }
            let currentReason = projection.receiptClasses[c]?.contains(r) == true
            let legacyReason = c == "permanent" && projection.legacyPermanentReasons.contains(r)
            guard currentReason || legacyReason else {
                return .refuse(BrowserRefusal(code: "invalid_receipt"))
            }
            return .accept(.accepted(BrowserDecodedAccepted(
                result: result,
                destinationGeneration: gen,
                inst: inst,
                batchId: batchId,
                periodId: nil,
                reason: r,
                receiptClass: c
            )))
        }
    }

    private static func decodeUnsupported(root: [String: Any], projection: BrowserContractProjection) -> BrowserDecodeResult {
        guard let behind = root["behind"] as? String,
              let protoNum = root["protocol"] as? NSNumber,
              isNonNegativeInteger(protoNum) else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }
        if !["app", "extension"].contains(behind) {
            return .refuse(BrowserRefusal(code: "invalid_enum"))
        }
        if let version = root["version"] {
            guard let value = version as? String, scalarCount(value) <= projection.stringBounds.version else {
                return .refuse(BrowserRefusal(code: "missing_field"))
            }
        }
        return .accept(.unsupported(BrowserDecodedUnsupported(protocolVersion: protoNum.intValue, behind: behind)))
    }

    private static func decodeBye(root: [String: Any], projection: BrowserContractProjection) -> BrowserDecodeResult {
        guard let reason = root["reason"] as? String else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }
        if !["shutdown", "replaced", "update"].contains(reason) {
            return .refuse(BrowserRefusal(code: "invalid_enum"))
        }
        return .accept(.bye(BrowserDecodedBye(reason: reason)))
    }

    private static func decodeBatch(
        root: [String: Any],
        rawBytes: Data,
        projection: BrowserContractProjection
    ) -> BrowserDecodeResult {
        guard let gen = root["destination_generation"] as? String,
              let inst = root["inst"] as? String,
              let batchId = root["batch_id"] as? String,
              let queuedAtRaw = root["queued_at_ms"] else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }

        if gen.isEmpty || scalarCount(gen) > projection.stringBounds.generation ||
            inst.isEmpty || scalarCount(inst) > projection.stringBounds.instStringMax {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }

        if scalarCount(batchId) != projection.caps.batchIdHex ||
           batchId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) == nil {
            return .refuse(BrowserRefusal(code: "bad_batch_id"))
        }

        guard isNonNegativeInteger(queuedAtRaw, max: projection.policy.timestampMax) else {
            return .refuse(BrowserRefusal(code: "bad_number"))
        }
        let queuedAtMs = (queuedAtRaw as! NSNumber).uint64Value

        guard let recordsValue = root["records"] as? [Any] else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }
        guard let recordsArray = recordsValue as? [[String: Any]] else {
            return .refuse(BrowserRefusal(code: "bad_record"))
        }

        if recordsArray.isEmpty {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }
        if recordsArray.count > projection.caps.deltaRecords {
            return .refuse(BrowserRefusal(code: "too_many_deltas"))
        }

        let firstRec = recordsArray[0]
        guard let firstT = firstRec["t"] as? String else {
            return .refuse(BrowserRefusal(code: "bad_record"))
        }
        let isSnapshot = (firstT == "segment_start")
        if isSnapshot && recordsArray.count != 1 {
            return .refuse(BrowserRefusal(code: "bad_record"))
        }

        guard let firstCtx = firstRec["ctx"] as? String, !firstCtx.isEmpty, scalarCount(firstCtx) <= projection.stringBounds.ctxStringMax else {
            let cause = firstRec["ctx"] == nil ? "missing" : (scalarCount(firstRec["ctx"] as? String ?? "") > projection.stringBounds.ctxStringMax ? "too_long" : "empty")
            return .refuse(BrowserRefusal(code: "bad_record", field: "ctx", cause: cause, row: 0))
        }

        var decodedRecords: [BrowserDecodedBatchRecord] = []

        for row in 0..<recordsArray.count {
            let rec = recordsArray[row]
            guard let recT = rec["t"] as? String else {
                return .refuse(BrowserRefusal(code: "bad_record", row: row))
            }
            if recT != (isSnapshot ? "segment_start" : "delta") {
                return .refuse(BrowserRefusal(code: "bad_record", row: row))
            }

            guard let recCtx = rec["ctx"] as? String, !recCtx.isEmpty, scalarCount(recCtx) <= projection.stringBounds.ctxStringMax else {
                let cause = rec["ctx"] == nil ? "missing" : "too_long"
                return .refuse(BrowserRefusal(code: "bad_record", field: "ctx", cause: cause, row: row))
            }
            if !exactUTF8(recCtx, firstCtx) {
                return .refuse(BrowserRefusal(code: "mixed_context"))
            }

            if let recInst = rec["inst"] {
                guard let instString = recInst as? String, exactUTF8(instString, inst), scalarCount(instString) <= projection.stringBounds.instStringMax else {
                    return .refuse(BrowserRefusal(code: "bad_record", field: "inst", cause: "mismatch", row: row))
                }
            }

            if let snapReason = rec["snapshot_reason"] {
                guard let reason = snapReason as? String, reason == "delivery_recovery" else {
                    return .refuse(BrowserRefusal(code: "invalid_enum"))
                }
            }

            for key in ["title", "url", "site", "adapter"] {
                let max: Int
                switch key {
                case "title": max = projection.stringBounds.titleStringMax
                case "url": max = projection.stringBounds.urlStringMax
                case "site": max = projection.stringBounds.siteStringMax
                default: max = projection.stringBounds.adapterStringMax
                }
                if let refusal = optionalRecordString(rec, key: key, max: max, row: row) {
                    return refusal
                }
            }

            if let rel = rec["rel"] {
                guard let number = rel as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                    return .refuse(BrowserRefusal(code: "bad_number", row: row))
                }
            }

            if isSnapshot, let nValue = rec["n"] {
                guard isNonNegativeInteger(nValue, max: UInt64(projection.stringBounds.blocksMax)) else {
                    return .refuse(BrowserRefusal(code: "bad_number", field: "n", row: row))
                }
            }

            guard let tsRaw = rec["ts"], isNonNegativeInteger(tsRaw, max: projection.policy.timestampMax) else {
                return .refuse(BrowserRefusal(code: "bad_number"))
            }
            let tsVal = (tsRaw as! NSNumber).uint64Value

            let opVal = rec["op"] as? String
            var blockIdVal: String? = nil

            if isSnapshot {
                guard let blocks = rec["blocks"] as? [[String: Any]] else {
                    return .refuse(BrowserRefusal(code: "bad_record", row: row))
                }
                if blocks.count > projection.stringBounds.blocksMax {
                    return .refuse(BrowserRefusal(code: "bad_record", row: row))
                }
                for block in blocks {
                    if let refusal = validateTextBlock(block, requireText: true, projection: projection, row: row) {
                        return refusal
                    }
                }
            } else {
                guard let op = opVal, ["add", "update", "remove"].contains(op) else {
                    return .refuse(BrowserRefusal(code: "bad_record", row: row))
                }
                guard let block = rec["block"] as? [String: Any] else {
                    return .refuse(BrowserRefusal(code: "bad_record", row: row))
                }
                if let refusal = validateTextBlock(block, requireText: op != "remove", projection: projection, row: row) {
                    return refusal
                }
                blockIdVal = block["id"] as? String
            }

            decodedRecords.append(BrowserDecodedBatchRecord(
                rawSlice: Data(),
                t: recT,
                ts: tsVal,
                ctx: recCtx,
                inst: rec["inst"] as? String,
                op: opVal,
                blockId: blockIdVal,
                snapshotReason: rec["snapshot_reason"] as? String
            ))
        }

        return .accept(.batch(BrowserDecodedBatch(
            destinationGeneration: gen,
            inst: inst,
            batchId: batchId,
            queuedAtMs: queuedAtMs,
            records: decodedRecords
        )))
    }

    private static func validateTextBlock(
        _ block: [String: Any],
        requireText: Bool,
        projection: BrowserContractProjection,
        row: Int
    ) -> BrowserDecodeResult? {
        if let idValue = block["id"] {
            guard let id = idValue as? String, !id.isEmpty else {
                return .refuse(BrowserRefusal(code: "bad_record", field: "id", cause: "empty", row: row))
            }
            if scalarCount(id) > projection.stringBounds.idStringMax {
                return .refuse(BrowserRefusal(code: "bad_record", field: "id", cause: "too_long", row: row))
            }
        } else {
            return .refuse(BrowserRefusal(code: "bad_record", field: "id", cause: "missing", row: row))
        }

        if requireText || block["text"] != nil {
            guard let text = block["text"] as? String else {
                let cause = block.keys.contains("text") ? "invalid" : "missing"
                return .refuse(BrowserRefusal(code: "bad_record", field: "text", cause: cause, row: row))
            }
            if scalarCount(text) > projection.stringBounds.textMax {
                return .refuse(BrowserRefusal(code: "bad_record", field: "text", cause: "too_long", row: row))
            }
        }

        if let typeValue = block["type"] {
            guard let type = typeValue as? String, scalarCount(type) <= projection.stringBounds.typeStringMax else {
                return .refuse(BrowserRefusal(code: "bad_record", field: "type", row: row))
            }
        }
        if let depth = block["depth"] {
            guard isNonNegativeInteger(depth, max: UInt64(projection.stringBounds.blockDepthMax)) else {
                return .refuse(BrowserRefusal(code: "bad_record", field: "depth", row: row))
            }
        }
        if let attrs = block["attrs"] {
            guard let dict = attrs as? [String: Any] else {
                return .refuse(BrowserRefusal(code: "bad_record", field: "attrs", row: row))
            }
            if let refusal = optionalRecordString(dict, key: "label", max: projection.stringBounds.labelStringMax, row: row) {
                return refusal
            }
            if let refusal = optionalRecordString(dict, key: "level", max: projection.stringBounds.levelStringMax, row: row) {
                return refusal
            }
            if let refusal = optionalRecordString(dict, key: "linkHost", max: projection.stringBounds.linkHostStringMax, row: row) {
                return refusal
            }
        }
        return nil
    }

    public static func encodeRecordBytes(_ rec: [String: Any], projection: BrowserContractProjection) -> Data {
        return canonicalEncode(rec, projection: projection)
    }

    public static func validatedHostMessage(
        _ object: [String: Any],
        projection: BrowserContractProjection
    ) throws -> BrowserHostToExtensionMessage {
        if let type = object["type"] as? String, type == "hello_ack" || type == "state" {
            guard let capture = object["capture"] as? String,
                  object.keys.contains("destination_generation"),
                  object.keys.contains("period_id") else {
                throw BrowserIntakeLocalRefusal(code: "bad_state_ids")
            }
            let generation = object["destination_generation"]!
            let period = object["period_id"]!
            switch capture {
            case "unavailable", "not_paired":
                guard generation is NSNull, period is NSNull else {
                    throw BrowserIntakeLocalRefusal(code: "bad_state_ids")
                }
            case "permitted":
                guard generation is String, period is String else {
                    throw BrowserIntakeLocalRefusal(code: "bad_state_ids")
                }
            case "paused", "intake_off":
                guard generation is String, period is NSNull || period is String else {
                    throw BrowserIntakeLocalRefusal(code: "bad_state_ids")
                }
            default:
                throw BrowserIntakeLocalRefusal(code: "bad_state_ids")
            }
        }
        let bytes = canonicalEncode(object, projection: projection)
        switch decode(bytes: bytes, direction: "host_to_extension", projection: projection) {
        case .accept:
            return BrowserHostToExtensionMessage(bytes: bytes)
        case .refuse(let refusal):
            throw BrowserIntakeLocalRefusal(code: refusal.code, field: refusal.field)
        case .unsupported:
            throw BrowserIntakeLocalRefusal(code: "bad_type")
        }
    }

    public static func encodeHostToExtension(_ message: BrowserHostToExtensionMessage) -> Data {
        message.bytes
    }

    public static func canonicalEncode(_ val: Any, projection: BrowserContractProjection) -> Data {
        let str = canonicalStringify(val, keyOrderMap: projection.canonicalKeyOrder)
        return Data(str.utf8)
    }

    public static func canonicalStringify(_ val: Any, keyOrderMap: [String: [String]]) -> String {
        if val is NSNull {
            return "null"
        }
        if let num = val as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            }
            if num.doubleValue == floor(num.doubleValue) && !num.doubleValue.isInfinite {
                return String(format: "%.0f", num.doubleValue)
            }
            return "\(num)"
        }
        if let b = val as? Bool {
            return b ? "true" : "false"
        }
        if let s = val as? String {
            return escapeJsonString(s)
        }
        if let arr = val as? [Any] {
            let items = arr.map { canonicalStringify($0, keyOrderMap: keyOrderMap) }
            return "[" + items.joined(separator: ",") + "]"
        }
        if let dict = val as? [String: Any] {
            var order: [String] = []
            if let type = dict["type"] as? String, let k = keyOrderMap[type] {
                order = k
            } else if let t = dict["t"] as? String {
                order = keyOrderMap[t == "segment_start" ? "snapshot_record" : "delta_record"] ?? []
            } else if dict["id"] != nil || dict["text"] != nil {
                order = keyOrderMap["block"] ?? []
            } else if dict["label"] != nil || dict["level"] != nil || dict["linkHost"] != nil {
                order = keyOrderMap["block_attrs"] ?? []
            }

            let allKeys = Array(dict.keys)
            let presentKnown = order.filter { dict[$0] != nil }
            var unknown = allKeys.filter { !order.contains($0) && dict[$0] != nil }
            unknown.sort { a, b in
                let a16 = Array(a.utf16)
                let b16 = Array(b.utf16)
                for (u1, u2) in zip(a16, b16) {
                    if u1 != u2 { return u1 < u2 }
                }
                return a16.count < b16.count
            }
            let finalOrder = presentKnown + unknown

            let pairs = finalOrder.map { key -> String in
                let valStr = canonicalStringify(dict[key]!, keyOrderMap: keyOrderMap)
                return escapeJsonString(key) + ":" + valStr
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
        return "null"
    }

    private static func escapeJsonString(_ str: String) -> String {
        var out = "\""
        for ch in str.unicodeScalars {
            if ch.value == 0x22 {
                out += "\\\""
            } else if ch.value == 0x5C {
                out += "\\\\"
            } else if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.append(Character(ch))
            }
        }
        out += "\""
        return out
    }

    public static func buildReply(
        destinationGeneration: String,
        inst: String,
        batchId: String,
        result: String,
        periodId: String? = nil,
        reason: String? = nil,
        receiptClass: String? = nil,
        projection: BrowserContractProjection
    ) throws -> [String: Any] {
        if result == "accepted" || result == "duplicate" {
            guard let period = periodId, reason == nil, receiptClass == nil else {
                throw NSError(domain: "BrowserPayloadDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid_receipt"])
            }
            return [
                "type": "accepted",
                "result": result,
                "destination_generation": destinationGeneration,
                "inst": inst,
                "batch_id": batchId,
                "period_id": period
            ]
        } else if result == "rejected" {
            guard let r = reason, periodId == nil else {
                throw NSError(domain: "BrowserPayloadDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid_receipt"])
            }
            let c = receiptClass ?? {
                for (kind, reasons) in projection.receiptClasses {
                    if reasons.contains(r) { return kind }
                }
                return "permanent"
            }()
            return [
                "type": "accepted",
                "result": "rejected",
                "destination_generation": destinationGeneration,
                "inst": inst,
                "batch_id": batchId,
                "reason": r,
                "class": c
            ]
        } else {
            throw NSError(domain: "BrowserPayloadDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid_receipt"])
        }
    }
}

#endif
