// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

// Import: the owner picks or drops a file, a copy is kept on this Mac, and it goes into the
// paired journal through the journal's two-step import exchange (save, then start). These are
// the plain rules; the store, the run and the transport are beside this file.

// MARK: - the journal's version

/// Whether the paired journal can take imports.
enum ImportVersionGate: Equatable, Sendable {
    /// The journal answers a repeated save or start with a replay, so imports may go.
    case supported
    /// No version known yet for this journal.
    case unknown
    /// Older than the first version that can take imports, or its version can't be read.
    case tooOld
}

/// The first journal release whose import save and start are safe to repeat.
let importMinimumJournalVersion = [2, 0, 52]

/// The one gate, shared by delivery and by what the app says about waiting imports. The version
/// may carry a leading `v` and a suffix after its numbers; each part compares as a number.
func importVersionGate(_ version: String?) -> ImportVersionGate {
    guard let version else { return .unknown }
    var trimmed = Substring(version.trimmingCharacters(in: .whitespaces))
    while trimmed.first == "v" { trimmed = trimmed.dropFirst() }
    let numbers = trimmed.prefix { $0.isNumber || $0 == "." }
    let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return .tooOld }
    var values: [Int] = []
    for part in parts {
        guard let value = Int(part) else { return .tooOld }
        values.append(value)
    }
    for i in 0..<max(values.count, importMinimumJournalVersion.count) {
        let a = i < values.count ? values[i] : 0
        let b = i < importMinimumJournalVersion.count ? importMinimumJournalVersion[i] : 0
        if a != b { return a > b ? .supported : .tooOld }
    }
    return .supported
}

// MARK: - what may be added

enum ImportIntakeRefusal: Equatable, Sendable {
    /// Not a file: a folder.
    case unsupportedType
    /// A HEIC photo this Mac couldn't convert.
    case cannotConvert
    /// It couldn't be read, or its read failed part way.
    case unreadable
    /// Larger than the journal takes.
    case tooLarge
    /// Not enough room on this Mac to hold a copy.
    case noSpace
}

enum ImportIntakeDecision: Equatable, Sendable {
    case accept(mime: String)
    case convertToJPEG
    case refuse(ImportIntakeRefusal)
}

/// The most an import may be: the journal's limit for one file.
let importMaxBytes: Int64 = 4 * 1024 * 1024 * 1024
/// Space that must stay free after a copy, so an import never starves capture of room.
let importMinFreeBytes: Int64 = 256 * 1024 * 1024

/// Every file is taken: the journal decides what a file is. A HEIC/HEIF photo is converted to
/// JPEG so the journal dates it by when it was taken; anything else keeps its own type, and a
/// type this Mac can't name goes as `application/octet-stream`.
func importIntakeDecision(_ type: UTType?) -> ImportIntakeDecision {
    if let type, type == .heic || type == .heif { return .convertToJPEG }
    return .accept(mime: type?.preferredMIMEType ?? "application/octet-stream")
}

private let importExtensionForMime: [String: String] = [
    "application/pdf": "pdf", "text/plain": "txt", "image/png": "png", "image/jpeg": "jpg",
    "image/webp": "webp", "image/gif": "gif", "audio/mpeg": "mp3", "audio/mp4": "m4a",
    "audio/aac": "aac", "audio/ogg": "ogg", "audio/opus": "opus", "audio/flac": "flac",
    "audio/x-flac": "flac", "audio/wav": "wav", "audio/x-wav": "wav", "audio/webm": "webm",
    "audio/amr": "amr", "audio/3gpp": "3gp",
]

