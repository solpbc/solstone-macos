// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Wire and framing constants for the folder source (Protocol v3).
enum FolderSourceWireConstants {
    static let source = "folder"
    static let capability = "folder"
    static let filePrefix = "folder_"
    static let fileSuffix = ".jsonl"
    static let windowSeconds: Int64 = 300
    static let maxFileLines = 5_000
    static let maxFileBytes = 8 * 1024 * 1024
    static let maxCompanionParts = 63
    /// Keep each multipart upload safely beneath the 128 MiB connection body ceiling.
    static let maxChunkPayloadBytes: Int64 = 96 * 1024 * 1024
    static let maxContentBytes: Int64 = 64 * 1024 * 1024
    static let maxNoteBytes: Int64 = 4 * 1024 * 1024
    static let maxImagePixels: Int64 = 64 * 1024 * 1024
    static let defaultDocumentRevisionCooldownMs: Int64 = 60 * 60 * 1000
    static let maxPathBytes = 1_024
    static let maxFolderNameBytes = 128
    static let maxFolderIDBytes = 64
    static let maxEstimateItems = 50_000
    static let maxPlatformStringBytes = 2_048
    static let maxWhereFroms = 16
    static let maxXattrs = 32
    static let settleDelaySeconds: TimeInterval = 2
}

/// Owner-chosen file kinds for one configured folder. All six default on.
struct FolderKinds: Codable, Equatable, Sendable {
    var notes: Bool = true
    var documents: Bool = true
    var transcripts: Bool = true
    var screenshots: Bool = true
    var photos: Bool = true
    var other: Bool = true

    static let allOn = FolderKinds()

    var anySelected: Bool {
        notes || documents || transcripts || screenshots || photos || other
    }

    func includes(_ kind: FolderFileKind) -> Bool {
        switch kind {
        case .notes: return notes
        case .documents: return documents
        case .transcripts: return transcripts
        case .screenshots: return screenshots
        case .photos: return photos
        case .other: return other
        }
    }

    /// Wire `meta.folder.kinds` values in stable order.
    var wireNames: [String] {
        var out: [String] = []
        if notes { out.append("notes") }
        if documents { out.append("documents") }
        if transcripts { out.append("transcripts") }
        if screenshots { out.append("screenshots") }
        if photos { out.append("photos") }
        if other { out.append("other") }
        return out
    }
}

/// Deterministic kind assigned to a file on this Mac.
enum FolderFileKind: String, Codable, Equatable, Sendable, CaseIterable {
    case notes
    case documents
    case transcripts
    case screenshots
    case photos
    case other

    /// Wire `kind_hint` sent on folder activity lines and estimate items.
    var kindHint: String? {
        switch self {
        case .notes: return "notes"
        case .documents: return "documents"
        case .transcripts: return "transcripts"
        case .screenshots: return "screenshots"
        case .photos: return "photos"
        case .other: return nil
        }
    }
}

/// Whether a file's bytes leave this Mac, only its details go, or it is skipped.
enum FolderDeliveryMode: String, Codable, Equatable, Sendable {
    case content
    case metadataOnly
    case ignore
}

/// Activity verb recorded for a file event inside a five-minute window.
enum FolderActivityVerb: String, Codable, Equatable, Sendable {
    case added
    case edited
    case revised
    case renamed
    case removed

    /// Wire `event` string for Protocol v3 folder activity JSONL.
    var wireEvent: String {
        switch self {
        case .added: return "added"
        case .edited, .revised: return "changed"
        case .renamed: return "renamed"
        case .removed: return "removed"
        }
    }
}

/// Lifecycle mode of one configured folder.
enum FolderMode: String, Codable, Equatable, Sendable {
    /// Picked, not yet confirmed. Nothing leaves this Mac.
    case settingUp
    /// Active: watches and sends five-minute segments.
    case on
    /// Paused individually: keeps scanning local changes and holds delivery until resumed.
    case paused
    /// Turned off: stops watching; what is already in the journal stays.
    case off
}

/// Fatal folder-level condition that puts a folder into `needs attention`.
enum FolderAttention: String, Codable, Equatable, Sendable {
    case missing
    case accessOff
    case unreadable
}

