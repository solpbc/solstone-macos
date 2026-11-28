// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation

/// Serial engine owning the durable per-folder ledger (`Solstone/folders/ledger.json`),
/// recursive non-hydrating scans, five-minute windowing, note edit coalescing & revert
/// suppression, one-hour document/transcript revision cool-down, inode/hash rename
/// matching, delete-before-send, pause-without-skipping, and Protocol v3 delivery batching.
///
/// Zero journal identity is stored in `ledger.json`.
actor FolderSourceEngine {
    static let ledgerFileName = "ledger.json"
    static let ledgerVersion = 1
    private static let retryDelaysMs: [Int64] = [30_000, 120_000, 600_000, 1_800_000]

    struct OverlapContext: Sendable {
        var obsidian: (path: String, name: String)?
        var screenshots: (path: String, name: String)?
    }

    struct PendingEvent: Codable, Equatable, Sendable {
        var id: String
        var relPath: String
        var previousPath: String?
        var verb: FolderActivityVerb
        var kind: FolderFileKind
        var delivery: FolderDeliveryMode
        var eventMs: Int64
        var observedMs: Int64
        var atRFC3339: String
        var observedRFC3339: String
        var createdRFC3339: String?
        var modifiedRFC3339: String?
        var fileExtension: String?
        var sizeBytes: Int64?
        var window: ObsidianWindow
        var windowEndMs: Int64
        var contentHash: String?
        var inlineNoteText: String?
        var platform: FolderPlatformMetadata?
        var isRevision: Bool = false
        var backfill: Bool = false
        var isFallbackDetailsOnly: Bool = false
        var retryAtMs: Int64?
        var tries: Int = 0
    }

    struct TrackedFile: Codable, Equatable, Sendable {
        var relPath: String
        var device: UInt64
        var inode: UInt64
        var sizeBytes: Int64
        var modifiedMs: Int64
        var createdMs: Int64?
        var fileExtension: String
        var kind: FolderFileKind
        var delivery: FolderDeliveryMode
        var contentHash: String?
        var deliveredToJournal: Bool = false
        var excludedBeforeSpan: Bool = false
        var lastSentHash: String?
        var lastNoteText: String?
        var pendingRevisionSaveMs: Int64?
        var pendingRevisionHash: String?
        var refusedContentHash: String?
    }

    struct FolderRecord: Codable, Equatable, Sendable {
        var id: String
        var path: String
        var name: String
        var bookmark: Data?
        var mode: FolderMode = .settingUp
        var returning: Bool = false
        var widening: Bool = false
        var kinds: FolderKinds = .allOn
        var facet: String?
        var span: FolderSpan = .last30Days
        var overlap: FolderOverlapInfo?
        var spanFromMs: Int64?
        var files: [String: TrackedFile] = [:]
        var pending: [PendingEvent] = []
        var backfillTotal: Int?
        var backfillDone: Int = 0
        var deliveredTotal: Int = 0
        var lastAddedMs: Int64?
        var lastCheckedMs: Int64?
        var fallbackToDetails: Int = 0
        var attention: FolderAttention?
        var cantRead: Int = 0
    }

    private struct Ledger: Codable, Equatable {
        var v: Int
        var folders: [FolderRecord]
    }

    private let directory: URL
    private let ledgerURL: URL
    private let reader: any FolderSystemReading
    private let totals: SourceTotals?
    private let timeZone: @Sendable () -> TimeZone
    private let onDelivered: @Sendable () async -> Void

    private var ledger: Ledger
    private var supported: FolderSupportedList = .defaults
    private var previews: [String: FolderPreviewSummary] = [:]

    init(
        directory: URL,
        reader: any FolderSystemReading = FolderSourceMacReader(),
        totals: SourceTotals? = nil,
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        onDelivered: @escaping @Sendable () async -> Void = {}
    ) {
        self.directory = directory
        self.ledgerURL = directory.appendingPathComponent(Self.ledgerFileName)
        self.reader = reader
        self.totals = totals
        self.timeZone = timeZone
        self.onDelivered = onDelivered
        if let data = try? Data(contentsOf: ledgerURL),
           let decoded = try? JSONDecoder().decode(Ledger.self, from: data),
           decoded.v == Self.ledgerVersion {
            self.ledger = decoded
        } else {
            self.ledger = Ledger(v: Self.ledgerVersion, folders: [])
        }
    }

    func setSupportedList(_ list: FolderSupportedList) {
        supported = list
    }

    func supportedList() -> FolderSupportedList {
        supported
    }

    // MARK: - Path check & folder lifecycle

    func checkAndAddFolder(
        rawPath: String,
        bookmark: Data? = nil,
        overlapContext: OverlapContext,
        allowOverlap: Bool = false
    ) -> FolderPickOutcome {
        let access = reader.checkFolderAccess(path: rawPath)
        guard access == .ok else {
            return reader.isThirdPartyStoragePath(rawPath) ? .refusedStorageProvider : .refusedLocal
        }
        let canonical = FolderSourceClassify.canonicalPath(rawPath)
        let name = FolderSourceClassify.usableFolderName(URL(fileURLWithPath: canonical).lastPathComponent)
        let existing = ledger.folders.map { (id: $0.id, path: $0.path, name: $0.name) }

        let check = FolderSourceClassify.detectOverlap(
            candidatePath: canonical,
            obsidian: overlapContext.obsidian,
            screenshots: overlapContext.screenshots,
            existingFolders: existing
        )

        var overlapInfo: FolderOverlapInfo?
        switch check {
        case .alreadyAdded(let id, let existingName):
            return .alreadyAdded(id: id, name: existingName)
        case .overlap(let info):
            if !allowOverlap {
                return .needsOverlapConfirmation(path: canonical, name: name, overlap: info)
            }
            overlapInfo = info
        case .none:
            break
        }

        let id = FolderSourceClassify.makeFolderID(name: name, canonicalPath: canonical)
        let record = FolderRecord(
            id: id,
            path: canonical,
            name: name,
            bookmark: bookmark,
            mode: .settingUp,
            returning: false,
            widening: false,
            kinds: .allOn,
            facet: nil,
            span: .last30Days,
            overlap: overlapInfo
        )
        ledger.folders.append(record)
        save()
        return .added(id: id)
    }

    /// Re-point an existing folder (e.g. after it moved or permissions changed).
    func repointFolder(
        id: String,
        newPath: String,
        bookmark: Data? = nil
    ) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        let access = reader.checkFolderAccess(path: newPath)
        guard access == .ok else { return false }
        let canonical = FolderSourceClassify.canonicalPath(newPath)
        let name = FolderSourceClassify.usableFolderName(URL(fileURLWithPath: canonical).lastPathComponent)
        ledger.folders[idx].path = canonical
        ledger.folders[idx].name = name
        ledger.folders[idx].bookmark = bookmark
        ledger.folders[idx].attention = nil
        save()
        return true
    }

    func updateKinds(id: String, kinds: FolderKinds) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        guard ledger.folders[idx].kinds != kinds else { return false }
        ledger.folders[idx].kinds = kinds
        save()
        return true
    }

    func updateFacet(id: String, facet: String?) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        let cleaned = facet?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (cleaned?.isEmpty == true) ? nil : cleaned
        guard ledger.folders[idx].facet != value else { return false }
        ledger.folders[idx].facet = value
        save()
        return true
    }

    func selectSpan(id: String, span: FolderSpan) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        ledger.folders[idx].span = span
        save()
        return true
    }

    func startWidening(id: String) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        guard ledger.folders[idx].mode == .on || ledger.folders[idx].mode == .paused else { return false }
        ledger.folders[idx].widening = true
        ledger.folders[idx].returning = true
        save()
        return true
    }

    func cancelWidening(id: String) {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return }
        ledger.folders[idx].widening = false
        previews[id] = nil
        save()
    }

    func pauseFolder(id: String) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        guard ledger.folders[idx].mode == .on else { return false }
        ledger.folders[idx].mode = .paused
        save()
        return true
    }

    func resumeFolder(id: String) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        guard ledger.folders[idx].mode == .paused else { return false }
        ledger.folders[idx].mode = .on
        save()
        return true
    }

    func turnOffFolder(id: String) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        ledger.folders[idx].mode = .off
        ledger.folders[idx].widening = false
        ledger.folders[idx].pending.removeAll()
        ledger.folders[idx].backfillTotal = nil
        ledger.folders[idx].backfillDone = 0
        ledger.folders[idx].attention = nil
        previews[id] = nil
        save()
        return true
    }

    func turnOnFolder(id: String) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        guard ledger.folders[idx].mode == .off else { return false }
        ledger.folders[idx].mode = .settingUp
        ledger.folders[idx].returning = true
        ledger.folders[idx].widening = false
        save()
        return true
    }

    func removeFolder(id: String) -> Bool {
        let before = ledger.folders.count
        ledger.folders.removeAll { $0.id == id }
        previews[id] = nil
        let removed = ledger.folders.count != before
        if removed { save() }
        return removed
    }

    /// Pairing privacy principle 9: when switching from a journal this folder has already
    /// synced with, return active/paused folders to `settingUp` (`returning = true`) and
    /// drop unsent items so nothing crosses pairings. A folder confirmed while unpaired
    /// (nothing ever delivered yet) keeps its state and waiting queue so files waiting
    /// on this Mac deliver as soon as a journal connects.
    func restartFirstSetup() {
        for idx in ledger.folders.indices {
            let hasDeliveredBefore = ledger.folders[idx].deliveredTotal > 0
                || ledger.folders[idx].files.values.contains(where: \.deliveredToJournal)
            guard hasDeliveredBefore else { continue }
            if ledger.folders[idx].mode == .on || ledger.folders[idx].mode == .paused {
                ledger.folders[idx].mode = .settingUp
                ledger.folders[idx].returning = true
            }
            ledger.folders[idx].widening = false
            ledger.folders[idx].pending.removeAll()
            ledger.folders[idx].backfillTotal = nil
            ledger.folders[idx].backfillDone = 0
            ledger.folders[idx].deliveredTotal = 0
            ledger.folders[idx].spanFromMs = nil
            for key in ledger.folders[idx].files.keys {
                ledger.folders[idx].files[key]?.deliveredToJournal = false
                ledger.folders[idx].files[key]?.lastSentHash = nil
                ledger.folders[idx].files[key]?.pendingRevisionSaveMs = nil
                ledger.folders[idx].files[key]?.pendingRevisionHash = nil
                ledger.folders[idx].files[key]?.refusedContentHash = nil
            }
        }
        previews.removeAll()
        save()
    }

    // MARK: - Preview & Confirm

    func setPreviewScanning(id: String) {
        var current = previews[id] ?? FolderPreviewSummary()
        current.scanning = true
        current.scanFailed = false
        previews[id] = current
    }

    /// Walk the folder locally (without hydrating evicted iCloud files) and compute preview counts
    /// plus the estimate payload for `POST /app/devices/ingest/folder/estimate`.
    func computePreview(
        id: String,
        now: Date
    ) -> (summary: FolderPreviewSummary, estimateItems: [FolderEstimateItem])? {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return nil }
        let folder = ledger.folders[idx]
        let tz = timeZone()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let nowMs = Self.ms(now)
        let cutoffMs = folder.span.cutoffMilliseconds(now: now, calendar: calendar)

        let walk = reader.walk(rootPath: folder.path, bookmark: folder.bookmark)
        if walk.status != .ok {
            var failed = FolderPreviewSummary(span: folder.span, scanFailed: true, scanning: false)
            failed.estimateState = .idle
            previews[id] = failed
            return (failed, [])
        }

        let canonicalRoot = FolderSourceClassify.canonicalPath(folder.path)
        var summary = FolderPreviewSummary(span: folder.span, unreadable: walk.unreadableDirs, scanFailed: false, scanning: false)
        var estimateItems: [FolderEstimateItem] = []

        if folder.span == .fromToday {
            summary.estimateState = .idle
            previews[id] = summary
            return (summary, [])
        }

        for file in walk.files {
            if let cutoffMs, file.modifiedMs < cutoffMs {
                continue
            }
            if let existing = folder.files[file.relativePath], existing.deliveredToJournal {
                continue
            }

            let isImage = supported.isImageExtension(file.fileExtension)
            let (isScreenshot, _) = reader.readMetadata(path: file.absolutePath, isImage: isImage)

            var noteData: Data?
            var contentHash: String?
            if supported.noteExtensions.contains(file.fileExtension) && file.sizeBytes <= supported.maxNoteBytes {
                if let read = reader.readAndHash(
                    path: file.absolutePath,
                    canonicalRoot: canonicalRoot,
                    expectedDevice: file.device,
                    expectedInode: file.inode,
                    maxInlineBytes: Int(supported.maxNoteBytes)
                ) {
                    noteData = read.inlineData
                    contentHash = read.sha256
                }
            }

            let (kind, delivery) = FolderSourceClassify.classifyFile(
                extension: file.fileExtension,
                sizeBytes: file.sizeBytes,
                isScreenshot: isScreenshot,
                noteBytes: noteData,
                kinds: folder.kinds,
                supported: supported
            )
            if delivery == .ignore { continue }

            summary.totalItems += 1
            if delivery == .content {
                summary.contentItems += 1
                summary.contentBytes += file.sizeBytes
            } else {
                summary.metadataOnlyItems += 1
            }

            let clampedMs = min(file.modifiedMs, nowMs)
            summary.earliestMs = summary.earliestMs.map { min($0, clampedMs) } ?? clampedMs
            summary.latestMs = summary.latestMs.map { max($0, clampedMs) } ?? clampedMs

            if estimateItems.count < FolderSourceWireConstants.maxEstimateItems {
                let stamp = ObsidianStamp(milliseconds: clampedMs, timeZone: tz)
                let hasContent = delivery == .content
                let cleanExt = (!file.fileExtension.isEmpty && file.fileExtension.utf8.count <= 64) ? file.fileExtension : nil
                estimateItems.append(FolderEstimateItem(
                    path: file.relativePath,
                    at: stamp.rfc3339,
                    fileType: cleanExt,
                    kindHint: hasContent ? kind.kindHint : nil,
                    contentHash: hasContent ? contentHash : nil,
                    hasContent: hasContent
                ))
            }
        }

        previews[id] = summary
        return (summary, estimateItems)
    }

    func applyEstimate(id: String, estimate: FolderBackfillEstimate?, state: FolderEstimateState) {
        guard var current = previews[id] else { return }
        current.estimate = estimate
        current.estimateState = state
        previews[id] = current
    }

    /// Confirm setup or "bring in older files" for one folder.
    /// Transitions to `.on`, records baseline for older files, and enqueues eligible files in span.
    func confirmFolder(id: String, now: Date) -> Bool {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == id }) else { return false }
        guard ledger.folders[idx].kinds.anySelected else { return false }

        let tz = timeZone()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let nowMs = Self.ms(now)
        let nowStamp = ObsidianStamp(milliseconds: nowMs, timeZone: tz)
        let span = ledger.folders[idx].span
        let cutoffMs = span.cutoffMilliseconds(now: now, calendar: calendar)
        let kinds = ledger.folders[idx].kinds
        let rootPath = ledger.folders[idx].path
        let bookmark = ledger.folders[idx].bookmark
        let canonicalRoot = FolderSourceClassify.canonicalPath(rootPath)

        let walk = reader.walk(rootPath: rootPath, bookmark: bookmark)
        switch walk.status {
        case .ok:
            break
        case .missing:
            ledger.folders[idx].attention = .missing
            save()
            return false
        case .accessOff:
            ledger.folders[idx].attention = .accessOff
            save()
            return false
        case .unreadable:
            ledger.folders[idx].attention = .unreadable
            save()
            return false
        }

        ledger.folders[idx].mode = .on
        ledger.folders[idx].returning = true
        ledger.folders[idx].widening = false
        ledger.folders[idx].attention = nil
        ledger.folders[idx].lastCheckedMs = nowMs
        ledger.folders[idx].cantRead = walk.unreadableDirs
        if let cutoffMs {
            if let existing = ledger.folders[idx].spanFromMs {
                ledger.folders[idx].spanFromMs = min(existing, cutoffMs)
            } else {
                ledger.folders[idx].spanFromMs = cutoffMs
            }
        } else {
            ledger.folders[idx].spanFromMs = Int64.min
        }

        var queuedNow = 0
        for file in walk.files {
            if let existing = ledger.folders[idx].files[file.relativePath], existing.deliveredToJournal {
                continue
            }

            let excludedBySpan = (span == .fromToday) || (cutoffMs.map { file.modifiedMs < $0 } ?? false)
            if excludedBySpan {
                // Record as baseline so existing older files aren't ingested unless later edited,
                // and aren't misreported as removed.
                var baselineHash: String?
                var baselineText: String?
                if supported.noteExtensions.contains(file.fileExtension) && file.sizeBytes <= supported.maxNoteBytes {
                    if let read = reader.readAndHash(
                        path: file.absolutePath,
                        canonicalRoot: canonicalRoot,
                        expectedDevice: file.device,
                        expectedInode: file.inode,
                        maxInlineBytes: Int(supported.maxNoteBytes)
                    ) {
                        baselineHash = read.sha256
                        if let data = read.inlineData, !data.contains(0) {
                            baselineText = String(data: data, encoding: .utf8)
                        }
                    }
                }
                ledger.folders[idx].files[file.relativePath] = TrackedFile(
                    relPath: file.relativePath,
                    device: file.device,
                    inode: file.inode,
                    sizeBytes: file.sizeBytes,
                    modifiedMs: file.modifiedMs,
                    createdMs: file.createdMs,
                    fileExtension: file.fileExtension,
                    kind: .other,
                    delivery: .ignore,
                    contentHash: baselineHash,
                    deliveredToJournal: false,
                    excludedBeforeSpan: true,
                    lastSentHash: nil,
                    lastNoteText: baselineText
                )
                continue
            }

            let isImage = supported.isImageExtension(file.fileExtension)
            let (isScreenshot, platform) = reader.readMetadata(path: file.absolutePath, isImage: isImage)

            var noteData: Data?
            var hash: String?
            let isNoteCandidate = supported.noteExtensions.contains(file.fileExtension) && file.sizeBytes <= supported.maxNoteBytes
            if isNoteCandidate {
                if let read = reader.readAndHash(
                    path: file.absolutePath,
                    canonicalRoot: canonicalRoot,
                    expectedDevice: file.device,
                    expectedInode: file.inode,
                    maxInlineBytes: Int(supported.maxNoteBytes)
                ) {
                    noteData = read.inlineData
                    hash = read.sha256
                } else {
                    ledger.folders[idx].cantRead += 1
                    continue
                }
            }

            let (kind, delivery) = FolderSourceClassify.classifyFile(
                extension: file.fileExtension,
                sizeBytes: file.sizeBytes,
                isScreenshot: isScreenshot,
                noteBytes: noteData,
                kinds: kinds,
                supported: supported
            )
            if delivery == .ignore { continue }

            if delivery == .content && hash == nil {
                if let read = reader.readAndHash(
                    path: file.absolutePath,
                    canonicalRoot: canonicalRoot,
                    expectedDevice: file.device,
                    expectedInode: file.inode,
                    maxInlineBytes: nil
                ) {
                    hash = read.sha256
                } else {
                    ledger.folders[idx].cantRead += 1
                    continue
                }
            }

            let noteText: String? = (kind == .notes && delivery == .content)
                ? noteData.flatMap { !$0.contains(0) ? String(data: $0, encoding: .utf8) : nil }
                : nil

            let evMs = min(file.modifiedMs, nowMs)
            let evStamp = ObsidianStamp(milliseconds: evMs, timeZone: tz)
            guard evStamp.isRepresentable else { continue }
            let win = evStamp.window
            let winEndMs = Self.windowEndMilliseconds(stamp: evStamp)
            let isBackfill = winEndMs <= nowMs
            let createdRFC = file.createdMs.flatMap { ms -> String? in
                let s = ObsidianStamp(milliseconds: ms, timeZone: tz)
                return s.isRepresentable ? s.rfc3339 : nil
            }
            let modifiedRFC: String? = {
                let s = ObsidianStamp(milliseconds: file.modifiedMs, timeZone: tz)
                return s.isRepresentable ? s.rfc3339 : nil
            }()

            let evID = Self.eventID(folderID: id, relPath: file.relativePath, verb: .added, ms: evMs)
            ledger.folders[idx].pending.removeAll { $0.relPath == file.relativePath }
            ledger.folders[idx].pending.append(PendingEvent(
                id: evID,
                relPath: file.relativePath,
                previousPath: nil,
                verb: .added,
                kind: kind,
                delivery: delivery,
                eventMs: evMs,
                observedMs: nowMs,
                atRFC3339: evStamp.rfc3339,
                observedRFC3339: nowStamp.rfc3339,
                createdRFC3339: createdRFC,
                modifiedRFC3339: modifiedRFC,
                fileExtension: file.fileExtension.isEmpty ? nil : file.fileExtension,
                sizeBytes: file.sizeBytes,
                window: win,
                windowEndMs: winEndMs,
                contentHash: delivery == .content ? hash : nil,
                inlineNoteText: noteText,
                platform: platform,
                isRevision: false,
                backfill: isBackfill,
                retryAtMs: nil,
                tries: 0
            ))
            ledger.folders[idx].files[file.relativePath] = TrackedFile(
                relPath: file.relativePath,
                device: file.device,
                inode: file.inode,
                sizeBytes: file.sizeBytes,
                modifiedMs: file.modifiedMs,
                createdMs: file.createdMs,
                fileExtension: file.fileExtension,
                kind: kind,
                delivery: delivery,
                contentHash: hash,
                deliveredToJournal: false,
                excludedBeforeSpan: false,
                lastSentHash: nil,
                lastNoteText: nil
            )
            queuedNow += 1
        }

        if queuedNow > 0 {
            ledger.folders[idx].backfillTotal = (ledger.folders[idx].backfillDone) + queuedNow
        }
        previews[id] = nil
        save()
        return true
    }

    // MARK: - Periodic scan (runs for both `on` AND `paused` folders so pause never skips)

    func scanAll(now: Date) {
        let nowMs = Self.ms(now)
        var dirty = false
        for idx in ledger.folders.indices {
            let mode = ledger.folders[idx].mode
            guard mode == .on || mode == .paused else { continue }
            if scanOne(idx: idx, now: now, nowMs: nowMs) {
                dirty = true
            }
        }
        if dirty { save() }
    }

    private func scanOne(idx: Int, now: Date, nowMs: Int64) -> Bool {
        let tz = timeZone()
        let nowStamp = ObsidianStamp(milliseconds: nowMs, timeZone: tz)
        let folderID = ledger.folders[idx].id
        let rootPath = ledger.folders[idx].path
        let bookmark = ledger.folders[idx].bookmark
        let kinds = ledger.folders[idx].kinds
        let canonicalRoot = FolderSourceClassify.canonicalPath(rootPath)

        let walk = reader.walk(rootPath: rootPath, bookmark: bookmark)
        ledger.folders[idx].lastCheckedMs = nowMs

        switch walk.status {
        case .ok:
            if ledger.folders[idx].attention != nil {
                ledger.folders[idx].attention = nil
            }
            ledger.folders[idx].cantRead = walk.unreadableDirs
        case .missing:
            let changed = ledger.folders[idx].attention != .missing
            ledger.folders[idx].attention = .missing
            return changed
        case .accessOff:
            let changed = ledger.folders[idx].attention != .accessOff
            ledger.folders[idx].attention = .accessOff
            return changed
        case .unreadable:
            let changed = ledger.folders[idx].attention != .unreadable
            ledger.folders[idx].attention = .unreadable
            return changed
        }

        var changed = false
        var seenPaths: Set<String> = []
        var newCandidates: [FolderScannedFile] = []
        var modifiedCandidates: [FolderScannedFile] = []

        for file in walk.files {
            seenPaths.insert(file.relativePath)
            // Wait for freshly written files to settle before reading or hashing.
            let modDate = Date(timeIntervalSince1970: Double(file.modifiedMs) / 1000.0)
            guard FolderSyncFiles.hasSettled(modified: modDate, now: now, delay: FolderSourceWireConstants.settleDelaySeconds) else {
                continue
            }
            if let tracked = ledger.folders[idx].files[file.relativePath] {
                if tracked.sizeBytes != file.sizeBytes || tracked.modifiedMs != file.modifiedMs {
                    modifiedCandidates.append(file)
                }
            } else {
                newCandidates.append(file)
            }
        }

        // Only a complete walk may treat disappeared paths as renames or removals, and
        // evicted iCloud files / stubs / partial downloads / unreachable dirs are protected.
        let disappearedPaths: [String]
        if walk.complete {
            disappearedPaths = ledger.folders[idx].files.keys
                .filter { rel in
                    if seenPaths.contains(rel) { return false }
                    if walk.deferredPaths.contains(rel) { return false }
                    if walk.unreachablePrefixes.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { return false }
                    return true
                }
                .sorted()
        } else {
            disappearedPaths = []
        }

        // 1. Match renames first: same (device, inode), or same (sizeBytes, sha256).
        var matchedDisappeared: Set<String> = []
        var remainingNew: [FolderScannedFile] = []
        let disappearedSizes: Set<Int64> = Set(disappearedPaths.compactMap { ledger.folders[idx].files[$0]?.sizeBytes })

        for cand in newCandidates {
            var matchedOld: String?
            // Inode match
            for oldRel in disappearedPaths where !matchedDisappeared.contains(oldRel) {
                if let old = ledger.folders[idx].files[oldRel],
                   old.device == cand.device && old.inode == cand.inode && cand.inode != 0 {
                    matchedOld = oldRel
                    break
                }
            }
            // Content hash fallback match
            if matchedOld == nil && disappearedSizes.contains(cand.sizeBytes) {
                if let read = reader.readAndHash(
                    path: cand.absolutePath,
                    canonicalRoot: canonicalRoot,
                    expectedDevice: cand.device,
                    expectedInode: cand.inode,
                    maxInlineBytes: nil
                ) {
                    for oldRel in disappearedPaths where !matchedDisappeared.contains(oldRel) {
                        if let old = ledger.folders[idx].files[oldRel],
                           old.sizeBytes == cand.sizeBytes,
                           old.contentHash == read.sha256 {
                            matchedOld = oldRel
                            break
                        }
                    }
                }
            }

            if let oldRel = matchedOld, var oldTracked = ledger.folders[idx].files.removeValue(forKey: oldRel) {
                matchedDisappeared.insert(oldRel)
                oldTracked.relPath = cand.relativePath
                oldTracked.device = cand.device
                oldTracked.inode = cand.inode
                oldTracked.sizeBytes = cand.sizeBytes
                oldTracked.modifiedMs = cand.modifiedMs
                oldTracked.fileExtension = cand.fileExtension

                if !oldTracked.deliveredToJournal {
                    // Rename before first send: update waiting event path in place.
                    for pIdx in ledger.folders[idx].pending.indices where ledger.folders[idx].pending[pIdx].relPath == oldRel {
                        ledger.folders[idx].pending[pIdx].relPath = cand.relativePath
                    }
                } else {
                    let isImage = supported.isImageExtension(cand.fileExtension)
                    let (_, platform) = reader.readMetadata(path: cand.absolutePath, isImage: isImage)
                    let evStamp = ObsidianStamp(milliseconds: nowMs, timeZone: tz)
                    let win = evStamp.window
                    let winEndMs = Self.windowEndMilliseconds(stamp: evStamp)
                    let createdRFC = cand.createdMs.flatMap { Self.optionalRFC3339($0, tz: tz) }
                    let modifiedRFC = Self.optionalRFC3339(cand.modifiedMs, tz: tz)
                    ledger.folders[idx].pending.append(PendingEvent(
                        id: Self.eventID(folderID: folderID, relPath: cand.relativePath, verb: .renamed, ms: nowMs),
                        relPath: cand.relativePath,
                        previousPath: oldRel,
                        verb: .renamed,
                        kind: oldTracked.kind,
                        delivery: .metadataOnly,
                        eventMs: nowMs,
                        observedMs: nowMs,
                        atRFC3339: evStamp.rfc3339,
                        observedRFC3339: nowStamp.rfc3339,
                        createdRFC3339: createdRFC,
                        modifiedRFC3339: modifiedRFC,
                        fileExtension: cand.fileExtension.isEmpty ? nil : cand.fileExtension,
                        sizeBytes: cand.sizeBytes,
                        window: win,
                        windowEndMs: winEndMs,
                        contentHash: nil,
                        inlineNoteText: nil,
                        platform: platform
                    ))
                }
                ledger.folders[idx].files[cand.relativePath] = oldTracked
                changed = true
            } else {
                remainingNew.append(cand)
            }
        }

        // 2. Delete-before-send & `removed` events (only when walk.complete == true).
        if walk.complete {
            for oldRel in disappearedPaths where !matchedDisappeared.contains(oldRel) {
                guard let old = ledger.folders[idx].files.removeValue(forKey: oldRel) else { continue }
                if !old.deliveredToJournal {
                    // Delete before send: drop any waiting events; nothing leaves this Mac.
                    ledger.folders[idx].pending.removeAll { $0.relPath == oldRel }
                    changed = true
                } else if !old.excludedBeforeSpan {
                    // Already received by the journal: drop any unsent pending edits/revisions
                    // whose bytes no longer exist on disk, and emit one `removed` activity line.
                    ledger.folders[idx].pending.removeAll { $0.relPath == oldRel && $0.verb != .removed }
                    let evStamp = ObsidianStamp(milliseconds: nowMs, timeZone: tz)
                    let win = evStamp.window
                    let winEndMs = Self.windowEndMilliseconds(stamp: evStamp)
                    ledger.folders[idx].pending.append(PendingEvent(
                        id: Self.eventID(folderID: folderID, relPath: oldRel, verb: .removed, ms: nowMs),
                        relPath: oldRel,
                        previousPath: nil,
                        verb: .removed,
                        kind: old.kind,
                        delivery: .metadataOnly,
                        eventMs: nowMs,
                        observedMs: nowMs,
                        atRFC3339: evStamp.rfc3339,
                        observedRFC3339: nowStamp.rfc3339,
                        createdRFC3339: nil,
                        modifiedRFC3339: evStamp.rfc3339,
                        fileExtension: old.fileExtension.isEmpty ? nil : old.fileExtension,
                        sizeBytes: old.sizeBytes,
                        window: win,
                        windowEndMs: winEndMs,
                        contentHash: nil,
                        inlineNoteText: nil,
                        platform: nil
                    ))
                    changed = true
                }
            }
        }

        // 3. Newly appeared files.
        for file in remainingNew {
            let isImage = supported.isImageExtension(file.fileExtension)
            let (isScreenshot, platform) = reader.readMetadata(path: file.absolutePath, isImage: isImage)

            var noteData: Data?
            var hash: String?
            let isNoteCandidate = supported.noteExtensions.contains(file.fileExtension) && file.sizeBytes <= supported.maxNoteBytes
            if isNoteCandidate {
                if let read = reader.readAndHash(
                    path: file.absolutePath,
                    canonicalRoot: canonicalRoot,
                    expectedDevice: file.device,
                    expectedInode: file.inode,
                    maxInlineBytes: Int(supported.maxNoteBytes)
                ) {
                    noteData = read.inlineData
                    hash = read.sha256
                } else {
                    ledger.folders[idx].cantRead += 1
                    continue
                }
            }

            let (kind, delivery) = FolderSourceClassify.classifyFile(
                extension: file.fileExtension,
                sizeBytes: file.sizeBytes,
                isScreenshot: isScreenshot,
                noteBytes: noteData,
                kinds: kinds,
                supported: supported
            )
            if delivery == .ignore { continue }

            if delivery == .content && hash == nil {
                if let read = reader.readAndHash(
                    path: file.absolutePath,
                    canonicalRoot: canonicalRoot,
                    expectedDevice: file.device,
                    expectedInode: file.inode,
                    maxInlineBytes: nil
                ) {
                    hash = read.sha256
                } else {
                    ledger.folders[idx].cantRead += 1
                    continue
                }
            }

            let noteText: String? = (kind == .notes && delivery == .content)
                ? noteData.flatMap { !$0.contains(0) ? String(data: $0, encoding: .utf8) : nil }
                : nil

            let evMs = min(file.modifiedMs, nowMs)
            let evStamp = ObsidianStamp(milliseconds: evMs, timeZone: tz)
            guard evStamp.isRepresentable else { continue }
            let win = evStamp.window
            let winEndMs = Self.windowEndMilliseconds(stamp: evStamp)

            ledger.folders[idx].pending.append(PendingEvent(
                id: Self.eventID(folderID: folderID, relPath: file.relativePath, verb: .added, ms: evMs),
                relPath: file.relativePath,
                previousPath: nil,
                verb: .added,
                kind: kind,
                delivery: delivery,
                eventMs: evMs,
                observedMs: nowMs,
                atRFC3339: evStamp.rfc3339,
                observedRFC3339: nowStamp.rfc3339,
                createdRFC3339: file.createdMs.flatMap { Self.optionalRFC3339($0, tz: tz) },
                modifiedRFC3339: Self.optionalRFC3339(file.modifiedMs, tz: tz),
                fileExtension: file.fileExtension.isEmpty ? nil : file.fileExtension,
                sizeBytes: file.sizeBytes,
                window: win,
                windowEndMs: winEndMs,
                contentHash: delivery == .content ? hash : nil,
                inlineNoteText: noteText,
                platform: platform
            ))
            ledger.folders[idx].files[file.relativePath] = TrackedFile(
                relPath: file.relativePath,
                device: file.device,
                inode: file.inode,
                sizeBytes: file.sizeBytes,
                modifiedMs: file.modifiedMs,
                createdMs: file.createdMs,
                fileExtension: file.fileExtension,
                kind: kind,
                delivery: delivery,
                contentHash: hash,
                deliveredToJournal: false,
                excludedBeforeSpan: false,
                lastSentHash: nil,
                lastNoteText: nil
            )
            changed = true
        }

        // 4. Modified files: notes coalesce in five-minute window (with revert suppression);
        // already-delivered documents/transcripts enter/reset the one-hour revision cool-down.
        for file in modifiedCandidates {
            let isImage = supported.isImageExtension(file.fileExtension)
            let (isScreenshot, platform) = reader.readMetadata(path: file.absolutePath, isImage: isImage)

            var noteData: Data?
            var newHash: String?
            let isNoteCandidate = supported.noteExtensions.contains(file.fileExtension) && file.sizeBytes <= supported.maxNoteBytes
            if isNoteCandidate {
                if let read = reader.readAndHash(
                    path: file.absolutePath,
                    canonicalRoot: canonicalRoot,
                    expectedDevice: file.device,
                    expectedInode: file.inode,
                    maxInlineBytes: Int(supported.maxNoteBytes)
                ) {
                    noteData = read.inlineData
                    newHash = read.sha256
                } else {
                    ledger.folders[idx].cantRead += 1
                    continue
                }
            }

            let (kind, rawDelivery) = FolderSourceClassify.classifyFile(
                extension: file.fileExtension,
                sizeBytes: file.sizeBytes,
                isScreenshot: isScreenshot,
                noteBytes: noteData,
                kinds: kinds,
                supported: supported
            )
            if rawDelivery == .ignore { continue }

            if rawDelivery == .content && newHash == nil {
                if let read = reader.readAndHash(
                    path: file.absolutePath,
                    canonicalRoot: canonicalRoot,
                    expectedDevice: file.device,
                    expectedInode: file.inode,
                    maxInlineBytes: nil
                ) {
                    newHash = read.sha256
                } else {
                    ledger.folders[idx].cantRead += 1
                    continue
                }
            }

            guard var tracked = ledger.folders[idx].files[file.relativePath] else { continue }
            tracked.device = file.device
            tracked.inode = file.inode
            tracked.sizeBytes = file.sizeBytes
            tracked.modifiedMs = file.modifiedMs
            tracked.fileExtension = file.fileExtension
            tracked.kind = kind

            // Do not re-send previously refused bytes unless file bytes actually changed.
            let delivery: FolderDeliveryMode
            if rawDelivery == .content, let newHash, tracked.refusedContentHash == newHash {
                delivery = kinds.other ? .metadataOnly : .ignore
            } else {
                delivery = rawDelivery
                if let newHash, tracked.refusedContentHash != newHash {
                    tracked.refusedContentHash = nil
                }
            }
            if delivery == .ignore {
                ledger.folders[idx].files[file.relativePath] = tracked
                continue
            }
            tracked.delivery = delivery
            tracked.excludedBeforeSpan = false

            if let newHash, newHash == tracked.contentHash {
                // Metadata-only touch with identical bytes: no duplicate send.
                ledger.folders[idx].files[file.relativePath] = tracked
                continue
            }
            tracked.contentHash = newHash

            let evMs = min(file.modifiedMs, nowMs)
            let evStamp = ObsidianStamp(milliseconds: evMs, timeZone: tz)
            guard evStamp.isRepresentable else {
                ledger.folders[idx].files[file.relativePath] = tracked
                continue
            }
            let win = evStamp.window
            let winEndMs = Self.windowEndMilliseconds(stamp: evStamp)

            switch (kind, delivery, tracked.deliveredToJournal) {
            case (.notes, .content, _):
                let currentText = noteData.flatMap { !$0.contains(0) ? String(data: $0, encoding: .utf8) : nil }
                let verb: FolderActivityVerb
                if let baseline = tracked.lastNoteText, let after = currentText {
                    if FolderSourceClassify.netLineDiff(before: baseline, after: after) == nil {
                        // Reverted back to baseline before window closed: drop pending edit.
                        ledger.folders[idx].pending.removeAll { $0.relPath == file.relativePath && $0.window == win }
                        ledger.folders[idx].files[file.relativePath] = tracked
                        changed = true
                        continue
                    }
                    verb = .edited
                } else {
                    verb = tracked.deliveredToJournal ? .edited : .added
                }
                // Coalesce rapid note edits into this five-minute window; send full current note bytes.
                ledger.folders[idx].pending.removeAll { $0.relPath == file.relativePath && $0.window == win }
                ledger.folders[idx].pending.append(PendingEvent(
                    id: Self.eventID(folderID: folderID, relPath: file.relativePath, verb: verb, ms: evMs),
                    relPath: file.relativePath,
                    previousPath: nil,
                    verb: verb,
                    kind: .notes,
                    delivery: .content,
                    eventMs: evMs,
                    observedMs: nowMs,
                    atRFC3339: evStamp.rfc3339,
                    observedRFC3339: nowStamp.rfc3339,
                    createdRFC3339: file.createdMs.flatMap { Self.optionalRFC3339($0, tz: tz) },
                    modifiedRFC3339: Self.optionalRFC3339(file.modifiedMs, tz: tz),
                    fileExtension: file.fileExtension.isEmpty ? nil : file.fileExtension,
                    sizeBytes: file.sizeBytes,
                    window: win,
                    windowEndMs: winEndMs,
                    contentHash: newHash,
                    inlineNoteText: currentText,
                    platform: platform
                ))
                ledger.folders[idx].files[file.relativePath] = tracked
                changed = true

            case (.documents, .content, true), (.transcripts, .content, true):
                // Already sent once: start or reset the one-hour revision cool-down.
                // Also drop any stale unsent revision queued earlier so the newer save wins.
                if newHash != tracked.lastSentHash {
                    ledger.folders[idx].pending.removeAll { $0.relPath == file.relativePath && $0.isRevision }
                    tracked.pendingRevisionSaveMs = evMs
                    tracked.pendingRevisionHash = newHash
                    changed = true
                }
                ledger.folders[idx].files[file.relativePath] = tracked

            case (.documents, .content, false), (.transcripts, .content, false):
                // Not yet delivered: refresh its waiting upload in place.
                ledger.folders[idx].pending.removeAll { $0.relPath == file.relativePath }
                ledger.folders[idx].pending.append(PendingEvent(
                    id: Self.eventID(folderID: folderID, relPath: file.relativePath, verb: .added, ms: evMs),
                    relPath: file.relativePath,
                    previousPath: nil,
                    verb: .added,
                    kind: kind,
                    delivery: .content,
                    eventMs: evMs,
                    observedMs: nowMs,
                    atRFC3339: evStamp.rfc3339,
                    observedRFC3339: nowStamp.rfc3339,
                    createdRFC3339: file.createdMs.flatMap { Self.optionalRFC3339($0, tz: tz) },
                    modifiedRFC3339: Self.optionalRFC3339(file.modifiedMs, tz: tz),
                    fileExtension: file.fileExtension.isEmpty ? nil : file.fileExtension,
                    sizeBytes: file.sizeBytes,
                    window: win,
                    windowEndMs: winEndMs,
                    contentHash: newHash,
                    inlineNoteText: nil,
                    platform: platform
                ))
                ledger.folders[idx].files[file.relativePath] = tracked
                changed = true

            case (_, .metadataOnly, _):
                ledger.folders[idx].pending.removeAll { $0.relPath == file.relativePath && $0.window == win }
                ledger.folders[idx].pending.append(PendingEvent(
                    id: Self.eventID(folderID: folderID, relPath: file.relativePath, verb: .edited, ms: evMs),
                    relPath: file.relativePath,
                    previousPath: nil,
                    verb: .edited,
                    kind: kind,
                    delivery: .metadataOnly,
                    eventMs: evMs,
                    observedMs: nowMs,
                    atRFC3339: evStamp.rfc3339,
                    observedRFC3339: nowStamp.rfc3339,
                    createdRFC3339: file.createdMs.flatMap { Self.optionalRFC3339($0, tz: tz) },
                    modifiedRFC3339: Self.optionalRFC3339(file.modifiedMs, tz: tz),
                    fileExtension: file.fileExtension.isEmpty ? nil : file.fileExtension,
                    sizeBytes: file.sizeBytes,
                    window: win,
                    windowEndMs: winEndMs,
                    contentHash: nil,
                    inlineNoteText: nil,
                    platform: platform
                ))
                ledger.folders[idx].files[file.relativePath] = tracked
                changed = true

            default:
                ledger.folders[idx].files[file.relativePath] = tracked
            }
        }

        // 5. Check one-hour revision cool-down across tracked documents & transcripts.
        let revWaitMs = supported.documentRevisionCooldownMs
        let dueKeys = ledger.folders[idx].files.keys.sorted().filter { key in
            guard let t = ledger.folders[idx].files[key], let saveMs = t.pendingRevisionSaveMs else {
                return false
            }
            return nowMs - saveMs >= revWaitMs
        }

        for relPath in dueKeys {
            guard var tracked = ledger.folders[idx].files[relPath],
                  let saveMs = tracked.pendingRevisionSaveMs else { continue }
            let absPath = (rootPath as NSString).appendingPathComponent(relPath)
            guard let probe = reader.probeFile(path: absPath, rootPath: rootPath, bookmark: bookmark),
                  (probe.isRegular || probe.isSymlink), !probe.isDataless else {
                continue
            }
            let (_, platform) = reader.readMetadata(path: absPath, isImage: false)
            let evStamp = ObsidianStamp(milliseconds: saveMs, timeZone: tz)
            guard evStamp.isRepresentable else { continue }
            let win = evStamp.window
            let winEndMs = Self.windowEndMilliseconds(stamp: evStamp)

            ledger.folders[idx].pending.append(PendingEvent(
                id: Self.eventID(folderID: folderID, relPath: relPath, verb: .revised, ms: saveMs),
                relPath: relPath,
                previousPath: nil,
                verb: .revised,
                kind: tracked.kind,
                delivery: .content,
                eventMs: saveMs,
                observedMs: nowMs,
                atRFC3339: evStamp.rfc3339,
                observedRFC3339: nowStamp.rfc3339,
                createdRFC3339: tracked.createdMs.flatMap { Self.optionalRFC3339($0, tz: tz) },
                modifiedRFC3339: Self.optionalRFC3339(tracked.modifiedMs, tz: tz),
                fileExtension: tracked.fileExtension.isEmpty ? nil : tracked.fileExtension,
                sizeBytes: tracked.sizeBytes,
                window: win,
                windowEndMs: winEndMs,
                contentHash: tracked.pendingRevisionHash ?? tracked.contentHash,
                inlineNoteText: nil,
                platform: platform,
                isRevision: true
            ))
            tracked.pendingRevisionSaveMs = nil
            tracked.pendingRevisionHash = nil
            ledger.folders[idx].files[relPath] = tracked
            changed = true
        }

        return changed
    }

    // MARK: - Delivery selection & answer handling

    /// Pick the next closed, due five-minute segment across all `.on` folders (newest window first).
    /// Iterates candidate windows so an evicted/dataless file in one window cannot head-of-line block
    /// older windows or other folders. Returns `nil` while the whole Mac is paused or nothing is ready.
    func nextDelivery(now: Date, ownerPaused: Bool) -> FolderSegmentUpload? {
        guard !ownerPaused else { return nil }
        let nowMs = Self.ms(now)

        struct CandidateWindow: Hashable {
            let idx: Int
            let window: ObsidianWindow
        }

        var candidateSet: Set<CandidateWindow> = []
        for (idx, folder) in ledger.folders.enumerated() {
            guard folder.mode == .on, folder.attention == nil else { continue }
            for ev in folder.pending {
                guard ev.windowEndMs <= nowMs else { continue }
                if let retry = ev.retryAtMs, retry > nowMs { continue }
                candidateSet.insert(CandidateWindow(idx: idx, window: ev.window))
            }
        }

        let orderedCandidates = candidateSet.sorted { lhs, rhs in
            if lhs.window != rhs.window { return lhs.window > rhs.window }
            return lhs.idx < rhs.idx
        }

        var mutated = false
        for candidate in orderedCandidates {
            let idx = candidate.idx
            let targetWindow = candidate.window
            let rootPath = ledger.folders[idx].path
            let bookmark = ledger.folders[idx].bookmark
            let canonicalRoot = FolderSourceClassify.canonicalPath(rootPath)

            let windowEvents = ledger.folders[idx].pending
                .filter { $0.window == targetWindow && $0.windowEndMs <= nowMs && ($0.retryAtMs ?? Int64.min) <= nowMs }
                .sorted { lhs, rhs in
                    if lhs.eventMs != rhs.eventMs { return lhs.eventMs < rhs.eventMs }
                    return lhs.relPath < rhs.relPath
                }

            var items: [FolderSegmentUpload.Item] = []
            var droppedIDs: Set<String> = []
            var droppedFilePaths: Set<String> = []
            var partCount = 0
            var chunkBytes: Int64 = 0

            for ev in windowEvents {
                guard items.count < FolderSourceWireConstants.maxFileLines else { break }

                if ev.delivery == .content && ev.verb != .removed {
                    if partCount >= FolderSourceWireConstants.maxCompanionParts { continue }
                    let estimatedSize = max(0, ev.sizeBytes ?? 0)
                    if partCount > 0 && chunkBytes + estimatedSize > FolderSourceWireConstants.maxChunkPayloadBytes {
                        continue
                    }
                    let absPath = (rootPath as NSString).appendingPathComponent(ev.relPath)
                    let probe = reader.probeFile(path: absPath, rootPath: rootPath, bookmark: bookmark)
                    let exists = probe.map { $0.isRegular || $0.isSymlink } ?? false
                    if !exists {
                        let wasDelivered = ledger.folders[idx].files[ev.relPath]?.deliveredToJournal == true
                        if !wasDelivered {
                            // Delete-before-send right before upload!
                            droppedIDs.insert(ev.id)
                            droppedFilePaths.insert(ev.relPath)
                            continue
                        }
                        if ev.inlineNoteText == nil {
                            // Already-delivered file vanished on disk before its revision uploaded.
                            droppedIDs.insert(ev.id)
                            continue
                        }
                    }
                    if probe?.isDataless == true {
                        // File was evicted to iCloud while waiting: leave queued without hydrating.
                        continue
                    }
                    let ext = (ev.fileExtension ?? "").lowercased()
                    let convert = (ev.kind == .screenshots || ev.kind == .photos) && supported.needsPNGConversion(ext)
                    partCount += 1
                    chunkBytes += estimatedSize
                    items.append(FolderSegmentUpload.Item(
                        eventID: ev.id,
                        verb: ev.verb,
                        path: ev.relPath,
                        previousPath: ev.previousPath,
                        at: ev.atRFC3339,
                        observedAt: ev.observedRFC3339,
                        fileType: ev.fileExtension,
                        sizeBytes: ev.sizeBytes,
                        createdAt: ev.createdRFC3339,
                        modifiedAt: ev.modifiedRFC3339,
                        kindHint: ev.kind.kindHint,
                        platform: ev.platform,
                        sourcePath: absPath,
                        canonicalRoot: canonicalRoot,
                        expectedSHA256: ev.contentHash,
                        inlineNoteData: ev.inlineNoteText.map { Data($0.utf8) },
                        convertToPNG: convert
                    ))
                } else {
                    items.append(FolderSegmentUpload.Item(
                        eventID: ev.id,
                        verb: ev.verb,
                        path: ev.relPath,
                        previousPath: ev.previousPath,
                        at: ev.atRFC3339,
                        observedAt: ev.observedRFC3339,
                        fileType: ev.fileExtension,
                        sizeBytes: ev.sizeBytes,
                        createdAt: ev.createdRFC3339,
                        modifiedAt: ev.modifiedRFC3339,
                        kindHint: nil,
                        platform: ev.platform,
                        sourcePath: nil,
                        canonicalRoot: nil,
                        expectedSHA256: nil,
                        convertToPNG: false
                    ))
                }
            }

            if !droppedIDs.isEmpty {
                ledger.folders[idx].pending.removeAll { droppedIDs.contains($0.id) }
                for path in droppedFilePaths {
                    ledger.folders[idx].files.removeValue(forKey: path)
                }
                mutated = true
            }

            if !items.isEmpty {
                if mutated { save() }
                let folder = ledger.folders[idx]
                return FolderSegmentUpload(
                    folderID: folder.id,
                    folderName: folder.name,
                    facet: folder.facet,
                    kinds: folder.kinds,
                    day: targetWindow.day,
                    segment: targetWindow.segment,
                    items: items
                )
            }
        }

        if mutated { save() }
        return nil
    }

    /// Record the journal's answer for one delivered segment chunk.
    func recordAnswer(_ answer: FolderDeliveryAnswer, for upload: FolderSegmentUpload, now: Date) async {
        guard let idx = ledger.folders.firstIndex(where: { $0.id == upload.folderID }) else { return }
        let nowMs = Self.ms(now)
        let uploadedIDs = Set(upload.items.map(\.eventID))

        switch answer {
        case .delivered(let localFallback):
            applyDelivered(idx: idx, uploadedIDs: uploadedIDs, serverRefused: [], localFallback: Set(localFallback), nowMs: nowMs)
            save()
            await onDelivered()

        case .deliveredWithRefused(let serverRefused, let localFallback):
            applyDelivered(idx: idx, uploadedIDs: uploadedIDs, serverRefused: Set(serverRefused), localFallback: Set(localFallback), nowMs: nowMs)
            save()
            await onDelivered()

        case .allFilesRefused(let refusedPaths):
            let refused = Set(refusedPaths)
            let targets = refused.isEmpty ? Set(upload.items.map(\.path)) : refused
            degradeToDetailsOnly(idx: idx, uploadedIDs: uploadedIDs, refusedPaths: targets)
            save()

        case .invalid:
            ledger.folders[idx].pending.removeAll { uploadedIDs.contains($0.id) }
            save()

        case .ahead, .retry:
            for pIdx in ledger.folders[idx].pending.indices where uploadedIDs.contains(ledger.folders[idx].pending[pIdx].id) {
                let tries = ledger.folders[idx].pending[pIdx].tries
                let delay = Self.retryDelaysMs[min(tries, Self.retryDelaysMs.count - 1)]
                ledger.folders[idx].pending[pIdx].tries = tries + 1
                ledger.folders[idx].pending[pIdx].retryAtMs = nowMs + delay
            }
            save()
        }
    }

    private func applyDelivered(
        idx: Int,
        uploadedIDs: Set<String>,
        serverRefused: Set<String>,
        localFallback: Set<String>,
        nowMs: Int64
    ) {
        let folderID = ledger.folders[idx].id
        var remaining: [PendingEvent] = []
        var deliveredCount = 0
        var backfillCount = 0

        for var ev in ledger.folders[idx].pending {
            guard uploadedIDs.contains(ev.id) else {
                remaining.append(ev)
                continue
            }
            if serverRefused.contains(ev.relPath) {
                // Journal refused this file's bytes; never resend them unless changed on disk.
                // Count `fallbackToDetails` only once the re-queued details-only line actually lands.
                if let badHash = ev.contentHash {
                    ledger.folders[idx].files[ev.relPath]?.refusedContentHash = badHash
                }
                if ledger.folders[idx].kinds.other {
                    ev.delivery = .metadataOnly
                    ev.contentHash = nil
                    ev.inlineNoteText = nil
                    ev.isFallbackDetailsOnly = true
                    ev.retryAtMs = nil
                    ev.tries = 0
                    remaining.append(ev)
                }
                continue
            }

            if ev.isFallbackDetailsOnly || localFallback.contains(ev.relPath) {
                if let badHash = ev.contentHash {
                    ledger.folders[idx].files[ev.relPath]?.refusedContentHash = badHash
                }
                ledger.folders[idx].fallbackToDetails += 1
            }

            deliveredCount += 1
            if ev.backfill { backfillCount += 1 }
            if ev.verb != .removed {
                ledger.folders[idx].files[ev.relPath]?.deliveredToJournal = true
                if let hash = ev.contentHash, !localFallback.contains(ev.relPath) {
                    ledger.folders[idx].files[ev.relPath]?.lastSentHash = hash
                }
                if let text = ev.inlineNoteText {
                    ledger.folders[idx].files[ev.relPath]?.lastNoteText = text
                }
            }
            _ = totals?.applyFolderItem(id: "\(folderID):\(ev.id)")
        }

        ledger.folders[idx].pending = remaining
        if deliveredCount > 0 {
            ledger.folders[idx].deliveredTotal += deliveredCount
            ledger.folders[idx].lastAddedMs = nowMs
        }
        if backfillCount > 0 {
            ledger.folders[idx].backfillDone += backfillCount
        }
        if let total = ledger.folders[idx].backfillTotal, ledger.folders[idx].backfillDone >= total {
            ledger.folders[idx].backfillTotal = nil
            ledger.folders[idx].backfillDone = 0
        }
    }

    private func degradeToDetailsOnly(idx: Int, uploadedIDs: Set<String>, refusedPaths: Set<String>) {
        var remaining: [PendingEvent] = []
        for var ev in ledger.folders[idx].pending {
            guard uploadedIDs.contains(ev.id) else {
                remaining.append(ev)
                continue
            }
            if refusedPaths.contains(ev.relPath) {
                if let badHash = ev.contentHash {
                    ledger.folders[idx].files[ev.relPath]?.refusedContentHash = badHash
                }
                if ledger.folders[idx].kinds.other {
                    ev.delivery = .metadataOnly
                    ev.contentHash = nil
                    ev.inlineNoteText = nil
                    ev.isFallbackDetailsOnly = true
                    ev.retryAtMs = nil
                    ev.tries = 0
                    remaining.append(ev)
                }
            } else {
                remaining.append(ev)
            }
        }
        ledger.folders[idx].pending = remaining
    }

    // MARK: - Snapshots

    func snapshot(
        paired: Bool,
        ownerPaused: Bool,
        journalNeedsUpdate: Bool,
        facets: [FolderFacet],
        facetsState: FolderFacetsState
    ) -> FoldersSnapshot {
        let home = reader.homePath()
        let summaries: [FolderSummary] = ledger.folders.map { f in
            let state: DeckStateWord
            if f.attention != nil {
                state = .needsAttention
            } else if f.mode == .settingUp {
                state = .settingUp
            } else if f.mode == .off {
                state = .off
            } else if f.mode == .paused || ownerPaused {
                state = .paused
            } else {
                state = .on
            }
            let preview = previews[f.id] ?? FolderPreviewSummary(span: f.span)
            return FolderSummary(
                id: f.id,
                name: f.name,
                path: f.path,
                displayPath: FolderSourceClassify.displayPath(f.path, homePath: home),
                mode: f.mode,
                state: state,
                attention: f.attention,
                kinds: f.kinds,
                facet: f.facet,
                span: f.span,
                returning: f.returning,
                widening: f.widening,
                overlap: f.overlap,
                preview: preview,
                backfillDone: f.backfillDone,
                backfillTotal: f.backfillTotal,
                waiting: f.pending.count,
                deliveredTotal: f.deliveredTotal,
                lastAddedAt: f.lastAddedMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) },
                lastCheckedAt: f.lastCheckedMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) },
                cantRead: f.cantRead,
                fallbackToDetails: f.fallbackToDetails,
                pausedByMac: f.mode == .on && ownerPaused && f.attention == nil
            )
        }
        let busy = ledger.folders.contains { f in
            f.mode == .on && f.attention == nil && !f.pending.isEmpty
        }
        return FoldersSnapshot.compose(
            folders: summaries,
            paired: paired,
            ownerPaused: ownerPaused,
            journalNeedsUpdate: journalNeedsUpdate,
            facets: facets,
            facetsState: facetsState,
            busy: busy
        )
    }

    func folderPaths() -> [(id: String, path: String, name: String)] {
        ledger.folders.map { ($0.id, $0.path, $0.name) }
    }

    func hasPendingUploads() -> Bool {
        ledger.folders.contains { $0.mode == .on && $0.attention == nil && !$0.pending.isEmpty }
    }

    // MARK: - Persistence & helpers

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ledger) else { return }
        let temp = directory.appendingPathComponent(".ledger.\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                _ = try FileManager.default.replaceItemAt(ledgerURL, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: ledgerURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000.0).rounded(.towardZero))
    }

    private static func optionalRFC3339(_ ms: Int64, tz: TimeZone) -> String? {
        let stamp = ObsidianStamp(milliseconds: ms, timeZone: tz)
        return stamp.isRepresentable ? stamp.rfc3339 : nil
    }

    private static func windowEndMilliseconds(stamp: ObsidianStamp) -> Int64 {
        let windowSecs = FolderSourceWireConstants.windowSeconds
        let localWallSec = stamp.epochSeconds + Int64(stamp.offsetSeconds)
        let rem = ((localWallSec % windowSecs) + windowSecs) % windowSecs
        let endEpochSec = stamp.epochSeconds + (windowSecs - rem)
        return endEpochSec * 1000
    }

    private static func eventID(folderID: String, relPath: String, verb: FolderActivityVerb, ms: Int64) -> String {
        let seed = "\(folderID)|\(relPath)|\(verb.rawValue)|\(ms)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