/// The name an item is sent under. The journal decides an item's kind from its extension, so a
/// name without one gets one from a type this Mac knows the extension of, and a converted HEIC
/// photo is sent as `.jpg`.
func importIntakeName(_ displayName: String?, mime: String, convertedToJPEG: Bool = false) -> String {
    let sendMime = convertedToJPEG ? "image/jpeg" : mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    // Only a type with a known extension gets one; any other name is sent as the owner named it.
    let wanted = importExtensionForMime[sendMime]
    let base = (displayName ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    if base.isEmpty { return wanted.map { "file.\($0)" } ?? "file" }
    let dot = base.lastIndex(of: ".")
    let hasExtension = dot.map { $0 > base.startIndex && base.index(after: $0) < base.endIndex } ?? false
    if convertedToJPEG { return (hasExtension ? String(base[..<dot!]) : base) + ".jpg" }
    guard !hasExtension, let wanted else { return base }
    return "\(base).\(wanted)"
}

/// The filename in the save's `file` part: its last path component, without the characters a
/// header can't carry, at most 128 UTF-8 bytes, keeping its extension.
func importWireFilename(_ raw: String) -> String {
    let parts = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
    let last = parts.last.map(String.init) ?? ""
    let dropped: Set<Unicode.Scalar> = ["\"", "\\", "\r", "\n"]
    var scalars = String.UnicodeScalarView()
    for scalar in last.unicodeScalars where !dropped.contains(scalar) { scalars.append(scalar) }
    let filtered = String(scalars)
    let stem: String
    let ext: String
    if let dot = filtered.lastIndex(of: ".") {
        stem = String(filtered[..<dot])
        ext = String(filtered[dot...])
    } else {
        stem = filtered
        ext = ""
    }
    let safeStem = stem.isEmpty ? "file" : stem
    if safeStem.utf8.count + ext.utf8.count <= 128 { return safeStem + ext }
    if ext.utf8.count <= 128 {
        var kept = ""
        for character in safeStem {
            if (kept + String(character)).utf8.count + ext.utf8.count > 128 { break }
            kept.append(character)
        }
        return kept + ext
    }
    var kept = ""
    for character in ext {
        if (kept + String(character)).utf8.count > 128 { break }
        kept.append(character)
    }
    return kept
}

// MARK: - an import the journal window handed over

/// What the journal's import page said about the files it handed to this app: the import area
/// and the context object, kept as JSON text exactly as it will be sent, so nested keys the app
/// doesn't know survive the queue.
struct ImportHandoff: Codable, Equatable, Sendable {
    var area: String
    var context: String

    /// Areas that are a way of adding, not a kind of file, so they carry no source hint.
    static let unhintedAreas: Set<String> = ["quick", "recording"]
}

/// Strict ASCII `^[0-9]{8}_[0-9]{6}$` check for journal import timestamps/IDs.
func isValidImportID(_ value: String?) -> Bool {
    guard let value else { return false }
    let bytes = Array(value.utf8)
    guard bytes.count == 15, bytes[8] == 0x5F else { return false }
    for index in 0..<15 where index != 8 {
        guard bytes[index] >= 0x30 && bytes[index] <= 0x39 else { return false }
    }
    return true
}

func validImportID(_ value: String?) -> String? {
    isValidImportID(value) ? value : nil
}

/// Only explicit confirmation-required `import_preview_required` kinds enter `ready to review`.
func isConfirmationRequiredKind(_ kind: String?) -> Bool {
    guard let kind, !kind.isEmpty else { return false }
    return kind == "body_confirmation_required"
        || kind == "confirmation_required"
        || kind.hasSuffix("_confirmation_required")
}

/// Phase of an active or paused resumable import upload, matching the journal client contract.
enum ImportUploadPhase: String, Codable, Equatable, Sendable {
    case sending
    case paused
    case checking
}

/// Confirmed byte progress for a resumable import transfer.
struct ImportResumableProgress: Equatable, Sendable {
    var bytesSent: Int64
    var bytesTotal: Int64
    var phase: ImportUploadPhase
    /// True after a pause/reconnect while resyncing and before the first new chunk is confirmed.
    var resuming: Bool = false

    var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, max(0, Double(bytesSent) / Double(bytesTotal)))
    }

    var percent: Int {
        guard bytesTotal > 0 else { return 0 }
        return min(100, max(0, Int((Double(bytesSent) / Double(bytesTotal)) * 100.0)))
    }
}

/// Additive resumable progress fields carried on `import.status` to the journal window.
struct ImportHandoffProgress: Equatable, Sendable {
    var bytesSent: Int64
    var bytesTotal: Int64
    var resumable: Bool
    var phase: ImportUploadPhase
}

/// Resumable upload limits advertised by the paired journal via `/api/system/status` + `/app/import/api/sources`.
struct ImportResumableCapabilities: Equatable, Sendable {
    var thresholdBytes: Int64
    var chunkBytes: Int64
    var maxFileBytes: Int64

    /// Maximum single-chunk payload admitted by the journal / SPL bridge drain ceiling (`8 MiB`).
    static let maxBridgeChunkBytes: Int64 = 8 * 1024 * 1024
    static let capabilityName = "resumable_import_uploads"
}

enum ImportCapabilityProbeOutcome: Equatable, Sendable {
    case supported(ImportResumableCapabilities)
    case unsupported
    case authStop
    case retry(cause: String)
}

/// Where one handed-over item is, for the page that handed it over.
enum ImportHandoffStatus: Equatable, Sendable {
    case waiting(sizeBytes: Int64 = 0, progress: ImportHandoffProgress? = nil)
    case uploading(sizeBytes: Int64 = 0, progress: ImportHandoffProgress? = nil)
    case attention(
        reason: String,
        importID: String?,
        reviewRequired: Bool = false,
        reviewExpired: Bool = false,
        reasonCode: String? = nil,
        kind: String? = nil,
        retryable: Bool = false
    )
    case delivered(importID: String?)
    /// Removed, or delivered and no longer remembered.
    case gone
}

