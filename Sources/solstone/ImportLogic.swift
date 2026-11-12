// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
    /// Video, or a type the journal doesn't import.
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

/// PDF, any audio, plain text and the journal's images are taken; HEIC/HEIF is converted to JPEG;
/// everything else, video included, is refused. Plain text means plain text, not Markdown or code,
/// and images mean exactly the four the journal reads as images.
func importIntakeDecision(_ type: UTType?) -> ImportIntakeDecision {
    guard let type else { return .refuse(.unsupportedType) }
    if type == .pdf { return .accept(mime: "application/pdf") }
    if type == .plainText || type == .utf8PlainText { return .accept(mime: "text/plain") }
    if type.conforms(to: .audio) { return .accept(mime: type.preferredMIMEType ?? "audio/mpeg") }
    if type == .png { return .accept(mime: "image/png") }
    if type == .jpeg { return .accept(mime: "image/jpeg") }
    if type == .webP { return .accept(mime: "image/webp") }
    if type == .gif { return .accept(mime: "image/gif") }
    if type == .heic || type == .heif { return .convertToJPEG }
    return .refuse(.unsupportedType)
}

private let importExtensionForMime: [String: String] = [
    "application/pdf": "pdf", "text/plain": "txt", "image/png": "png", "image/jpeg": "jpg",
    "image/webp": "webp", "image/gif": "gif", "audio/mpeg": "mp3", "audio/mp4": "m4a",
    "audio/aac": "aac", "audio/ogg": "ogg", "audio/opus": "opus", "audio/flac": "flac",
    "audio/x-flac": "flac", "audio/wav": "wav", "audio/x-wav": "wav", "audio/webm": "webm",
    "audio/amr": "amr", "audio/3gpp": "3gp",
]

/// The name an item is sent under. The journal decides an item's kind from its extension, so a
/// name without one gets one from its type, and a converted HEIC photo is sent as `.jpg`.
func importIntakeName(_ displayName: String?, mime: String, convertedToJPEG: Bool = false) -> String {
    let sendMime = convertedToJPEG ? "image/jpeg" : mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    let fallback = String(sendMime.split(separator: "/").last ?? "").filter { $0.isLetter || $0.isNumber }
    let wanted = importExtensionForMime[sendMime] ?? (fallback.isEmpty ? "bin" : fallback)
    let base = (displayName ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""
    if base.isEmpty { return "file.\(wanted)" }
    let dot = base.lastIndex(of: ".")
    let hasExtension = dot.map { $0 > base.startIndex && base.index(after: $0) < base.endIndex } ?? false
    if convertedToJPEG { return (hasExtension ? String(base[..<dot!]) : base) + ".jpg" }
    return hasExtension ? base : "\(base).\(wanted)"
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

// MARK: - the journal's answers

enum ImportOutcome: Equatable, Sendable {
    case saved(path: String, timestamp: String)
    case delivered
    case authStop
    /// Try again later. `cause` is a closed token: `io-<kind>`, `http-<status>`,
    /// `unreadable-answer`, `answer-<word>`, `loopback-refused`.
    case retry(cause: String)
    case needsAttention(error: String, reasonCode: String?, kind: String?)
}

enum ImportOperation: Sendable { case save, start }

let importGenericRefusal = "your journal couldn't accept this."

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
    if (500...599).contains(status) { return .retry(cause: "http-\(status)") }
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
                return .delivered
            }
            return .retry(cause: importUnexpectedAnswer(word, expected: "ok"))
        }
    }
    if (200...299).contains(status) { return .retry(cause: "http-\(status)") }
    guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        return .needsAttention(error: importGenericRefusal, reasonCode: nil, kind: nil)
    }
    if status == 400, root["reason_code"] as? String == "invalid_operation_for_state", root["kind"] as? String == "already_imported" {
        return .delivered
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

private func importUnexpectedAnswer(_ word: String?, expected: String) -> String {
    if word == expected { return "answer-incomplete" }
    if let word, (1...32).contains(word.count),
       word.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }) {
        return "answer-\(word)"
    }
    return "answer-unknown"
}

/// The retry schedule: 15 minutes doubling, capped at 4 hours.
func importRetryBackoff(attempt: Int) -> TimeInterval {
    let exponent = min(max(attempt - 1, 0), 4)
    return min(15 * 60 * Double(1 << exponent), 4 * 3600)
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

enum ImportRowKind: Equatable, Sendable {
    case waiting
    case sending
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
}

/// Refusals a retry could plausibly change. Every other refusal offers only `remove`.
let importRetryableReasons: Set<String> = [
    "import_queue_unreachable", "import_metadata_failed", "import_not_found", "import_preview_required",
]
let importNotRetryableKinds: Set<String> = ["client_item_conflict"]

struct ImportSnapshot: Equatable, Sendable {
    var rows: [ImportRow] = []
    var waiting: ImportWaitingReason = .unpaired
    /// What can still go on its own. Zero while the journal is too old.
    var countsAsWaiting = 0
    /// Rows exist and none can go on its own, or the journal is too old for them.
    var needsOwner = false
    var deliveredToCurrentJournal = false
    var interruptedAdd = false
    var storeUnreadable = false
    /// The last add's progress or result.
    var intake: ImportIntakeLine?
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