/// How far back to bring in existing files when setting up or widening a folder.
enum FolderSpan: String, Codable, Equatable, Sendable, CaseIterable {
    case last30Days
    case last6Months
    case lastYear
    case allOfIt
    case fromToday

    var label: String {
        switch self {
        case .last30Days: return ScreenshotCopy.last30Days
        case .last6Months: return ScreenshotCopy.last6Months
        case .lastYear: return ScreenshotCopy.lastYear
        case .allOfIt: return ScreenshotCopy.allOfIt
        case .fromToday: return ScreenshotCopy.nothingFromBeforeToday
        }
    }

    func cutoffMilliseconds(now: Date, calendar: Calendar = .current) -> Int64? {
        let startOfToday = calendar.startOfDay(for: now)
        let cutoff: Date?
        switch self {
        case .last30Days:
            cutoff = calendar.date(byAdding: .day, value: -30, to: startOfToday)
        case .last6Months:
            cutoff = calendar.date(byAdding: .month, value: -6, to: startOfToday)
        case .lastYear:
            cutoff = calendar.date(byAdding: .year, value: -1, to: startOfToday)
        case .allOfIt:
            return nil
        case .fromToday:
            cutoff = startOfToday
        }
        return cutoff.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.towardZero)) }
    }
}

/// Existing source that overlaps a candidate folder path.
struct FolderOverlapInfo: Codable, Equatable, Sendable {
    enum TargetKind: String, Codable, Equatable, Sendable {
        case obsidian
        case screenshots
        case folder
    }

    var targetKind: TargetKind
    var targetName: String
    var targetFolderID: String?

    var displayTarget: String {
        switch targetKind {
        case .obsidian: return FolderSourceCopy.overlapObsidian(targetName)
        case .screenshots: return FolderSourceCopy.overlapScreenshots(targetName)
        case .folder: return FolderSourceCopy.overlapFolder(targetName)
        }
    }
}

/// Result of checking a chosen folder path before setup begins.
enum FolderPickOutcome: Equatable, Sendable {
    case added(id: String)
    case alreadyAdded(id: String, name: String)
    case needsOverlapConfirmation(path: String, name: String, overlap: FolderOverlapInfo)
    case refusedLocal
    case refusedStorageProvider
}

/// One facet available on the paired journal.
struct FolderFacet: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var title: String
    var color: String?
}

/// Availability of the journal's facet list.
enum FolderFacetsState: Equatable, Sendable {
    case ready
    case unpaired
    case offline
    case needsJournalUpdate
}

/// Availability of the journal's backfill estimate during preview.
enum FolderEstimateState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unpaired
    case offline
    case needsJournalUpdate
}

/// Supported file-type table published by `GET /app/devices/ingest/folder/supported`,
/// with ruleset v8 defaults used until the paired journal answers.
struct FolderSupportedList: Codable, Equatable, Sendable {
    var rulesetVersion: Int = 8
    var windowSeconds: Int64 = FolderSourceWireConstants.windowSeconds
    var maxContentBytes: Int64 = FolderSourceWireConstants.maxContentBytes
    var maxNoteBytes: Int64 = FolderSourceWireConstants.maxNoteBytes
    var maxImagePixels: Int64 = FolderSourceWireConstants.maxImagePixels
    var documentRevisionCooldownMs: Int64 = FolderSourceWireConstants.defaultDocumentRevisionCooldownMs
    var structuredProseMinWords: Int = 1_500
    var structuredProseMinHeadingLevels: Int = 2
    var longProseMinWords: Int = 5_000
    var noteExtensions: Set<String> = ["md", "markdown", "txt", "log"]
    var documentExtensions: Set<String> = ["pdf"]
    var transcriptExtensions: Set<String> = ["vtt", "srt"]
    var acceptedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    var convertibleImageExtensions: Set<String> = ["heic", "heif", "tif", "tiff", "gif", "bmp"]
    var fromJournal: Bool = false

    static let defaults = FolderSupportedList()

    func isImageExtension(_ ext: String) -> Bool {
        acceptedImageExtensions.contains(ext) || convertibleImageExtensions.contains(ext)
    }