/// Formats byte sizes on the same binary scale as the journal's live transfer strip (`0 B`, `4.0 MB`, `4.0 GB`).
func importFormatBytes(_ bytes: Int64) -> String {
    let clamped = max(0, bytes)
    if clamped == 0 { return "0 B" }
    let kib = 1024.0
    let mib = kib * 1024.0
    let gib = mib * 1024.0
    let value = Double(clamped)
    if value < kib { return "\(clamped) B" }
    if value < mib { return String(format: "%.0f KB", value / kib) }
    if value < gib { return String(format: "%.1f MB", value / mib) }
    return String(format: "%.1f GB", value / gib)
}

/// Computes lowercase 64-hex SHA-256 of an in-memory chunk.
func importDataSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum ImportFileHashResult: Equatable, Sendable {
    case hashed(String)
    case unreadable
    case cancelled
}

/// Streams a custody file in fixed 64 KiB reads to compute its whole-file lowercase 64-hex SHA-256
/// with O(1) memory, verifying exact byte count and checking `shouldStop` between reads.
/// Uses POSIX `open`/`read` into a single reusable buffer so large files never accumulate
/// autoreleased `NSData` pages on a cooperative Swift thread.
func importFileSHA256(
    at url: URL,
    expectedSize: Int64,
    bufferBytes: Int = 64 * 1024,
    shouldStop: () -> Bool = { Task.isCancelled }
) -> ImportFileHashResult {
    guard expectedSize >= 0 else { return .unreadable }
    let fd = Darwin.open(url.path, O_RDONLY)
    guard fd >= 0 else { return .unreadable }
    defer { _ = Darwin.close(fd) }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: max(1, bufferBytes))
    var totalRead: Int64 = 0
    while true {
        if shouldStop() { return .cancelled }
        let n: Int = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            while true {
                let got = Darwin.read(fd, base, raw.count)
                if got < 0 && errno == EINTR { continue }
                return got
            }
        }
        if n < 0 { return .unreadable }
        if n == 0 { break }
        totalRead += Int64(n)
        if totalRead > expectedSize { return .unreadable }
        buffer.withUnsafeBytes { raw in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw.prefix(n)))
        }
    }
    guard totalRead == expectedSize else { return .unreadable }
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return .hashed(hex)
}

// MARK: - the journal's answers

enum ImportOutcome: Equatable, Sendable {
    case saved(path: String, timestamp: String)
    /// The journal has it, under this import row when its answer named one.
    case delivered(importID: String?)
    /// Saved in the journal and awaiting owner preview & confirmation before starting.
    case readyToReview(importID: String?, error: String, reasonCode: String, kind: String)
    case authStop
    /// Try again later. `cause` is a closed token: `io-<kind>`, `http-<status>`,
    /// `unreadable-answer`, `answer-<word>`, `loopback-refused`.
    case retry(cause: String)
    case needsAttention(error: String, reasonCode: String?, kind: String?)
}

enum ImportInspectOutcome: Equatable, Sendable {
    /// Confirmed or retired in the journal: persist 24h receipt first, then delete local bytes.
    case confirmed
    /// Still pending and eligible/unknown: keep `ready to review` and preserve local bytes.
    case stillPending
    /// 404: waiting copy in journal expired; keep local bytes for `send again to review`.
    case expired
    /// 401/403: halt batch and record pairing refusal; never delete local bytes.
    case authStop
    /// 400/429/5xx/malformed/transport: leave unchanged and continue sibling items.
    case unchanged
}

enum ImportOperation: Sendable { case save, start }

let importGenericRefusal = MacStrings.macos_importlogic_yourjournalcouldntacceptthis()

/// Reads the journal's answer, as the Android app does. A 403 from this Mac's own loopback proxy
/// (it marks its refusals) is not the journal refusing the pairing.
func classifyImportResponse(
    _ operation: ImportOperation,
    status: Int,
    body: Data,
    loopbackRefused: Bool = false
) -> ImportOutcome {
    if loopbackRefused { return .retry(cause: "loopback-refused") }
    if status == 401 || status == 403 { return .authStop }
    if status == 408 || (500...599).contains(status) { return .retry(cause: "http-\(status)") }
    if status == 200 {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .retry(cause: "unreadable-answer")
        }
        let word = root["status"] as? String
        switch operation {
        case .save:
            if word == "staged", let path = root["path"] as? String, !path.isEmpty,
               let timestamp = root["timestamp"] as? String, !timestamp.isEmpty {
                return .saved(path: path, timestamp: timestamp)
            }
            return .retry(cause: importUnexpectedAnswer(word, expected: "staged"))
        case .start:
            if word == "ok", let task = root["task_id"] as? String, !task.isEmpty,
               let importID = root["import_id"] as? String, !importID.isEmpty {
                return .delivered(importID: importID)
            }
            return .retry(cause: importUnexpectedAnswer(word, expected: "ok"))
        }
    }
    if (200...299).contains(status) { return .retry(cause: "http-\(status)") }
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        return .needsAttention(error: importGenericRefusal, reasonCode: nil, kind: nil)
    }
    if status == 400, root["reason_code"] as? String == "invalid_operation_for_state", root["kind"] as? String == "already_imported" {
        return .delivered(importID: validImportID(root["import_id"] as? String))
    }
    if operation == .start,
       status == 409,
       let reasonCode = root["reason_code"] as? String,
       reasonCode == "import_preview_required",
       let kind = root["kind"] as? String,
       isConfirmationRequiredKind(kind) {
        let error = (root["error"] as? String).map { String($0.prefix(300)) } ?? ""
        return .readyToReview(
            importID: validImportID(root["import_id"] as? String),
            error: error,
            reasonCode: String(reasonCode.prefix(64)),
            kind: String(kind.prefix(64))
        )
    }
    if let error = root["error"] as? String, let reasonCode = root["reason_code"] as? String {
        return .needsAttention(
            error: String(error.prefix(300)),
            reasonCode: String(reasonCode.prefix(64)),
            kind: (root["kind"] as? String).map { String($0.prefix(64)) }
        )
    }
    return .needsAttention(error: importGenericRefusal, reasonCode: nil, kind: nil)
}

