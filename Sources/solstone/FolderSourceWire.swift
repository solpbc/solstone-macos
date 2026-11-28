// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation

/// One Protocol v3 folder activity JSONL line (v1).
struct FolderActivityWireLine: Encodable, Equatable, Sendable {
    let v: Int = 1
    let event: String
    let path: String
    let previousPath: String?
    let at: String
    let observedAt: String
    let fileType: String?
    let size: Int64?
    let createdAt: String?
    let modifiedAt: String?
    let contentHash: String?
    let part: String?
    let kindHint: String?
    let platform: FolderPlatformMetadata?

    enum CodingKeys: String, CodingKey {
        case v, event, path
        case previousPath = "previous_path"
        case at
        case observedAt = "observed_at"
        case fileType = "file_type"
        case size
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case contentHash = "content_hash"
        case part
        case kindHint = "kind_hint"
        case platform
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(event, forKey: .event)
        try c.encode(path, forKey: .path)
        if event == "renamed" {
            try c.encodeIfPresent(previousPath, forKey: .previousPath)
        }
        try c.encode(at, forKey: .at)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encodeIfPresent(fileType, forKey: .fileType)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        if event != "removed" {
            try c.encodeIfPresent(contentHash, forKey: .contentHash)
            try c.encodeIfPresent(part, forKey: .part)
        }
        try c.encodeIfPresent(kindHint, forKey: .kindHint)
        if let platform = platform?.sanitized() {
            try c.encode(platform, forKey: .platform)
        }
    }
}

/// One folder segment chunk ready to stage and upload via Protocol v3.
struct FolderSegmentUpload: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var eventID: String
        var verb: FolderActivityVerb
        var path: String
        var previousPath: String?
        var at: String
        var observedAt: String
        var fileType: String?
        var sizeBytes: Int64?
        var createdAt: String?
        var modifiedAt: String?
        var kindHint: String?
        var platform: FolderPlatformMetadata?
        /// Non-nil when this item uploads companion file bytes.
        var sourcePath: String?
        var canonicalRoot: String?
        var expectedSHA256: String?
        var inlineNoteData: Data? = nil
        var convertToPNG: Bool = false
    }

    var folderID: String
    var folderName: String
    var facet: String?
    var kinds: FolderKinds
    var day: String
    var segment: String
    var items: [Item]
}

/// Refused file entry returned by the journal on `200 ok` (`refused_files`) or `400 folder_file_invalid`.
struct FolderRefusedFile: Decodable, Equatable, Sendable {
    let path: String
    let part: String?
    let reasonCode: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case path, part
        case reasonCode = "reason_code"
        case detail
    }
}

/// Outcome of one Protocol v3 folder segment upload per the answers table.
enum FolderDeliveryAnswer: Equatable, Sendable {
    /// Upload accepted. `localFallback` lists paths already sent details-only after local conversion refusal.
    case delivered(localFallback: [String] = [])
    /// Upload partially accepted: non-refused items landed; `serverRefused` paths must be re-queued details-only.
    case deliveredWithRefused(serverRefused: [String], localFallback: [String] = [])
    /// Every item failed per-file validation (`400 folder_file_invalid`); re-queue as details-only.
    case allFilesRefused([String])
    case ahead
    case invalid
    case retry
}

/// Transport contract for the folder source so tests run deterministically without a network.
protocol FolderSourceTransport: FolderSyncJournalTransport {
    func fetchFacets(serverURL: String) async throws -> [FolderFacet]
    func fetchSupported(serverURL: String) async throws -> FolderSupportedList
    func fetchEstimate(serverURL: String, request: FolderEstimateRequest) async throws -> FolderBackfillEstimate
    func sendSegment(
        _ upload: FolderSegmentUpload,
        reader: any FolderSystemReading,
        supported: FolderSupportedList,
        serverURL: String,
        isCurrent: @Sendable () async -> Bool
    ) async -> FolderDeliveryAnswer
}

/// Wire encoding & answers-table classification for the folder source (Protocol v3, bundle 15.5.0).
enum FolderSourceWire {
    static let facetsPath = "/app/devices/ingest/folder/facets"
    static let supportedPath = "/app/devices/ingest/folder/supported"
    static let estimatePath = "/app/devices/ingest/folder/estimate"

    private struct WireFacet: Decodable {
        let name: String
        let title: String?
        let color: String?
        let muted: Bool?
    }

    private struct WireFacetList: Decodable {
        let facets: [WireFacet]
    }

    private struct WireSupportedThresholds: Decodable {
        let structuredProseMinWords: Int?
        let structuredProseMinHeadingLevels: Int?
        let longProseMinWords: Int?