    func needsPNGConversion(_ ext: String) -> Bool {
        convertibleImageExtensions.contains(ext)
    }
}

/// One item sent to `POST /app/devices/ingest/folder/estimate`.
struct FolderEstimateItem: Encodable, Equatable, Sendable {
    let path: String
    let at: String
    let fileType: String?
    let kindHint: String?
    let contentHash: String?
    let hasContent: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case at
        case fileType = "file_type"
        case kindHint = "kind_hint"
        case contentHash = "content_hash"
        case hasContent = "has_content"
    }
}

struct FolderEstimateRequest: Encodable, Equatable, Sendable {
    let folderID: String
    let items: [FolderEstimateItem]

    enum CodingKeys: String, CodingKey {
        case folderID = "folder_id"
        case items
    }
}

/// Non-money backfill work estimate returned by the journal (segments, days, thoughts).
struct FolderBackfillEstimate: Codable, Equatable, Sendable {
    var items: Int
    var contentItems: Int
    var activityOnlyItems: Int
    var alreadyInJournal: Int
    var segments: Int
    var contentSegments: Int
    var activityOnlySegments: Int
    var days: Int
    var thoughts: Int
    var backfillPaused: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case contentItems = "content_items"
        case activityOnlyItems = "activity_only_items"
        case alreadyInJournal = "already_in_journal"
        case segments
        case contentSegments = "content_segments"
        case activityOnlySegments = "activity_only_segments"
        case days
        case thoughts
        case backfillPaused = "backfill_paused"
    }

    init(
        items: Int = 0,
        contentItems: Int = 0,
        activityOnlyItems: Int = 0,
        alreadyInJournal: Int = 0,
        segments: Int = 0,
        contentSegments: Int = 0,
        activityOnlySegments: Int = 0,
        days: Int = 0,
        thoughts: Int = 0,
        backfillPaused: Bool = false
    ) {
        self.items = items
        self.contentItems = contentItems
        self.activityOnlyItems = activityOnlyItems
        self.alreadyInJournal = alreadyInJournal
        self.segments = segments
        self.contentSegments = contentSegments
        self.activityOnlySegments = activityOnlySegments
        self.days = days
        self.thoughts = thoughts
        self.backfillPaused = backfillPaused
    }
}

/// Preview counts, date range, and optional journal estimate shown before confirmation.
struct FolderPreviewSummary: Equatable, Sendable {
    var span: FolderSpan = .last30Days
    var totalItems: Int = 0
    var contentItems: Int = 0
    var contentBytes: Int64 = 0
    var metadataOnlyItems: Int = 0
    var earliestMs: Int64?
    var latestMs: Int64?
    var unreadable: Int = 0
    var scanFailed: Bool = false
    var scanning: Bool = false
    var estimate: FolderBackfillEstimate?
    var estimateState: FolderEstimateState = .idle
}

/// Optional platform provenance metadata carried on Protocol v3 folder activity lines.
struct FolderPlatformMetadata: Codable, Equatable, Sendable {
    var originURL: String?
    var referrerURL: String?
    var downloadedBy: String?
    var sourceApp: String?
    var whereFroms: [String]?
    var quarantine: String?
    var zoneID: UInt64?
    var xattrs: [String: String]?

    enum CodingKeys: String, CodingKey {
        case originURL = "origin_url"
        case referrerURL = "referrer_url"
        case downloadedBy = "downloaded_by"
        case sourceApp = "source_app"
        case whereFroms = "where_froms"
        case quarantine
        case zoneID = "zone_id"
        case xattrs
    }

    var isEmpty: Bool {
        originURL == nil
            && referrerURL == nil
            && downloadedBy == nil
            && sourceApp == nil
            && (whereFroms?.isEmpty ?? true)
            && quarantine == nil
            && zoneID == nil
            && (xattrs?.isEmpty ?? true)
    }

