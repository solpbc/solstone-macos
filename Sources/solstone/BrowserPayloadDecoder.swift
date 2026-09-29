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
        case "stale_generation":
            return "stale_generation"
        case "resource_exhausted":
            return "resource_exhausted"
        case "queue_full":
            return "queue_full"
        case "age_policy":
            return "age_policy"
        case "expired_unaccepted":
            return "expired_unaccepted"
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
    private static func parseHex4(_ bytes: [UInt8], from start: Int) -> UInt16? {
        var val: UInt16 = 0
        for offset in 0..<4 {
            let b = bytes[start + offset]
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

    private static func hasLoneSurrogateEscape(_ text: String) -> Bool {
        let utf8 = Array(text.utf8)
        var i = 0
        let n = utf8.count
        while i < n {
            if utf8[i] == UInt8(ascii: "\\") && i + 1 < n && utf8[i + 1] == UInt8(ascii: "u") {
                if i + 5 >= n {
                    return true
                }
                guard let hexVal = parseHex4(utf8, from: i + 2) else {
                    return true
                }
                if (0xD800...0xDBFF).contains(hexVal) {
                    if i + 11 < n && utf8[i + 6] == UInt8(ascii: "\\") && utf8[i + 7] == UInt8(ascii: "u") {
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
            } else {
                i += 1
            }
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

    private static func exceedsJsonDepth(_ text: String, maxDepth: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for ch in text {
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

    private static func extractRecordSlices(from rawText: String) -> [Data]? {
        guard let recordsRange = rawText.range(of: "\"records\"") else { return nil }
        let restOfText = rawText[recordsRange.upperBound...]
        guard let openBracketIdx = restOfText.firstIndex(of: "[") else { return nil }

        var slices: [Data] = []
        var idx = rawText.index(after: openBracketIdx)
        let endIdx = rawText.endIndex

        var inString = false
        var escaped = false
        var depth = 0
        var recordStartIdx: String.Index? = nil

        while idx < endIdx {
            let ch = rawText[idx]
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
            } else if ch == "{" {
                if depth == 0 {
                    recordStartIdx = idx
                }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let start = recordStartIdx {
                    let recString = String(rawText[start...idx])
                    slices.append(Data(recString.utf8))
                    recordStartIdx = nil
                }
            } else if ch == "]" && depth == 0 {
                break
            }
            idx = rawText.index(after: idx)
        }
        return slices
    }

    public static func decode(
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

        guard let text = String(data: bytes, encoding: .utf8) else {
            return .refuse(BrowserRefusal(code: "bad_utf8"))
        }

        if bytes.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .refuse(BrowserRefusal(code: "empty_payload"))
        }

        if hasLoneSurrogateEscape(text) {
            return .refuse(BrowserRefusal(code: "lone_surrogate"))
        }

        if exceedsJsonDepth(text, maxDepth: projection.caps.jsonMaxDepth) {
            return .refuse(BrowserRefusal(code: "bad_json"))
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: bytes, options: [])
        } catch {
            return .refuse(BrowserRefusal(code: "bad_json"))
        }

        guard let root = jsonObject as? [String: Any] else {
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
            return decodeBatch(root: root, rawBytes: bytes, rawText: text, projection: projection)
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

    private static func isNonNegativeInteger(_ val: Any?, max: UInt64? = nil) -> Bool {
        guard let num = val as? NSNumber else { return false }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return false }
        let d = num.doubleValue
        if d < 0 || d != floor(d) || d.isInfinite { return false }
        if let max = max, d > Double(max) { return false }
        return true
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
        if version.count > projection.stringBounds.version || inst.isEmpty || inst.count > projection.stringBounds.instStringMax {
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

        if let failureVal = root["failure"], !(failureVal is NSNull) {
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

        if let g = genVal, !(g is NSNull), !(g is String) {
            return .refuse(BrowserRefusal(code: "bad_state_ids"))
        }
        if let p = periodVal, !(p is NSNull), !(p is String) {
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
        if gen.isEmpty || gen.count > projection.stringBounds.generation ||
           period.isEmpty || period.count > projection.stringBounds.periodId {
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

        if batchId.count != projection.caps.batchIdHex ||
           batchId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) == nil {
            return .refuse(BrowserRefusal(code: "invalid_receipt"))
        }

        let periodId = root["period_id"] as? String
        let reason = root["reason"] as? String
        let receiptClass = root["class"] as? String

        if result == "accepted" || result == "duplicate" {
            guard let period = periodId, !period.isEmpty, reason == nil, receiptClass == nil else {
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
            guard let r = reason, let c = receiptClass, periodId == nil else {
                return .refuse(BrowserRefusal(code: "invalid_receipt"))
            }
            guard let validReasons = projection.receiptClasses[c], validReasons.contains(r) else {
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
        rawText: String,
        projection: BrowserContractProjection
    ) -> BrowserDecodeResult {
        guard let gen = root["destination_generation"] as? String,
              let inst = root["inst"] as? String,
              let batchId = root["batch_id"] as? String,
              let queuedAtRaw = root["queued_at_ms"] else {
            return .refuse(BrowserRefusal(code: "missing_field"))
        }

        if batchId.count != projection.caps.batchIdHex ||
           batchId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) == nil {
            return .refuse(BrowserRefusal(code: "bad_batch_id"))
        }

        guard isNonNegativeInteger(queuedAtRaw, max: projection.policy.timestampMax) else {
            return .refuse(BrowserRefusal(code: "bad_number"))
        }
        let queuedAtMs = (queuedAtRaw as! NSNumber).uint64Value

        guard let recordsArray = root["records"] as? [[String: Any]] else {
            return .refuse(BrowserRefusal(code: "missing_field"))
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

        guard let firstCtx = firstRec["ctx"] as? String, !firstCtx.isEmpty else {
            let cause = firstRec.keys.contains("ctx") ? "empty" : "missing"
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

            guard let recCtx = rec["ctx"] as? String, !recCtx.isEmpty else {
                let cause = rec.keys.contains("ctx") ? "empty" : "missing"
                return .refuse(BrowserRefusal(code: "bad_record", field: "ctx", cause: cause, row: row))
            }
            if recCtx != firstCtx {
                return .refuse(BrowserRefusal(code: "mixed_context"))
            }

            if let recInst = rec["inst"] as? String, recInst != inst {
                return .refuse(BrowserRefusal(code: "bad_record", field: "inst", cause: "mismatch", row: row))
            }

            if let snapReason = rec["snapshot_reason"] as? String {
                if snapReason != "delivery_recovery" {
                    return .refuse(BrowserRefusal(code: "invalid_enum"))
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
                    guard let bid = block["id"] as? String, !bid.isEmpty else {
                        let cause = block.keys.contains("id") ? "empty" : "missing"
                        return .refuse(BrowserRefusal(code: "bad_record", field: "id", cause: cause, row: row))
                    }
                    if bid.count > projection.stringBounds.idStringMax {
                        return .refuse(BrowserRefusal(code: "bad_record", field: "id", cause: "too_long", row: row))
                    }
                }
            } else {
                guard let op = opVal, ["add", "update", "remove"].contains(op) else {
                    return .refuse(BrowserRefusal(code: "bad_record", row: row))
                }
                guard let block = rec["block"] as? [String: Any] else {
                    return .refuse(BrowserRefusal(code: "bad_record", row: row))
                }
                guard let bid = block["id"] as? String, !bid.isEmpty else {
                    let cause = block.keys.contains("id") ? "empty" : "missing"
                    return .refuse(BrowserRefusal(code: "bad_record", field: "id", cause: cause, row: row))
                }
                if bid.count > projection.stringBounds.idStringMax {
                    return .refuse(BrowserRefusal(code: "bad_record", field: "id", cause: "too_long", row: row))
                }
                blockIdVal = bid
            }

            let rawSlices = extractRecordSlices(from: rawText)
            let recBytes: Data
            if let slices = rawSlices, row < slices.count {
                recBytes = slices[row]
            } else {
                recBytes = encodeRecordBytes(rec, projection: projection)
            }

            decodedRecords.append(BrowserDecodedBatchRecord(
                rawSlice: recBytes,
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

    public static func encodeRecordBytes(_ rec: [String: Any], projection: BrowserContractProjection) -> Data {
        return canonicalEncode(rec, projection: projection)
    }

    public static func canonicalEncode(_ val: Any, projection: BrowserContractProjection) -> Data {
        let str = canonicalStringify(val, keyOrderMap: projection.canonicalKeyOrder)
        return Data(str.utf8)
    }

    public static func canonicalStringify(_ val: Any, keyOrderMap: [String: [String]]) -> String {
        if val is NSNull {
            return "null"
        }
        if let b = val as? Bool {
            return b ? "true" : "false"
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