/// Classifies `GET /app/import/api/<id>` for safe reconciliation of `ready to review` items.
/// Fails closed (preserving local bytes) on `pending + unknown/absent saved_start`, malformed JSON,
/// `400`, `429`, `5xx`, or transport failure.
func classifyImportInspectResponse(
    status: Int,
    body: Data,
    loopbackRefused: Bool = false
) -> ImportInspectOutcome {
    if loopbackRefused { return .unchanged }
    if status == 401 || status == 403 { return .authStop }
    if status == 404 { return .expired }
    guard status == 200 else { return .unchanged }
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        return .unchanged
    }
    let statusWord = (root["status"] as? String)?.lowercased()
    let savedStart = root["saved_start"] as? [String: Any]
    let savedStartActive = savedStart?["active"] as? Bool == true
    let savedStartState = (savedStart?["state"] as? String)?.lowercased()
    let retiredStatuses: Set<String> = ["running", "success", "failed", "unconfirmed", "noted", "unavailable"]
    if let statusWord, retiredStatuses.contains(statusWord) {
        return .confirmed
    }
    if savedStartActive || savedStartState == "consumed" {
        return .confirmed
    }
    if statusWord == "pending" {
        if savedStart == nil || savedStartState == nil || savedStartState == "eligible" || savedStartState == "unknown" {
            return .stillPending
        }
    }
    return .unchanged
}

private func importUnexpectedAnswer(_ word: String?, expected: String) -> String {
    if word == expected { return "answer-incomplete" }
    if let word, (1...32).contains(word.count),
       word.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }) {
        return "answer-\(word)"
    }
    return "answer-unknown"
}

/// Payload for `POST /app/import/api/uploads`.
struct ImportUploadCreateRequest: Equatable, Sendable {
    var clientItemID: String
    var filename: String
    var mimeType: String
    var totalBytes: Int64
    var sha256: String
    var importedVia: String
    var deviceNoun: String
    var handoff: ImportHandoff?

