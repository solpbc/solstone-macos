// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// What a request to change one item did.
enum ImportChange: Equatable, Sendable {
    case done
    /// The item is in the middle of a journal exchange; nothing was changed.
    case inFlight
    /// The journal already has it; nothing was changed.
    case delivered
    /// The item isn't in a state this change applies to.
    case refused
    /// No such item: it was removed, or finished and deleted after delivery.
    case gone
}

/// Where an item's attention verdict came from, for what the owner is shown.
enum ImportAttentionScope: Equatable, Sendable {
    case none
    /// The journal it would go to now refused it, at its current version.
    case here
    /// Another journal, or an older version of this one, refused it; it is going again.
    case elsewhere
    /// The copy on this Mac is missing.
    case local
}

struct ImportListItem: Equatable, Sendable {
    var id: String
    var displayName: String
    var state: String
    var error: String?
    var reasonCode: String?
    var kind: String?
    var importID: String?
    var reviewExpired: Bool
    var scope: ImportAttentionScope
    var inFlight: Bool
    var hasSavedProgress: Bool
}

struct ImportReviewCandidate: Equatable, Sendable {
    var id: String
    var importID: String
    var instanceID: String
}

struct ImportCandidate: Equatable, Sendable {
    var id: String
    var progress: (path: String, timestamp: String)?

    static func == (a: ImportCandidate, b: ImportCandidate) -> Bool {
        a.id == b.id && a.progress?.path == b.progress?.path && a.progress?.timestamp == b.progress?.timestamp
    }
}

struct ImportItemDescriptor: Equatable, Sendable {
    var id: String
    var payloadURL: URL
    var displayName: String
    var mime: String
    var size: Int64
    var handoff: ImportHandoff?
}

/// One item's record. Field for field the Android app's import row.
struct ImportItemRecord: Codable, Equatable, Sendable {
    var id: String
    var payloadKind: String
    var displayName: String
    var mime: String
    var byteSize: Int64
    /// `pending`, `ready_to_review`, `attention` or `delivered`.
    var state: String
    var createdAt: Date
    var progressPath: String?
    var progressTimestamp: String?
    var progressInstanceID: String?
    var backoffInstanceID: String?
    var attemptCount: Int
    var nextAttemptAt: Date?
    var attentionError: String?
    var attentionReasonCode: String?
    var attentionKind: String?
    var attentionInstanceID: String?
    var attentionJournalVersion: String?
    /// Set when the journal window handed this item over, and sent with its save.
    var handoff: ImportHandoff?
    /// Optional review fields (upgrade-safe for pre-existing custody.json files).
    var reviewImportID: String? = nil
    var reviewKind: String? = nil
    var reviewReasonCode: String? = nil
    var reviewError: String? = nil
    var reviewInstanceID: String? = nil
    var reviewExpired: Bool? = nil

    var isJournalAttention: Bool {
        state == "attention" && attentionInstanceID != nil && attentionJournalVersion != nil
    }

    var isPreviewRequiredAttention: Bool {
        state == "attention" && attentionReasonCode == "import_preview_required"
    }
}

private struct ImportCustodyFile: Codable {
    var version = 1
    var items: [ImportItemRecord] = []
    var lastDeliveredAt: Date?
    var lastDeliveredInstance: String?
    /// Optional 24h recent UI receipts (upgrade-safe for pre-existing custody.json files).
    var recentReceipts: [ImportRecentReceipt]?
}