    /// Clean control characters and enforce wire size bounds before encoding.
    func sanitized() -> FolderPlatformMetadata? {
        var copy = FolderPlatformMetadata()
        copy.originURL = Self.cleanString(originURL)
        copy.referrerURL = Self.cleanString(referrerURL)
        copy.downloadedBy = Self.cleanString(downloadedBy)
        copy.sourceApp = Self.cleanString(sourceApp)
        if let list = whereFroms {
            let cleaned = Array(list.compactMap(Self.cleanString).prefix(FolderSourceWireConstants.maxWhereFroms))
            if !cleaned.isEmpty { copy.whereFroms = cleaned }
        }
        copy.quarantine = Self.cleanString(quarantine)
        copy.zoneID = zoneID
        if let attrs = xattrs {
            var cleaned: [String: String] = [:]
            for key in attrs.keys.sorted() {
                guard cleaned.count < FolderSourceWireConstants.maxXattrs else { break }
                guard let cleanKey = Self.cleanString(key), let cleanVal = Self.cleanString(attrs[key]) else { continue }
                cleaned[cleanKey] = cleanVal
            }
            if !cleaned.isEmpty { copy.xattrs = cleaned }
        }
        return copy.isEmpty ? nil : copy
    }

    private static func cleanString(_ value: String?) -> String? {
        guard let raw = value else { return nil }
        let stripped = raw.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let text = String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.utf8.count <= FolderSourceWireConstants.maxPlatformStringBytes {
            return text
        }
        var end = text.startIndex
        var bytes = 0
        for idx in text.indices {
            let charBytes = String(text[idx]).utf8.count
            if bytes + charBytes > FolderSourceWireConstants.maxPlatformStringBytes { break }
            bytes += charBytes
            end = text.index(after: idx)
        }
        let prefix = String(text[..<end])
        return prefix.isEmpty ? nil : prefix
    }
}

/// Immutable per-folder snapshot consumed by SwiftUI views and the desktop shell.
struct FolderSummary: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var path: String
    var displayPath: String
    var mode: FolderMode
    var state: DeckStateWord
    var attention: FolderAttention?
    var kinds: FolderKinds
    var facet: String?
    var span: FolderSpan
    var returning: Bool
    var widening: Bool
    var overlap: FolderOverlapInfo?
    var preview: FolderPreviewSummary
    var backfillDone: Int
    var backfillTotal: Int?
    var waiting: Int
    var deliveredTotal: Int
    var lastAddedAt: Date?
    var lastCheckedAt: Date?
    var cantRead: Int
    var fallbackToDetails: Int
    var pausedByMac: Bool

    var isBackfilling: Bool {
        guard let total = backfillTotal, total > 0 else { return false }
        return backfillDone < total
    }
}

/// Aggregate snapshot across all configured folders, published by `FolderSource`.
struct FoldersSnapshot: Equatable, Sendable {
    var folders: [FolderSummary] = []
    var state: DeckStateWord = .readyToSetUp
    var subline: String? = nil
    var waiting: Int = 0
    var paired: Bool = true
    var ownerPaused: Bool = false
    var journalNeedsUpdate: Bool = false
    var facets: [FolderFacet] = []
    var facetsState: FolderFacetsState = .unpaired
    var busy: Bool = false

    static let empty = FoldersSnapshot()

    var hasRunningOrPaused: Bool {
        folders.contains { $0.mode == .on || $0.mode == .paused }
    }

    var hasRunning: Bool {
        folders.contains { $0.mode == .on && $0.attention == nil }
    }

    var hasPausedForMac: Bool {
        folders.contains { ($0.mode == .on || $0.mode == .paused) && $0.attention == nil }
    }