    func encodedJSON() -> Data? {
        var obj: [String: Any] = [
            "client_item_id": clientItemID,
            "filename": importWireFilename(filename),
            "total_bytes": totalBytes,
            "sha256": sha256,
            "imported_via": importedVia,
            "device_noun": deviceNoun,
        ]
        let cleanMime = mimeType.filter { $0 != "\r" && $0 != "\n" }
        if !cleanMime.isEmpty {
            obj["mime_type"] = cleanMime
        }
        if let handoff {
            obj["area"] = handoff.area
            if !ImportHandoff.unhintedAreas.contains(handoff.area) {
                obj["source_hint"] = handoff.area
            }
            if let contextData = handoff.context.data(using: .utf8),
               let parsed = (try? JSONSerialization.jsonObject(with: contextData)) as? [String: Any] {
                obj["context"] = parsed
            } else if !handoff.context.isEmpty {
                obj["context"] = handoff.context
            }
        }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

enum ImportUploadCreateOutcome: Equatable, Sendable {
    case open(uploadID: String, nextOffset: Int64, totalBytes: Int64, chunkBytes: Int64, expiresAt: String?)
    case alreadyStaged(path: String, timestamp: String)
    case alreadyImported(importID: String?)
    /// Older journal returned 404 or 405 on `POST /app/import/api/uploads`; fall back to `/save`.
    case unsupported
    case insufficientSpace(error: String, requiredBytes: Int64?, availableBytes: Int64?)
    case authStop
    case retry(cause: String)
    case needsAttention(error: String, reasonCode: String?, kind: String?)
}

enum ImportUploadChunkOutcome: Equatable, Sendable {
    case accepted(nextOffset: Int64, totalBytes: Int64, complete: Bool, expiresAt: String?)
    /// `nextOffset` is nil when an intermediate proxy stripped the 409 JSON body; resync via GET.
    case offsetMismatch(nextOffset: Int64?)
    case chunkChecksumMismatch(nextOffset: Int64?)
    case uploadNotFound
    case insufficientSpace(error: String)
    case authStop
    case retry(cause: String, urlError: URLError.Code? = nil)
    case needsAttention(error: String, reasonCode: String?, kind: String?)
}

enum ImportUploadStatusOutcome: Equatable, Sendable {
    case open(uploadID: String, nextOffset: Int64, totalBytes: Int64, chunkBytes: Int64, phase: ImportUploadPhase, expiresAt: String?)
    case uploadNotFound
    case authStop
    case retry(cause: String)
}

enum ImportUploadCommitOutcome: Equatable, Sendable {
    case staged(path: String, timestamp: String)
    case wholeFileChecksumMismatch(error: String)
    case incompleteUpload(nextOffset: Int64?)
    case uploadNotFound
    case authStop
    case retry(cause: String)
    case needsAttention(error: String, reasonCode: String?, kind: String?)
}

enum ImportUploadAbortOutcome: Equatable, Sendable {
    case deleted
    case notFound
    case authStop
    case retry(cause: String)
}

private func jsonInt64(_ value: Any?) -> Int64? {
    if let i = value as? Int64 { return i }
    if let i = value as? Int { return Int64(i) }
    if let n = value as? NSNumber {
        // Avoid interpreting booleans as 0/1.
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.int64Value
    }
    return nil
}

/// Parses `capabilities` from `GET /api/system/status` for `"resumable_import_uploads"`.
func parseSystemStatusResumableCapability(_ body: Data) -> Bool? {
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        return nil
    }
    guard let caps = root["capabilities"] as? [String] else {
        return false
    }
    return caps.contains(ImportResumableCapabilities.capabilityName)
}

/// Parses top-level `resumable` limits from `GET /app/import/api/sources`.
func parseSourcesResumableCapabilities(_ body: Data) -> ImportResumableCapabilities? {
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          let resumable = root["resumable"] as? [String: Any],
          let threshold = jsonInt64(resumable["threshold_bytes"]), threshold > 0,
          let chunk = jsonInt64(resumable["chunk_bytes"]),
          chunk > 0, chunk <= ImportResumableCapabilities.maxBridgeChunkBytes,
          let maxFile = jsonInt64(resumable["max_file_bytes"]), maxFile >= threshold
    else {
        return nil
    }
    return ImportResumableCapabilities(
        thresholdBytes: threshold,
        chunkBytes: chunk,
        maxFileBytes: maxFile
    )
}

func classifyUploadCreateResponse(
    status: Int,
    body: Data,
    loopbackRefused: Bool = false
) -> ImportUploadCreateOutcome {
    if loopbackRefused { return .retry(cause: "loopback-refused") }
    if status == 401 || status == 403 { return .authStop }
    if status == 404 || status == 405 { return .unsupported }
    if status == 507 {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = (root?["error"] as? String).map { String($0.prefix(300)) } ?? importGenericRefusal
        return .insufficientSpace(
            error: error,
            requiredBytes: jsonInt64(root?["required_bytes"]),
            availableBytes: jsonInt64(root?["available_bytes"])
        )
    }
    if status == 408 || (500...599).contains(status) { return .retry(cause: "http-\(status)") }
    if status == 200 || status == 201 {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .retry(cause: "unreadable-answer")
        }
        let word = root["status"] as? String
        switch word {
        case "open":
            guard let uploadID = root["upload_id"] as? String, !uploadID.isEmpty,
                  let nextOffset = jsonInt64(root["next_offset"]), nextOffset >= 0,
                  let totalBytes = jsonInt64(root["total_bytes"]), totalBytes > 0,
                  let chunkBytes = jsonInt64(root["chunk_bytes"]),
                  chunkBytes > 0, chunkBytes <= ImportResumableCapabilities.maxBridgeChunkBytes else {
                return .retry(cause: "answer-incomplete")
            }
            return .open(
                uploadID: uploadID,
                nextOffset: nextOffset,
                totalBytes: totalBytes,
                chunkBytes: chunkBytes,
                expiresAt: root["expires_at"] as? String
            )
        case "already_staged":
            let saveObj = (root["save_response"] as? [String: Any]) ?? root
            if let path = saveObj["path"] as? String, !path.isEmpty,
               let timestamp = saveObj["timestamp"] as? String, !timestamp.isEmpty {
                return .alreadyStaged(path: path, timestamp: timestamp)
            }
            return .retry(cause: "answer-incomplete")
        case "already_imported":
            return .alreadyImported(importID: validImportID(root["import_id"] as? String))
        default:
            return .retry(cause: importUnexpectedAnswer(word, expected: "open"))
        }
    }
    if (200...299).contains(status) { return .retry(cause: "http-\(status)") }
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        return .needsAttention(error: importGenericRefusal, reasonCode: nil, kind: nil)
    }
    let reasonCode = root["reason_code"] as? String
    let kind = root["kind"] as? String
    if status == 409, reasonCode == "journal_busy" {
        return .retry(cause: "http-409-busy")
    }
    if status == 400, reasonCode == "invalid_operation_for_state", kind == "already_imported" {
        return .alreadyImported(importID: validImportID(root["import_id"] as? String))
    }
    if let error = root["error"] as? String, let reasonCode {
        return .needsAttention(
            error: String(error.prefix(300)),
            reasonCode: String(reasonCode.prefix(64)),
            kind: kind.map { String($0.prefix(64)) }
        )
    }
    return .needsAttention(error: importGenericRefusal, reasonCode: nil, kind: nil)
}