/// Flushes a file or directory to the disk itself, not only to the drive's cache.
func importFullFsync(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd) }
    if fcntl(fd, F_FULLFSYNC) != 0 {
        guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

/// The owner's held imports: one folder per item, holding the copy as `payload`, and one record
/// file for them all. An item becomes real only when its record is written, after its folder is
/// in place and flushed; a folder without a record is an add that never finished, and is reaped.
///
/// Every method takes the store's lock, so a change and the record it writes can't interleave
/// with another. If the record file can't be read, nothing is changed and nothing is reaped.
final class ImportCustodyStore: @unchecked Sendable {
    let root: URL
    private let lock = NSRecursiveLock()
    private let clock: @Sendable () -> Date
    private let fsync: @Sendable (URL) throws -> Void
    private let move: @Sendable (URL, URL) throws -> Void
    private let remover: @Sendable (URL) -> Bool
    private var file = ImportCustodyFile()
    private var inFlight: Set<String> = []
    private var stagedKinds: [String: String] = [:]
    /// Handed-over items this launch delivered, newest last, with the journal row each became.
    /// The record itself is deleted on delivery; this is what the journal window still asks about.
    private var receipts: [(id: String, importID: String?)] = []
    private static let receiptLimit = 1024
    static let recentReceiptLimit = 5
    static let recentReceiptWindow: TimeInterval = 24 * 60 * 60
    private(set) var unreadable = false

    private var recordURL: URL { root.appendingPathComponent("custody.json") }
    private var stagingRoot: URL { root.appendingPathComponent(".staging", isDirectory: true) }

    init(
        root: URL,
        clock: @escaping @Sendable () -> Date = Date.init,
        fsync: @escaping @Sendable (URL) throws -> Void = importFullFsync,
        move: @escaping @Sendable (URL, URL) throws -> Void = { from, to in
            guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        },
        remover: @escaping @Sendable (URL) -> Bool = { url in
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                return true
            } catch {
                return false
            }
        }
    ) {
        self.root = root
        self.clock = clock
        self.fsync = fsync
        self.move = move
        self.remover = remover
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: recordURL.path) {
            if let data = try? Data(contentsOf: recordURL),
               let decoded = try? JSONDecoder().decode(ImportCustodyFile.self, from: data) {
                file = decoded
            } else {
                unreadable = true
            }
        }
    }

    private func isUnsafeID(_ id: String) -> Bool {
        id.isEmpty || id.contains("/") || id.contains("\\") || id.contains(".")
    }

    /// Writes the record file; the in-memory record changes only once it is on disk.
    private func persist(_ next: ImportCustodyFile) -> Bool {
        guard !unreadable, let data = try? JSONEncoder().encode(next) else { return false }
        let temporary = root.appendingPathComponent(".custody-\(UUID().uuidString).json")
        do {
            try data.write(to: temporary)
            try fsync(temporary)
            if rename(temporary.path, recordURL.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try fsync(root)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        file = next
        return true
    }

    private func update(_ id: String, _ change: (inout ImportItemRecord) -> Void) -> Bool {
        guard let index = file.items.firstIndex(where: { $0.id == id }) else { return false }
        var next = file
        change(&next.items[index])
        return persist(next)
    }

    private func record(_ id: String) -> ImportItemRecord? { file.items.first { $0.id == id } }

    private var ordered: [ImportItemRecord] {
        file.items.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    // MARK: - adding

    /// Starts an add: a staging folder whose `payload` the caller writes.
    func begin() -> String? {
        lock.withLock {
            guard !unreadable else { return nil }
            let id = UUID().uuidString.lowercased()
            do {
                try FileManager.default.createDirectory(at: stagingRoot.appendingPathComponent(id, isDirectory: true), withIntermediateDirectories: true)
            } catch {
                return nil
            }
            stagedKinds[id] = "file"
            return id
        }
    }

    func stagingPayloadURL(_ id: String) -> URL {
        stagingRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent("payload")
    }

    /// Makes a staged add real: flush its copy and folder, move the folder into place, flush the
    /// path down to the store, then write its record. All under the lock, with nothing between.
    func publish(_ id: String, displayName: String, mime: String, size: Int64, handoff: ImportHandoff? = nil) -> Bool {
        lock.withLock {
            guard !unreadable, !isUnsafeID(id), let kind = stagedKinds[id] else { return false }
            let staging = stagingRoot.appendingPathComponent(id, isDirectory: true)
            let payload = staging.appendingPathComponent("payload")
            guard let actual = (try? FileManager.default.attributesOfItem(atPath: payload.path))?[.size] as? NSNumber,
                  actual.int64Value == size else { return false }
            var moved = false
            do {
                try fsync(payload)
                try fsync(staging)
                let target = root.appendingPathComponent(id, isDirectory: true)
                try move(staging, target)
                moved = true
                try fsync(target)
                try fsync(root)
                let row = ImportItemRecord(
                    id: id, payloadKind: kind, displayName: displayName, mime: mime, byteSize: size,
                    state: "pending", createdAt: clock(), progressPath: nil, progressTimestamp: nil,
                    progressInstanceID: nil, backoffInstanceID: nil, attemptCount: 0, nextAttemptAt: nil,
                    attentionError: nil, attentionReasonCode: nil, attentionKind: nil,
                    attentionInstanceID: nil, attentionJournalVersion: nil, handoff: handoff
                )
                guard record(id) == nil else {
                    stagedKinds[id] = nil
                    return false
                }
                var next = file
                next.items.append(row)
                stagedKinds[id] = nil
                return persist(next)
            } catch {
                if moved { stagedKinds[id] = nil }
                return false
            }
        }
    }

    func abandon(_ id: String) {
        lock.withLock {
            guard !isUnsafeID(id) else { return }
            stagedKinds[id] = nil
            _ = remover(stagingRoot.appendingPathComponent(id, isDirectory: true))
        }
    }

    /// Deletes delivered items: the folder first, then the record, so an interrupted finish leaves
    /// a delivered record whose folder is gone, which recovery deletes.
    func finish() {
        lock.withLock {
            guard !unreadable else { return }
            for row in ordered where row.state == "delivered" && !isUnsafeID(row.id) {
                guard remover(root.appendingPathComponent(row.id, isDirectory: true)) else { continue }
                var next = file
                next.items.removeAll { $0.id == row.id }
                _ = persist(next)
            }
        }
    }

    /// Once per launch, before any add or run: finish deliveries, reap abandoned staging and
    /// folders without a record, and mark items whose copy is gone.
    func recover() {
        lock.withLock {
            guard !unreadable else { return }
            finish()
            let fm = FileManager.default
            for child in (try? fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? [] {
                stagedKinds[child.lastPathComponent] = nil
                _ = remover(child)
            }
            let ids = Set(file.items.map(\.id))
            for child in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                let name = child.lastPathComponent
                guard name != ".staging", (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if !ids.contains(name) { _ = remover(child) }
            }
            for row in ordered where !isUnsafeID(row.id) {
                let folder = root.appendingPathComponent(row.id, isDirectory: true)
                let payload = folder.appendingPathComponent("payload")
                let size = (try? fm.attributesOfItem(atPath: payload.path))?[.size] as? NSNumber
                guard size?.int64Value != row.byteSize else { continue }
                if row.state == "delivered" {
                    var next = file
                    next.items.removeAll { $0.id == row.id }
                    _ = persist(next)
                } else if !(row.state == "attention" && row.attentionKind == "missing_copy" && row.attentionInstanceID == nil) {
                    _ = update(row.id) {
                        $0.state = "attention"
                        $0.attentionKind = "missing_copy"
                        $0.attentionError = nil
                        $0.attentionReasonCode = nil
                        $0.attentionInstanceID = nil
                        $0.attentionJournalVersion = nil
                        $0.progressPath = nil
                        $0.progressTimestamp = nil
                        $0.progressInstanceID = nil
                        $0.backoffInstanceID = nil
                        $0.attemptCount = 0
                        $0.nextAttemptAt = nil
                        $0.reviewImportID = nil
                        $0.reviewKind = nil
                        $0.reviewReasonCode = nil
                        $0.reviewError = nil
                        $0.reviewInstanceID = nil
                        $0.reviewExpired = nil
                    }
                }
            }
        }
    }

    // MARK: - delivery

    private static func isAttentionEligible(_ row: ImportItemRecord, instance: String, journalVersion: String) -> Bool {
        guard row.isJournalAttention else { return false }
        if row.isPreviewRequiredAttention {
            // Never auto-retry preview-required refusals on reconnect or journal version bump.
            return row.attentionInstanceID != instance
        }
        return row.attentionInstanceID != instance || row.attentionJournalVersion != journalVersion
    }

    private static func prunedRecentReceipts(_ entries: [ImportRecentReceipt], now: Date) -> [ImportRecentReceipt] {
        let cutoff = now.addingTimeInterval(-recentReceiptWindow)
        var seen: Set<String> = []
        var fresh: [(index: Int, receipt: ImportRecentReceipt)] = []
        for (index, entry) in entries.enumerated() where entry.deliveredAt >= cutoff {
            guard seen.insert(entry.id).inserted else { continue }
            var sanitized = entry
            sanitized.importID = validImportID(entry.importID)
            fresh.append((index, sanitized))
        }
        fresh.sort { a, b in
            if a.receipt.deliveredAt != b.receipt.deliveredAt {
                return a.receipt.deliveredAt > b.receipt.deliveredAt
            }
            return a.index < b.index
        }
        return Array(fresh.prefix(recentReceiptLimit).map(\.receipt))
    }

    func eligible(instance: String, journalVersion: String, now: Date) -> [ImportCandidate] {
        lock.withLock {
            guard !unreadable else { return [] }
            return ordered.compactMap { row in
                guard row.state != "delivered" && row.state != "ready_to_review" else { return nil }
                let eligible: Bool
                if row.state == "pending" {
                    if row.backoffInstanceID == instance, let next = row.nextAttemptAt { eligible = now >= next } else { eligible = true }
                } else if row.isJournalAttention {
                    eligible = Self.isAttentionEligible(row, instance: instance, journalVersion: journalVersion)
                } else {
                    eligible = false
                }
                guard eligible else { return nil }
                if row.progressInstanceID == instance, let path = row.progressPath, let timestamp = row.progressTimestamp {
                    return ImportCandidate(id: row.id, progress: (path, timestamp))
                }
                return ImportCandidate(id: row.id, progress: nil)
            }
        }
    }

    /// Marks an item as in an exchange with `instance`. One refused elsewhere goes back to
    /// pending, since it is being sent again. Only `.done` lets the exchange go.
    func beginExchange(_ id: String, instance: String, journalVersion: String) -> ImportChange {
        lock.withLock {
            guard !unreadable, let row = record(id) else { return .gone }
            if inFlight.contains(id) { return .inFlight }
            if row.state == "delivered" { return .delivered }
            if row.state == "pending" {
                // fine
            } else if Self.isAttentionEligible(row, instance: instance, journalVersion: journalVersion) {
                guard update(id, {
                    $0.state = "pending"
                    $0.attentionError = nil
                    $0.attentionReasonCode = nil
                    $0.attentionKind = nil
                    $0.attentionInstanceID = nil
                    $0.attentionJournalVersion = nil
                }) else { return .refused }
            } else {
                return .refused
            }
            inFlight.insert(id)
            return .done
        }
    }

    func recordSaved(_ id: String, path: String, timestamp: String, instance: String) -> ImportChange {
        lock.withLock {
            guard let row = record(id) else {
                inFlight.remove(id)
                return .gone
            }
            guard row.state == "pending" || row.isJournalAttention else { return .refused }
            return update(id) {
                $0.progressPath = path
                $0.progressTimestamp = timestamp
                $0.progressInstanceID = instance
            } ? .done : .refused
        }
    }

    func recordReadyToReview(
        _ id: String,
        importID: String,
        error: String,
        reasonCode: String,
        kind: String,
        instance: String
    ) -> ImportChange {
        lock.withLock {
            defer { inFlight.remove(id) }
            guard let validID = validImportID(importID) else { return .refused }
            guard let row = record(id) else { return .gone }
            guard row.state == "pending" || row.isJournalAttention else { return .refused }
            return update(id) {
                $0.state = "ready_to_review"
                $0.reviewImportID = validID
                $0.reviewKind = kind
                $0.reviewReasonCode = reasonCode
                $0.reviewError = error.isEmpty ? nil : error
                $0.reviewInstanceID = instance
                $0.reviewExpired = false
                $0.attentionError = nil
                $0.attentionReasonCode = nil
                $0.attentionKind = nil
                $0.attentionInstanceID = nil
                $0.attentionJournalVersion = nil
                $0.backoffInstanceID = nil
                $0.attemptCount = 0
                $0.nextAttemptAt = nil
            } ? .done : .refused
        }
    }

    func recordDelivered(_ id: String, instance: String, importID: String? = nil) -> ImportChange {
        lock.withLock {
            defer { inFlight.remove(id) }
            guard let row = record(id) else { return .gone }
            if row.state == "delivered" { return .done }
            guard row.state == "pending" || row.isJournalAttention,
                  let index = file.items.firstIndex(where: { $0.id == id }) else { return .refused }
            let now = clock()
            let resolvedImportID = validImportID(importID) ?? validImportID(row.progressTimestamp)
            var next = file
            next.items[index].state = "delivered"
            next.lastDeliveredAt = now
            next.lastDeliveredInstance = instance
            let uiReceipt = ImportRecentReceipt(
                id: row.id,
                filename: row.displayName,
                importID: resolvedImportID,
                instanceID: instance,
                deliveredAt: now
            )
            next.recentReceipts = Self.prunedRecentReceipts([uiReceipt] + (next.recentReceipts ?? []), now: now)
            guard persist(next) else { return .refused }
            if row.handoff != nil {
                if receipts.count >= Self.receiptLimit { receipts.removeFirst() }
                receipts.append((id, resolvedImportID ?? importID ?? row.progressTimestamp))
            }
            return .done
        }
    }

    // MARK: - review reconciliation

    func reviewCandidates(instance: String) -> [ImportReviewCandidate] {
        lock.withLock {
            guard !unreadable else { return [] }
            return ordered.compactMap { row in
                guard row.state == "ready_to_review",
                      row.reviewExpired != true,
                      !inFlight.contains(row.id),
                      row.reviewInstanceID == instance,
                      let importID = validImportID(row.reviewImportID) else { return nil }
                return ImportReviewCandidate(id: row.id, importID: importID, instanceID: instance)
            }
        }
    }

    /// Re-verifies `(id, expectedImportID, expectedInstanceID)` under the store lock before
    /// durably writing the 24h recent receipt and marking the item delivered. Local bytes are
    /// removed afterward by `finish()`, preserving durability if interrupted.
    func reconcileConfirmed(_ id: String, expectedImportID: String, expectedInstanceID: String) -> ImportChange {
        lock.withLock {
            guard !unreadable else { return .refused }
            guard let index = file.items.firstIndex(where: { $0.id == id }) else { return .gone }
            let row = file.items[index]
            guard !inFlight.contains(id),
                  row.state == "ready_to_review",
                  row.reviewExpired != true,
                  row.reviewImportID == expectedImportID,
                  row.reviewInstanceID == expectedInstanceID else { return .refused }
            let now = clock()
            let resolvedImportID = validImportID(expectedImportID)
            var next = file
            next.items[index].state = "delivered"
            next.lastDeliveredAt = now
            next.lastDeliveredInstance = expectedInstanceID
            let uiReceipt = ImportRecentReceipt(
                id: row.id,
                filename: row.displayName,
                importID: resolvedImportID,
                instanceID: expectedInstanceID,
                deliveredAt: now
            )
            next.recentReceipts = Self.prunedRecentReceipts([uiReceipt] + (next.recentReceipts ?? []), now: now)
            guard persist(next) else { return .refused }
            if row.handoff != nil {
                if receipts.count >= Self.receiptLimit { receipts.removeFirst() }
                receipts.append((id, resolvedImportID))
            }
            return .done
        }
    }

    /// Re-verifies `(id, expectedImportID, expectedInstanceID)` under the store lock before
    /// marking the staged copy expired. Keeps local bytes intact for `sendAgain`.
    func reconcileExpired(_ id: String, expectedImportID: String, expectedInstanceID: String) -> ImportChange {
        lock.withLock {
            guard !unreadable else { return .refused }
            guard let row = record(id) else { return .gone }
            guard !inFlight.contains(id),
                  row.state == "ready_to_review",
                  row.reviewExpired != true,
                  row.reviewImportID == expectedImportID,
                  row.reviewInstanceID == expectedInstanceID else { return .refused }
            return update(id) {
                $0.reviewExpired = true
            } ? .done : .refused
        }
    }

    /// When paired to a different journal instance, resets `ready_to_review` and `reviewExpired`
    /// items back to `pending` so they deliver cleanly to the new journal.
    func resetReviewItemsForDifferentInstance(_ currentInstance: String) {
        lock.withLock {
            guard !unreadable else { return }
            let needsReset = file.items.contains { row in
                row.state == "ready_to_review"
                    && !inFlight.contains(row.id)
                    && row.reviewInstanceID != currentInstance
            }
            guard needsReset else { return }
            var next = file
            for index in next.items.indices {
                let row = next.items[index]
                guard row.state == "ready_to_review",
                      !inFlight.contains(row.id),
                      row.reviewInstanceID != currentInstance else { continue }
                next.items[index].state = "pending"
                next.items[index].progressPath = nil
                next.items[index].progressTimestamp = nil
                next.items[index].progressInstanceID = nil
                next.items[index].backoffInstanceID = nil
                next.items[index].attemptCount = 0
                next.items[index].nextAttemptAt = nil
                next.items[index].reviewImportID = nil
                next.items[index].reviewKind = nil
                next.items[index].reviewReasonCode = nil
                next.items[index].reviewError = nil
                next.items[index].reviewInstanceID = nil
                next.items[index].reviewExpired = nil
                next.items[index].attentionError = nil
                next.items[index].attentionReasonCode = nil
                next.items[index].attentionKind = nil
                next.items[index].attentionInstanceID = nil
                next.items[index].attentionJournalVersion = nil
            }
            _ = persist(next)
        }
    }

    /// Where a handed-over item is, for the journal window that handed it over.
    func handoffStatus(
        _ id: String,
        missingCopyReason: String,
        reviewReadyReason: String = MacStrings.macos_desktopimportpage_reviewdetail(),
        reviewExpiredReason: String = MacStrings.macos_desktopimportpage_reviewexpired()
    ) -> ImportHandoffStatus {
        lock.withLock {
            if let receipt = receipts.last(where: { $0.id == id }) { return .delivered(importID: receipt.importID) }
            guard !isUnsafeID(id), let row = record(id) else { return .gone }
            if row.state == "delivered" {
                return .delivered(importID: validImportID(row.reviewImportID) ?? validImportID(row.progressTimestamp) ?? row.progressTimestamp)
            }
            if inFlight.contains(id) { return .uploading(sizeBytes: row.byteSize) }
            if row.state == "ready_to_review" {
                if row.reviewExpired == true {
                    return .attention(
                        reason: reviewExpiredReason,
                        importID: validImportID(row.reviewImportID),
                        reviewRequired: false,
                        reviewExpired: true,
                        reasonCode: row.reviewReasonCode,
                        kind: row.reviewKind,
                        retryable: true
                    )
                }
                return .attention(
                    reason: reviewReadyReason,
                    importID: validImportID(row.reviewImportID),
                    reviewRequired: true,
                    reviewExpired: false,
                    reasonCode: row.reviewReasonCode ?? "import_preview_required",
                    kind: row.reviewKind,
                    retryable: false
                )
            }
            if row.state == "attention" {
                if row.isJournalAttention {
                    return .attention(
                        reason: row.attentionError ?? importGenericRefusal,
                        importID: validImportID(row.progressTimestamp),
                        reviewRequired: false,
                        reviewExpired: false,
                        reasonCode: row.attentionReasonCode,
                        kind: row.attentionKind,
                        retryable: isImportAttentionRetryable(reasonCode: row.attentionReasonCode, kind: row.attentionKind)
                    )
                }
                return .attention(
                    reason: missingCopyReason,
                    importID: nil,
                    reviewRequired: false,
                    reviewExpired: false,
                    reasonCode: nil,
                    kind: row.attentionKind,
                    retryable: false
                )
            }
            return .waiting(sizeBytes: row.byteSize)
        }
    }

    func recordAttention(_ id: String, error: String, reasonCode: String, kind: String?, instance: String, journalVersion: String) -> ImportChange {
        lock.withLock {
            defer { inFlight.remove(id) }
            guard let row = record(id) else { return .gone }
            guard row.state == "pending" || row.isJournalAttention else { return .refused }
            return update(id) {
                $0.state = "attention"
                $0.attentionInstanceID = instance
                $0.attentionJournalVersion = journalVersion
                $0.attentionKind = kind
                $0.attentionError = error
                $0.attentionReasonCode = reasonCode
                $0.reviewImportID = nil
                $0.reviewKind = nil
                $0.reviewReasonCode = nil
                $0.reviewError = nil
                $0.reviewInstanceID = nil
                $0.reviewExpired = nil
            } ? .done : .refused
        }
    }

    func markRetry(_ id: String, instance: String, now: Date) {
        lock.withLock {
            guard let row = record(id), row.state == "pending" else { return }
            let count = row.backoffInstanceID == instance ? row.attemptCount + 1 : 1
            _ = update(id) {
                $0.backoffInstanceID = instance
                $0.attemptCount = count
                $0.nextAttemptAt = now.addingTimeInterval(importRetryBackoff(attempt: count))
            }
        }
    }

    func endExchange(_ id: String) {
        lock.withLock { _ = inFlight.remove(id) }
    }

    func isInFlight(_ id: String) -> Bool { lock.withLock { inFlight.contains(id) } }

    // MARK: - the owner's changes

    /// Removes an item: its record first, then its folder, so an interrupted removal leaves only
    /// a folder without a record, which recovery reaps. Refused in an exchange or once delivered.
    func remove(_ id: String) -> ImportChange {
        lock.withLock {
            guard !unreadable else { return .refused }
            guard !isUnsafeID(id), let row = record(id) else { return .gone }
            if inFlight.contains(id) { return .inFlight }
            if row.state == "delivered" { return .delivered }
            var next = file
            next.items.removeAll { $0.id == id }
            guard persist(next) else { return .refused }
            _ = remover(root.appendingPathComponent(id, isDirectory: true))
            return .done
        }
    }

    /// The owner's retry of an item the journal refused.
    func retry(_ id: String) -> ImportChange {
        lock.withLock {
            guard !unreadable else { return .refused }
            guard let row = record(id) else { return .gone }
            if inFlight.contains(id) { return .inFlight }
            if row.state == "delivered" { return .delivered }
            guard row.isJournalAttention else { return .refused }
            return update(id) {
                $0.state = "pending"
                $0.progressPath = nil
                $0.progressTimestamp = nil
                $0.progressInstanceID = nil
                $0.backoffInstanceID = nil
                $0.attemptCount = 0
                $0.nextAttemptAt = nil
                $0.attentionError = nil
                $0.attentionReasonCode = nil
                $0.attentionKind = nil
                $0.attentionInstanceID = nil
                $0.attentionJournalVersion = nil
            } ? .done : .refused
        }
    }

    /// Re-queues an item whose waiting copy in the journal expired, clearing its saved timestamp
    /// so it re-uploads cleanly via `/save` + `/start`.
    func sendAgain(_ id: String) -> ImportChange {
        lock.withLock {
            guard !unreadable else { return .refused }
            guard let row = record(id) else { return .gone }
            if inFlight.contains(id) { return .inFlight }
            if row.state == "delivered" { return .delivered }
            guard row.state == "ready_to_review" else { return .refused }
            return update(id) {
                $0.state = "pending"
                $0.progressPath = nil
                $0.progressTimestamp = nil
                $0.progressInstanceID = nil
                $0.backoffInstanceID = nil
                $0.attemptCount = 0
                $0.nextAttemptAt = nil
                $0.reviewImportID = nil
                $0.reviewKind = nil
                $0.reviewReasonCode = nil
                $0.reviewError = nil
                $0.reviewInstanceID = nil
                $0.reviewExpired = nil
                $0.attentionError = nil
                $0.attentionReasonCode = nil
                $0.attentionKind = nil
                $0.attentionInstanceID = nil
                $0.attentionJournalVersion = nil
            } ? .done : .refused
        }
    }

    func hasSavedProgress(_ id: String) -> Bool {
        lock.withLock {
            guard let row = record(id) else { return false }
            if row.state == "ready_to_review" {
                return row.reviewExpired != true
            }
            return row.progressPath != nil && row.progressTimestamp != nil
        }
    }

    // MARK: - reading

    func items(instance: String?, journalVersion: String?) -> [ImportListItem] {
        lock.withLock {
            ordered.filter { $0.state != "delivered" }.map { row in
                let scope: ImportAttentionScope
                if row.state != "attention" { scope = .none }
                else if !row.isJournalAttention { scope = .local }
                else if row.isPreviewRequiredAttention && row.attentionInstanceID == instance { scope = .here }
                else if row.attentionInstanceID == instance && row.attentionJournalVersion == journalVersion { scope = .here }
                else { scope = .elsewhere }
                let isReview = row.state == "ready_to_review"
                let expired = isReview && row.reviewExpired == true
                return ImportListItem(
                    id: row.id,
                    displayName: row.displayName,
                    state: row.state,
                    error: isReview ? row.reviewError : row.attentionError,
                    reasonCode: isReview ? row.reviewReasonCode : row.attentionReasonCode,
                    kind: isReview ? row.reviewKind : row.attentionKind,
                    importID: isReview ? validImportID(row.reviewImportID) : validImportID(row.progressTimestamp),
                    reviewExpired: expired,
                    scope: scope,
                    inFlight: inFlight.contains(row.id),
                    hasSavedProgress: isReview ? !expired : (row.progressPath != nil && row.progressTimestamp != nil)
                )
            }
        }
    }

    /// Lightweight UI receipts pruned to last 24h (max 5 newest), filtered to the currently paired
    /// and confirmed journal instance. Empty when unpaired or unconfirmed.
    func recentReceipts(forInstance instance: String?, now: Date? = nil) -> [ImportRecentReceipt] {
        lock.withLock {
            guard !unreadable, let instance else { return [] }
            let reference = now ?? clock()
            let pruned = Self.prunedRecentReceipts(file.recentReceipts ?? [], now: reference)
            return pruned.filter { $0.instanceID == instance }
        }
    }

    func lastDeliveredInstance() -> String? { lock.withLock { file.lastDeliveredInstance } }
    func lastDeliveredAt() -> Date? { lock.withLock { file.lastDeliveredAt } }

    func item(_ id: String) -> ImportItemDescriptor? {
        lock.withLock {
            guard !isUnsafeID(id), let row = record(id) else { return nil }
            return ImportItemDescriptor(
                id: row.id,
                payloadURL: root.appendingPathComponent(row.id, isDirectory: true).appendingPathComponent("payload"),
                displayName: row.displayName, mime: row.mime, size: row.byteSize, handoff: row.handoff
            )
        }
    }
}