        enum CodingKeys: String, CodingKey {
            case structuredProseMinWords = "structured_prose_min_words"
            case structuredProseMinHeadingLevels = "structured_prose_min_heading_levels"
            case longProseMinWords = "long_prose_min_words"
        }
    }

    private struct WireSupportedKind: Decodable {
        let extensions: [String]?
        let convertToPNGOnDevice: [String]?
        let thresholds: WireSupportedThresholds?

        enum CodingKeys: String, CodingKey {
            case extensions
            case convertToPNGOnDevice = "convert_to_png_on_device"
            case thresholds
        }
    }

    private struct WireSupportedKinds: Decodable {
        let notes: WireSupportedKind?
        let documents: WireSupportedKind?
        let transcripts: WireSupportedKind?
        let screenshots: WireSupportedKind?
        let photos: WireSupportedKind?
    }

    private struct WireSupportedResponse: Decodable {
        let rulesetVersion: Int?
        let windowSeconds: Int64?
        let maxFileBytes: Int64?
        let maxNoteBytes: Int64?
        let maxImagePixels: Int64?
        let documentRevisionCooldownSeconds: Int64?
        let kinds: WireSupportedKinds?

        enum CodingKeys: String, CodingKey {
            case rulesetVersion = "ruleset_version"
            case windowSeconds = "window_seconds"
            case maxFileBytes = "max_file_bytes"
            case maxNoteBytes = "max_note_bytes"
            case maxImagePixels = "max_image_pixels"
            case documentRevisionCooldownSeconds = "document_revision_cooldown_seconds"
            case kinds
        }
    }

    private struct WireUploadAnswer: Decodable {
        let status: String?
        let reasonCode: String?
        let refusedFiles: [FolderRefusedFile]?

        enum CodingKeys: String, CodingKey {
            case status
            case reasonCode = "reason_code"
            case refusedFiles = "refused_files"
        }
    }