func classifyUploadChunkResponse(
    status: Int,
    body: Data,
    loopbackRefused: Bool = false
) -> ImportUploadChunkOutcome {
    if loopbackRefused { return .retry(cause: "loopback-refused") }
    if status == 401 || status == 403 { return .authStop }
    if status == 404 { return .uploadNotFound }
    if status == 507 {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = (root?["error"] as? String).map { String($0.prefix(300)) } ?? importGenericRefusal
        return .insufficientSpace(error: error)
    }
    if status == 408 || (500...599).contains(status) { return .retry(cause: "http-\(status)") }
    if status == 200 {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let nextOffset = jsonInt64(root["next_offset"]), nextOffset >= 0,
              let totalBytes = jsonInt64(root["total_bytes"]), totalBytes > 0 else {
            return .retry(cause: "unreadable-answer")
        }
        let complete = (root["complete"] as? Bool) ?? (nextOffset >= totalBytes)
        return .accepted(
            nextOffset: nextOffset,
            totalBytes: totalBytes,
            complete: complete,
            expiresAt: root["expires_at"] as? String
        )
    }
    if (200...299).contains(status) { return .retry(cause: "http-\(status)") }
    let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    let reasonCode = root?["reason_code"] as? String
    if status == 409 {
        if reasonCode == "journal_busy" {
            return .retry(cause: "http-409-busy")
        }
        // Includes bodyless 409 from proxy EarlyFinal: nextOffset nil triggers GET resync.
        return .offsetMismatch(nextOffset: jsonInt64(root?["next_offset"]))
    }
    if status == 422, reasonCode == "chunk_checksum_mismatch" {
        return .chunkChecksumMismatch(nextOffset: jsonInt64(root?["next_offset"]))
    }
    if status == 400, reasonCode == "incomplete_chunk_body" {
        return .retry(cause: "http-400-incomplete-chunk")
    }
    if let root, let error = root["error"] as? String, let reasonCode {
        return .needsAttention(
            error: String(error.prefix(300)),
            reasonCode: String(reasonCode.prefix(64)),
            kind: (root["kind"] as? String).map { String($0.prefix(64)) }
        )
    }
    return .needsAttention(error: importGenericRefusal, reasonCode: nil, kind: nil)
}

func classifyUploadStatusResponse(
    status: Int,
    body: Data,
    loopbackRefused: Bool = false
) -> ImportUploadStatusOutcome {
    if loopbackRefused { return .retry(cause: "loopback-refused") }
    if status == 401 || status == 403 { return .authStop }
    if status == 404 { return .uploadNotFound }
    if status == 408 || (500...599).contains(status) { return .retry(cause: "http-\(status)") }
    guard status == 200,
          let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          let uploadID = root["upload_id"] as? String, !uploadID.isEmpty,
          let nextOffset = jsonInt64(root["next_offset"]), nextOffset >= 0,
          let totalBytes = jsonInt64(root["total_bytes"]), totalBytes > 0,
          let chunkBytes = jsonInt64(root["chunk_bytes"]),
          chunkBytes > 0, chunkBytes <= ImportResumableCapabilities.maxBridgeChunkBytes else {
        return .retry(cause: status == 200 ? "unreadable-answer" : "http-\(status)")
    }
    let phase = (root["phase"] as? String).flatMap(ImportUploadPhase.init(rawValue:)) ?? .sending
    return .open(
        uploadID: uploadID,
        nextOffset: nextOffset,
        totalBytes: totalBytes,
        chunkBytes: chunkBytes,
        phase: phase,
        expiresAt: root["expires_at"] as? String
    )
}