    /// Per-folder `SourceDeclaration` entries for `PUT /app/network/api/clients/self/sources`,
    /// ordered by severity (`needs_attention` < `paused` < `on`) then ascending `id` UTF-8 order.
    /// `off` and `settingUp` folders are omitted.
    func folderDeclarations(ownerPaused: Bool) -> [SourceDeclaration] {
        var ranked: [(rank: Int, id: String, state: String)] = []
        var seen: Set<String> = []
        for folder in folders {
            guard seen.insert(folder.id).inserted else { continue }
            guard folder.mode != .off && folder.mode != .settingUp else { continue }
            let rank: Int
            let wireState: String
            if folder.attention != nil {
                rank = 0
                wireState = "needs_attention"
            } else if folder.mode == .paused || ownerPaused {
                rank = 1
                wireState = "paused"
            } else {
                rank = 2
                wireState = "on"
            }
            ranked.append((rank, folder.id, wireState))
        }
        ranked.sort { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8)
        }
        return ranked.map { SourceDeclaration(source: FolderSourceWireConstants.source, state: $0.state, detail: $0.id) }
    }

    /// Derive worst-signal-wins deck tile state and sub-line from individual folders.
    static func compose(
        folders: [FolderSummary],
        paired: Bool,
        ownerPaused: Bool,
        journalNeedsUpdate: Bool,
        facets: [FolderFacet],
        facetsState: FolderFacetsState,
        busy: Bool
    ) -> FoldersSnapshot {
        let waiting = folders.reduce(0) { $0 + $1.waiting }
        guard !folders.isEmpty else {
            return FoldersSnapshot(
                folders: [],
                state: .readyToSetUp,
                subline: nil,
                waiting: 0,
                paired: paired,
                ownerPaused: ownerPaused,
                journalNeedsUpdate: journalNeedsUpdate,
                facets: facets,
                facetsState: facetsState,
                busy: busy
            )
        }

        let attentionFolders = folders.filter { $0.state == .needsAttention }
        let settingUpFolders = folders.filter { $0.state == .settingUp }
        let onFolders = folders.filter { $0.state == .on }
        let pausedFolders = folders.filter { $0.state == .paused }

        let tileState: DeckStateWord
        let subline: String?

        if !attentionFolders.isEmpty {
            tileState = .needsAttention
            if attentionFolders.count == 1 {
                let f = attentionFolders[0]
                switch f.attention {
                case .accessOff: subline = FolderSourceCopy.accessOff(f.name)
                case .missing: subline = FolderSourceCopy.missing(f.name)
                case .unreadable, nil: subline = FolderSourceCopy.unreadable(f.name)
                }
            } else {
                subline = FolderSourceCopy.needAttentionMany(attentionFolders.count)
            }
        } else if !settingUpFolders.isEmpty {
            tileState = .settingUp
            subline = FolderSourceCopy.finishSetup(settingUpFolders[0].name)
        } else if !onFolders.isEmpty {
            tileState = .on
            if !pausedFolders.isEmpty {
                subline = FolderSourceCopy.split(on: onFolders.count, paused: pausedFolders.count)
            } else if !paired {
                subline = FolderSourceCopy.unpaired
            } else if journalNeedsUpdate {
                subline = FolderSourceCopy.journalUpdate
            } else if let backfilling = onFolders.first(where: { $0.isBackfilling }),
                      let total = backfilling.backfillTotal {
                subline = FolderSourceCopy.tileProgress(folder: backfilling.name, done: backfilling.backfillDone, total: total)
            } else if waiting > 0 {
                if onFolders.count == 1 {
                    subline = FolderSourceCopy.waitingFolder(onFolders[0].name, count: waiting)
                } else {
                    subline = FolderSourceCopy.waiting(waiting)
                }
            } else if onFolders.count == 1 {
                subline = onFolders[0].name
            } else if onFolders.count == 2 {
                subline = FolderSourceCopy.two(onFolders[0].name, onFolders[1].name)
            } else {
                subline = FolderSourceCopy.many(onFolders.count)
            }
        } else if !pausedFolders.isEmpty {
            tileState = .paused
            if ownerPaused {
                subline = FolderSourceCopy.pausedMac
            } else if pausedFolders.count == 1 {
                subline = pausedFolders[0].name
            } else if pausedFolders.count == 2 {
                subline = FolderSourceCopy.two(pausedFolders[0].name, pausedFolders[1].name)
            } else {
                subline = FolderSourceCopy.many(pausedFolders.count)
            }
        } else {
            tileState = .off
            subline = nil
        }

        return FoldersSnapshot(
            folders: folders,
            state: tileState,
            subline: subline,
            waiting: waiting,
            paired: paired,
            ownerPaused: ownerPaused,
            journalNeedsUpdate: journalNeedsUpdate,
            facets: facets,
            facetsState: facetsState,
            busy: busy
        )
    }
}