    static func parseFacets(_ data: Data) -> [FolderFacet]? {
        guard let decoded = try? JSONDecoder().decode(WireFacetList.self, from: data) else {
            return nil
        }
        return decoded.facets
            .filter { ($0.muted ?? false) == false && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { facet in
                let trimmedTitle = (facet.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return FolderFacet(
                    name: facet.name,
                    title: trimmedTitle.isEmpty ? facet.name : trimmedTitle,
                    color: facet.color
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func parseSupportedList(_ data: Data) -> FolderSupportedList? {
        guard let wire = try? JSONDecoder().decode(WireSupportedResponse.self, from: data) else {
            return nil
        }
        var list = FolderSupportedList.defaults
        let norm: ([String]?) -> Set<String> = { items in
            Set((items ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }.filter { !$0.isEmpty })
        }

        let notes = norm(wire.kinds?.notes?.extensions)
        if !notes.isEmpty { list.noteExtensions = notes }

        let docs = norm(wire.kinds?.documents?.extensions).subtracting(list.noteExtensions)
        if !docs.isEmpty { list.documentExtensions = docs }

        if let th = wire.kinds?.documents?.thresholds {
            if let v = th.structuredProseMinWords { list.structuredProseMinWords = v }
            if let v = th.structuredProseMinHeadingLevels { list.structuredProseMinHeadingLevels = v }
            if let v = th.longProseMinWords { list.longProseMinWords = v }
        }

        // Unambiguous transcript extensions not overlapping plain notes or documents.
        let unambiguousTranscripts: Set<String> = ["vtt", "srt"]
        let transcripts = norm(wire.kinds?.transcripts?.extensions)
            .subtracting(list.noteExtensions)
            .subtracting(list.documentExtensions)
            .intersection(unambiguousTranscripts)
        if !transcripts.isEmpty { list.transcriptExtensions = transcripts }

        let acceptedImages = norm(wire.kinds?.screenshots?.extensions).union(norm(wire.kinds?.photos?.extensions))
        if !acceptedImages.isEmpty { list.acceptedImageExtensions = acceptedImages }

        let convertibleImages = norm(wire.kinds?.screenshots?.convertToPNGOnDevice).union(norm(wire.kinds?.photos?.convertToPNGOnDevice))
        if !convertibleImages.isEmpty { list.convertibleImageExtensions = convertibleImages }

        if let v = wire.rulesetVersion { list.rulesetVersion = v }
        if let v = wire.windowSeconds, v > 0 { list.windowSeconds = v }
        if let v = wire.maxFileBytes, v > 0 { list.maxContentBytes = v }
        if let v = wire.maxNoteBytes, v > 0 { list.maxNoteBytes = v }
        if let v = wire.maxImagePixels, v > 0 { list.maxImagePixels = v }
        if let secs = wire.documentRevisionCooldownSeconds, secs > 0 {
            list.documentRevisionCooldownMs = secs * 1000
        }
        list.fromJournal = true
        return list
    }

    static func folderMeta(_ upload: FolderSegmentUpload) -> [String: IngestJSONValue] {
        var folderObj: [String: IngestJSONValue] = [
            "v": .integer(1),
            "id": .string(upload.folderID),
            "name": .string(FolderSourceClassify.usableFolderName(upload.folderName)),
            "kinds": .array(upload.kinds.wireNames.map { .string($0) }),
        ]
        if let facet = upload.facet, !facet.isEmpty {
            folderObj["facet"] = .string(facet)
        } else {
            folderObj["facet"] = .null
        }
        return ["folder": .object(folderObj)]
    }

    /// Encode activity lines as LF-terminated JSONL and return `(filename, bytes)`.
    static func encodeActivityJSONL(_ lines: [FolderActivityWireLine]) throws -> (filename: String, data: Data) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Data()
        for line in lines {
            let encoded = try encoder.encode(line)
            bytes.append(encoded)
            bytes.append(0x0A)
        }
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ("\(FolderSourceWireConstants.filePrefix)\(hex)\(FolderSourceWireConstants.fileSuffix)", bytes)
    }

    /// Classify HTTP response per `POST /app/devices/ingest` (`source = "folder"`) answers table.
    static func classifyAnswer(statusCode: Int, body: Data) -> FolderDeliveryAnswer {
        let parsed = try? JSONDecoder().decode(WireUploadAnswer.self, from: body)
        if (200...299).contains(statusCode) {
            guard let status = parsed?.status else { return .retry }
            if status == "ok" || status == "duplicate" || status == "collision" {
                let refused = (parsed?.refusedFiles ?? []).map(\.path)
                return refused.isEmpty ? .delivered() : .deliveredWithRefused(serverRefused: refused)
            }
            return .retry
        }
        let reason = parsed?.reasonCode ?? parseIngestErrorBody(body).reasonCode
        switch reason {
        case "segment_removed", "duplicate", "collision":
            return .delivered()
        case "folder_file_invalid":
            return .allFilesRefused((parsed?.refusedFiles ?? []).map(\.path))
        case "folder_ahead":
            return .ahead
        case "folder_invalid":
            return .invalid
        case "journal_read_failed":
            return .retry
        default:
            return .retry
        }
    }

    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jsonl": return "application/jsonl"
        case "md", "markdown": return "text/markdown; charset=utf-8"
        case "txt", "log": return "text/plain; charset=utf-8"
        case "pdf": return "application/pdf"
        case "vtt": return "text/vtt; charset=utf-8"
        case "srt": return "application/x-subrip"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "json": return "application/json"
        case "csv": return "text/csv; charset=utf-8"
        case "tsv": return "text/tab-separated-values; charset=utf-8"
        case "html": return "text/html; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

/// Live Protocol v3 transport backed by `UploadClient`.
struct FolderLiveTransport: FolderSourceTransport {
    var journal: UploadClient

    func capabilities(serverURL: String) async throws -> [String] {
        try await journal.capabilities(serverURL: serverURL)
    }

    func fetchFacets(serverURL: String) async throws -> [FolderFacet] {
        let data = try await journal.folderGet(serverURL: serverURL, path: FolderSourceWire.facetsPath)
        guard let parsed = FolderSourceWire.parseFacets(data) else {
            throw UploadError.invalidResponse
        }
        return parsed
    }

    func fetchSupported(serverURL: String) async throws -> FolderSupportedList {
        let data = try await journal.folderGet(serverURL: serverURL, path: FolderSourceWire.supportedPath)
        guard let parsed = FolderSourceWire.parseSupportedList(data) else {
            throw UploadError.invalidResponse
        }
        return parsed
    }

    func fetchEstimate(serverURL: String, request: FolderEstimateRequest) async throws -> FolderBackfillEstimate {
        let body = try JSONEncoder().encode(request)
        let data = try await journal.folderPostJSON(serverURL: serverURL, path: FolderSourceWire.estimatePath, body: body)
        guard let decoded = try? JSONDecoder().decode(FolderBackfillEstimate.self, from: data) else {
            throw UploadError.invalidResponse
        }
        return decoded
    }

    func sendSegment(
        _ upload: FolderSegmentUpload,
        reader: any FolderSystemReading,
        supported: FolderSupportedList,
        serverURL: String,
        isCurrent: @Sendable () async -> Bool
    ) async -> FolderDeliveryAnswer {
        guard !upload.items.isEmpty else { return .delivered() }
        guard !Task.isCancelled, await isCurrent() else { return .retry }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-folder-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return .retry
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        var wireLines: [FolderActivityWireLine] = []
        var companionURLs: [URL] = []
        var locallyRefused: [String] = []
        var partNumber = 0

        for item in upload.items {
            var partName: String?
            var contentHash: String?
            var effectiveSize = item.sizeBytes

            if item.verb != .removed, let inlineData = item.inlineNoteData {
                partNumber += 1
                let ext = (item.fileType ?? "md").lowercased()
                let targetExt = ext.isEmpty ? "md" : ext
                let partFileName = String(format: "c_%02d.%@", partNumber, targetExt)
                let destURL = staging.appendingPathComponent(partFileName)
                do {
                    try inlineData.write(to: destURL, options: .atomic)
                } catch {
                    return .retry
                }
                let sha = SHA256.hash(data: inlineData).map { String(format: "%02x", $0) }.joined()
                partName = partFileName
                contentHash = sha
                effectiveSize = Int64(inlineData.count)
                companionURLs.append(destURL)
            } else if item.verb != .removed, let sourcePath = item.sourcePath, let canonicalRoot = item.canonicalRoot {
                partNumber += 1
                let ext = (item.fileType ?? (sourcePath as NSString).pathExtension).lowercased()
                let targetExt = item.convertToPNG ? "png" : (ext.isEmpty ? "bin" : ext)
                let candidateName = String(format: "c_%02d.%@", partNumber, targetExt)
                let destURL = staging.appendingPathComponent(candidateName)

                let staged = reader.stageFile(
                    sourcePath: sourcePath,
                    canonicalRoot: canonicalRoot,
                    destinationURL: destURL,
                    expectedSHA256: item.expectedSHA256,
                    convertToPNG: item.convertToPNG,
                    maxImagePixels: supported.maxImagePixels,
                    maxBytes: supported.maxContentBytes
                )

                switch staged {
                case .ready(let sha256, let stagedSize, let finalExt):
                    let finalName = String(format: "c_%02d.%@", partNumber, finalExt)
                    let finalURL = staging.appendingPathComponent(finalName)
                    if finalURL != destURL {
                        try? FileManager.default.moveItem(at: destURL, to: finalURL)
                    }
                    partName = finalName
                    contentHash = sha256
                    if effectiveSize == nil { effectiveSize = stagedSize }
                    companionURLs.append(finalURL)
                case .invalidContent:
                    // Unconvertible or oversized after conversion: degrade this item to details-only locally.
                    locallyRefused.append(item.path)
                    partNumber -= 1
                case .missing, .dataless, .unreadable:
                    // File disappeared or changed before staging: retry after the next walk reconciles.
                    return .retry
                }
            }

            wireLines.append(FolderActivityWireLine(
                event: item.verb.wireEvent,
                path: item.path,
                previousPath: item.verb == .renamed ? item.previousPath : nil,
                at: item.at,
                observedAt: item.observedAt,
                fileType: item.fileType,
                size: effectiveSize,
                createdAt: item.createdAt,
                modifiedAt: item.modifiedAt,
                contentHash: contentHash,
                part: partName,
                kindHint: item.kindHint,
                platform: item.platform
            ))
        }

        let jsonlName: String
        let jsonlBytes: Data
        do {
            (jsonlName, jsonlBytes) = try FolderSourceWire.encodeActivityJSONL(wireLines)
        } catch {
            return .invalid
        }
        guard jsonlBytes.count <= FolderSourceWireConstants.maxFileBytes else {
            return .invalid
        }

        let jsonlURL = staging.appendingPathComponent(jsonlName)
        do {
            try jsonlBytes.write(to: jsonlURL, options: .atomic)
        } catch {
            return .retry
        }

        let allFiles = [jsonlURL] + companionURLs
        let bodyURL = staging.appendingPathComponent("body")
        let answer = await journal.uploadFolderFiles(
            allFiles,
            serverURL: serverURL,
            day: upload.day,
            segment: upload.segment,
            metadata: FolderSourceWire.folderMeta(upload),
            source: FolderSourceWireConstants.source,
            bodyURL: bodyURL,
            isCurrent: isCurrent,
            classify: FolderSourceWire.classifyAnswer
        )

        if locallyRefused.isEmpty {
            return answer
        }
        switch answer {
        case .delivered(let existingLocal):
            return .delivered(localFallback: Array(Set(existingLocal + locallyRefused)).sorted())
        case .deliveredWithRefused(let serverRefused, let existingLocal):
            return .deliveredWithRefused(
                serverRefused: serverRefused,
                localFallback: Array(Set(existingLocal + locallyRefused)).sorted()
            )
        default:
            return answer
        }
    }
}