func classifyUploadCommitResponse(
    status: Int,
    body: Data,
    loopbackRefused: Bool = false
) -> ImportUploadCommitOutcome {
    if loopbackRefused { return .retry(cause: "loopback-refused") }
    if status == 401 || status == 403 { return .authStop }
    if status == 404 { return .uploadNotFound }
    if status == 408 || (500...599).contains(status) { return .retry(cause: "http-\(status)") }
    if status == 200 {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .retry(cause: "unreadable-answer")
        }
        if root["status"] as? String == "staged",
           let path = root["path"] as? String, !path.isEmpty,
           let timestamp = root["timestamp"] as? String, !timestamp.isEmpty {
            return .staged(path: path, timestamp: timestamp)
        }
        return .retry(cause: importUnexpectedAnswer(root["status"] as? String, expected: "staged"))
    }
    if (200...299).contains(status) { return .retry(cause: "http-\(status)") }
    let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    let reasonCode = root?["reason_code"] as? String
    if status == 409 {
        if reasonCode == "journal_busy" {
            return .retry(cause: "http-409-busy")
        }
        return .incompleteUpload(nextOffset: jsonInt64(root?["next_offset"]))
    }
    if status == 422, reasonCode == "whole_file_checksum_mismatch" {
        let error = (root?["error"] as? String).map { String($0.prefix(300)) } ?? importGenericRefusal
        return .wholeFileChecksumMismatch(error: error)
    }
    if let root, let error = root["error"] as? String, let reasonCode {
        return .needsAttention(
            error: String(error.prefix(300)),
            reasonCode: String(reasonCode.prefix(64)),
            kind: (root["kind"] as? String).map { String($0.prefix(64)) }
        )
    }
    return .needsAttention(error: importGenericRefusal, reasonCode: nil, kind: nil)
}

func classifyUploadAbortResponse(
    status: Int,
    loopbackRefused: Bool = false
) -> ImportUploadAbortOutcome {
    if loopbackRefused { return .retry(cause: "loopback-refused") }
    if status == 401 || status == 403 { return .authStop }
    if status == 404 { return .notFound }
    if (200...299).contains(status) { return .deleted }
    return .retry(cause: "http-\(status)")
}

/// The retry schedule for transient delivery failures: short first steps so a brief
/// relay or network blip recovers quickly, then backing off to a 4-hour cap.
private let importRetryBackoffSchedule: [TimeInterval] = [
    5,
    15,
    60,
    5 * 60,
    15 * 60,
    30 * 60,
    60 * 60,
    2 * 3600,
    4 * 3600,
]

func importRetryBackoff(attempt: Int) -> TimeInterval {
    guard attempt > 1 else { return importRetryBackoffSchedule[0] }
    let index = min(attempt - 1, importRetryBackoffSchedule.count - 1)
    return importRetryBackoffSchedule[index]
}

/// Contract retry ladder for resumable chunk uploads: `1s -> 2s -> 5s -> 10s -> 30s -> 60s`
/// with `±20%` jitter, capped at 60 s and reset on every confirmed chunk or reconnect/wake.
let importChunkRetryBackoffBaseSeconds: [TimeInterval] = [1, 2, 5, 10, 30, 60]

/// `jitterUnit` is in `0.0...1.0` (`0.5` yields exact base delay; `0.0` = `-20%`, `1.0` = `+20%`).
func importChunkRetryBackoff(attempt: Int, jitterUnit: Double = Double.random(in: 0...1)) -> TimeInterval {
    let base: TimeInterval
    if attempt <= 1 {
        base = importChunkRetryBackoffBaseSeconds[0]
    } else {
        let index = min(attempt - 1, importChunkRetryBackoffBaseSeconds.count - 1)
        base = importChunkRetryBackoffBaseSeconds[index]
    }
    let clamped = min(1.0, max(0.0, jitterUnit))
    let factor = 0.8 + (clamped * 0.4)
    return base * factor
}

// MARK: - what the page shows

/// Why imports are still on this Mac, the most important reason first.
enum ImportWaitingReason: Equatable, Sendable {
    case unpaired, awaitingConfirmation, pairingRefused, checkingJournal, journalTooOld, sending, waiting
}

/// The facts the waiting reason is read from.
struct ImportFacts: Equatable, Sendable {
    var paired = false
    var markConfirmed = false
    var syncPaused = false
    /// The pairing was revoked or refused, or the journal refused it here.
    var pairingRefused = false
    /// Whether the paired journal is currently offline or unreachable.
    var offline = false
    /// The journal's identity, when this Mac knows it; nil means no instance.
    var instance: String?
    var version: String?
    /// The address imports go to, when there is one.
    var serverURL: String?
}

func importWaitingReason(_ facts: ImportFacts, gate: ImportVersionGate, sending: Bool) -> ImportWaitingReason {
    if !facts.paired { return .unpaired }
    if !facts.markConfirmed { return .awaitingConfirmation }
    if facts.pairingRefused { return .pairingRefused }
    switch gate {
    case .unknown: return .checkingJournal
    case .tooOld: return .journalTooOld
    case .supported: return sending ? .sending : .waiting
    }
}

/// Persisted lightweight UI receipt for a delivered or confirmed import (24h, cap 5, per-instance).
struct ImportRecentReceipt: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var filename: String
    var importID: String?
    var instanceID: String
    var deliveredAt: Date
}

enum ImportRowKind: Equatable, Sendable {
    case waiting
    case sending
    /// A resumable transfer paused mid-way (offline, network switch, sleep, or backoff). Non-fault.
    case paused
    /// Saved in the journal and awaiting owner preview & confirmation before starting.
    case readyToReview
    /// Waiting copy in the journal expired; local copy is still held for one-tap re-send.
    case reviewExpired
    /// The journal it would go to now refused it.
    case refused(String)
    /// Another journal, or an older version of this one, refused it; it is going again.
    case goingAgain
    /// The copy on this Mac is missing.
    case missingCopy
}

struct ImportRow: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var kind: ImportRowKind
    /// A retry could plausibly go differently.
    var retryable: Bool
    /// The journal already holds a staged copy, so removing it here may not keep it out.
    var savedAtJournal: Bool
    /// Valid ASCII `YYYYMMDD_HHMMSS` journal import ID when known.
    var importID: String? = nil
    var reasonCode: String? = nil
    var reviewKind: String? = nil
    var reviewExpired: Bool = false
    /// Total file size in bytes.
    var byteSize: Int64 = 0
    /// Confirmed byte progress when this item is transferring or paused via resumable chunks.
    var progress: ImportResumableProgress? = nil
}

/// Refusals a retry could plausibly change. Every other refusal offers only `remove`.
let importRetryableReasons: Set<String> = [
    "import_queue_unreachable",
    "import_metadata_failed",
    "import_not_found",
    "insufficient_journal_space",
    "whole_file_checksum_mismatch",
    "upload_not_found",
]
let importNotRetryableKinds: Set<String> = [
    "client_item_conflict", "plan_failed", "nothing_to_import", "invalid_request", "not_found",
]

func isImportAttentionRetryable(reasonCode: String?, kind: String?) -> Bool {
    if let kind, importNotRetryableKinds.contains(kind) { return false }
    if reasonCode == "import_preview_required" {
        return kind == "source_changed" || kind == "already_running"
    }
    return importRetryableReasons.contains(reasonCode ?? "")
}

struct ImportSnapshot: Equatable, Sendable {
    var rows: [ImportRow] = []
    var recentReceipts: [ImportRecentReceipt] = []
    var waiting: ImportWaitingReason = .unpaired
    var offline = false
    /// Whether `more imports` and journal import links should appear (paired, confirmed, not refused).
    var canOpenJournalImport = false
    /// What can still go on its own. Zero while the journal is too old.
    var countsAsWaiting = 0
    /// Rows exist and none can go on its own, or the journal is too old for them.
    var needsOwner = false
    var deliveredToCurrentJournal = false
    var interruptedAdd = false
    var storeUnreadable = false
    /// The last add's progress or result.
    var intake: ImportIntakeLine?

    /// Items awaiting owner review (normal or expired). Non-fault; never increments waiting.
    var readyToReviewCount: Int { reviewRows.count }

    /// Real faults: refused, missing copy, journal too old with queued rows, or unreadable store.
    var hasFault: Bool {
        if storeUnreadable { return true }
        let hasFaultRow = rows.contains { row in
            switch row.kind {
            case .refused, .missingCopy: return true
            case .waiting, .sending, .paused, .goingAgain, .readyToReview, .reviewExpired: return false
            }
        }
        if hasFaultRow { return true }
        return waiting == .journalTooOld && rows.contains { row in
            switch row.kind {
            case .waiting, .sending, .paused, .goingAgain: return true
            case .readyToReview, .reviewExpired, .refused, .missingCopy: return false
            }
        }
    }

    var reviewRows: [ImportRow] {
        rows.filter { $0.kind == .readyToReview || $0.kind == .reviewExpired }
    }

    /// Non-review rows (`on this device`), sorted actionable-first: attention, sending, paused, waiting.
    var onDeviceRows: [ImportRow] {
        let filtered = rows.filter { $0.kind != .readyToReview && $0.kind != .reviewExpired }
        func rank(_ kind: ImportRowKind) -> Int {
            switch kind {
            case .refused, .missingCopy: return 0
            case .sending: return 1
            case .paused: return 2
            case .waiting, .goingAgain: return 3
            case .readyToReview, .reviewExpired: return 4
            }
        }
        return filtered.enumerated().sorted { lhs, rhs in
            let a = rank(lhs.element.kind)
            let b = rank(rhs.element.kind)
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    var hasSending: Bool {
        rows.contains { $0.kind == .sending }
    }

    var hasPaused: Bool {
        rows.contains { $0.kind == .paused }
    }

    var hasActiveOrHeldItems: Bool {
        !rows.isEmpty || storeUnreadable
    }
}

enum ImportIntakeLine: Equatable, Sendable {
    case copying(done: Int, total: Int)
    case finished(accepted: Int, refused: [ImportRefusedItem])
}

struct ImportRefusedItem: Equatable, Sendable {
    var name: String
    var reason: ImportIntakeRefusal
}

/// What a remove or a retry did.
enum ImportActionResult: Equatable, Sendable {
    case done
    /// For a remove: whether the journal may already hold a staged copy.
    case removed(savedAtJournal: Bool)
    /// It is in a journal exchange now; nothing changed.
    case busy
    case alreadyDelivered
    case gone
    /// It isn't in a state this applies to.
    case notApplicable
    case storeUnreadable
}
