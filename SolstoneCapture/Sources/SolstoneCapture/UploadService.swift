// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CryptoKit
import SolstoneCaptureCore

/// File info returned by the server for a segment
public struct ServerFileInfo: Sendable {
    public let name: String      // e.g., "143022_300_audio.m4a"
    public let sha256: String
    public let size: Int
}

/// Service for uploading segments to the remote server
/// Thread safety: @MainActor ensures all state mutations happen on main thread,
/// which is required for @Observable to work correctly with SwiftUI.
/// Network operations use URLSession which manages its own threading.
@MainActor
@Observable
public final class UploadService {
    /// Current upload status
    public enum Status: Sendable, Equatable {
        case notSynced          // Initial state, haven't verified connection
        case syncing(checked: Int, total: Int)
        case synced             // Successfully verified with server
        case uploading(segment: String)
        case retrying(segment: String, attempts: Int)
        case offline(String)    // Can't reach server
    }

    /// Result of an upload attempt
    public enum UploadResult: Sendable {
        case success
        case failure(Error)
        case skipped  // Already exists on server
        case notConfigured
    }

    // MARK: - Observable State

    public private(set) var status: Status = .notSynced
    public private(set) var pendingCount: Int = 0

    /// Whether syncing is paused - reads from config as single source of truth
    public var syncPaused: Bool {
        config.syncPaused
    }

    // MARK: - Private State

    private let storageManager: StorageManager
    private let session: URLSession
    private var config: AppConfig
    private var lastUploadedSegment: URL?
    private var retryTask: Task<Void, Never>?
    // Exponential backoff for upload retries: 5s, 30s, 2min, 5min, then 5min thereafter.
    // Short initial delays catch transient network issues; longer delays avoid
    // hammering the server during extended outages while still retrying regularly.
    private var retryDelays: [TimeInterval] = [5, 30, 120, 300]

    // MARK: - Initialization

    public init(storageManager: StorageManager, config: AppConfig) {
        self.storageManager = storageManager
        self.config = config

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 300  // 5 min for large files
        sessionConfig.timeoutIntervalForResource = 600  // 10 min total
        self.session = URLSession(configuration: sessionConfig)
    }

    /// Update configuration (called when settings change)
    public func updateConfig(_ newConfig: AppConfig) {
        let wasPaused = config.syncPaused
        self.config = newConfig

        // If sync was re-enabled, trigger a sync to catch up
        if wasPaused && !newConfig.syncPaused {
            Task { await syncOnStartup() }
        }
    }

    // MARK: - Startup Sync

    /// Scan all local segments and upload any missing from server
    public func syncOnStartup() async {
        Log.upload("syncOnStartup called, isConfigured=\(config.isUploadConfigured), paused=\(syncPaused)")

        guard !syncPaused else {
            Log.upload("Sync paused, skipping")
            return
        }

        guard config.isUploadConfigured else {
            Log.upload("Not configured, skipping sync")
            return
        }

        Log.upload("Starting sync, testing connection to \(config.serverURL ?? "nil")...")

        // Test connection first
        if let error = await testConnection() {
            Log.upload("Connection test failed: \(error)")
            status = .offline(error)
            return
        }

        Log.upload("Connection test passed")

        // Collect all segment directories grouped by day
        let segmentsByDay = collectSegmentsByDay()
        guard !segmentsByDay.isEmpty else {
            Log.upload("No local segments found")
            status = .synced
            return
        }

        let totalSegments = segmentsByDay.values.reduce(0) { $0 + $1.count }
        pendingCount = totalSegments
        var checked = 0

        // Process each day
        for (day, localSegments) in segmentsByDay.sorted(by: { $0.key < $1.key }) {
            status = .syncing(checked: checked, total: totalSegments)

            // Query server for all segments on this day
            guard let serverSegments = await getServerSegments(day: day) else {
                Log.upload("Failed to query server for day \(day), skipping")
                checked += localSegments.count
                pendingCount = totalSegments - checked
                continue
            }

            Log.upload("Day \(day): \(localSegments.count) local, \(serverSegments.count) on server")

            // Check each local segment
            for segmentURL in localSegments {
                let (_, segment) = convertSegmentPath(segmentURL)

                // Check if segment exists and all files match
                let needsUpload = segmentNeedsUpload(
                    segmentURL: segmentURL,
                    segment: segment,
                    serverFiles: serverSegments[segment]
                )

                if needsUpload {
                    Log.upload("Segment \(segment) needs upload...")
                    let result = await uploadSegmentWithRetry(at: segmentURL)
                    switch result {
                    case .success:
                        Log.upload("Segment \(segment) uploaded successfully")
                        lastUploadedSegment = segmentURL
                    case .failure(let error):
                        Log.upload("Segment \(segment) upload failed: \(error)")
                    case .skipped:
                        Log.upload("Segment \(segment) already exists")
                    case .notConfigured:
                        break
                    }
                } else {
                    Log.upload("Segment \(segment) verified on server")
                    lastUploadedSegment = segmentURL
                }

                checked += 1
                pendingCount = totalSegments - checked
                status = .syncing(checked: checked, total: totalSegments)
            }
        }

        // Cleanup old segments after sync
        await cleanupOldSegments()

        status = .synced
        pendingCount = 0
        Log.upload("Sync complete")
    }

    // MARK: - Single Segment Upload

    /// Upload a segment (called when a new segment completes)
    public func uploadSegment(at segmentURL: URL) async -> UploadResult {
        guard !syncPaused else {
            return .notConfigured
        }

        guard config.isUploadConfigured else {
            return .notConfigured
        }

        pendingCount += 1
        let result = await uploadSegmentWithRetry(at: segmentURL)

        if case .success = result {
            lastUploadedSegment = segmentURL
            await cleanupOldSegments()
        }

        pendingCount = max(0, pendingCount - 1)
        return result
    }

    // MARK: - Server Check

    /// Test connection to server using saved config, returns error message if failed
    public func testConnection() async -> String? {
        guard let serverURL = config.serverURL,
              let serverKey = config.serverKey else {
            Log.upload("testConnection: not configured")
            return "Not configured"
        }
        return await Self.testConnection(serverURL: serverURL, serverKey: serverKey)
    }

    /// Test connection to server with explicit URL and key, returns error message if failed
    public static func testConnection(serverURL: String, serverKey: String) async -> String? {
        // Use segments endpoint with current date to test connection
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let today = dateFormatter.string(from: Date())
        let urlString = "\(serverURL)/app/remote/ingest/\(serverKey)/segments/\(today)"
        Log.upload("testConnection: GET \(urlString)")

        guard let url = URL(string: urlString) else {
            Log.upload("testConnection: invalid URL")
            return "Invalid URL"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10  // Quick timeout for connection test
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // Use ephemeral session for connection test (no caching)
        let testSession = URLSession(configuration: .ephemeral)
        defer { testSession.invalidateAndCancel() }

        do {
            Log.upload("testConnection: sending request...")
            let (data, response) = try await testSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "<none>"
                Log.upload("testConnection: HTTP \(httpResponse.statusCode)")
                Log.upload("testConnection: Content-Type: \(contentType)")
                Log.upload("testConnection: Body: \(bodyPreview)")
                Log.upload("testConnection: All headers: \(httpResponse.allHeaderFields)")

                // Check if response is JSON (not HTML login page)
                if contentType.contains("text/html") || bodyPreview.contains("<!DOCTYPE") || bodyPreview.contains("<html") {
                    Log.upload("testConnection: got HTML instead of JSON - endpoint may not exist")
                    return "Server returned login page (restart server?)"
                }

                switch httpResponse.statusCode {
                case 200:
                    Log.upload("testConnection: SUCCESS")
                    return nil  // Success - server responded with JSON
                case 401:
                    Log.upload("testConnection: FAILED - Invalid API key")
                    return "Invalid API key"
                case 403:
                    Log.upload("testConnection: FAILED - Remote disabled")
                    return "Remote disabled"
                case 404:
                    Log.upload("testConnection: FAILED - Endpoint not found")
                    return "Endpoint not found (server update needed?)"
                default:
                    Log.upload("testConnection: FAILED - Server error \(httpResponse.statusCode)")
                    return "Server error (\(httpResponse.statusCode))"
                }
            }
            Log.upload("testConnection: no HTTP response object")
            return "Invalid response"
        } catch let error as URLError {
            Log.upload("testConnection: URLError \(error.code.rawValue) - \(error.localizedDescription)")
            switch error.code {
            case .notConnectedToInternet:
                return "No internet connection"
            case .cannotFindHost:
                return "Server not found"
            case .cannotConnectToHost:
                return "Cannot connect to server"
            case .timedOut:
                return "Connection timed out"
            default:
                return error.localizedDescription
            }
        } catch {
            Log.upload("testConnection: error \(error)")
            return error.localizedDescription
        }
    }

    /// Get all segments with file info for a given day from the server
    /// Returns nil on error, empty dict if day has no segments
    public func getServerSegments(day: String) async -> [String: [ServerFileInfo]]? {
        guard let serverURL = config.serverURL,
              let serverKey = config.serverKey else {
            return nil
        }

        let urlString = "\(serverURL)/app/remote/ingest/\(serverKey)/segments/\(day)"
        guard let url = URL(string: urlString) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                // Parse JSON: [{"key": "...", "files": [{"name": "...", "size": ..., "sha256": "..."}]}]
                if let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    var result: [String: [ServerFileInfo]] = [:]
                    for seg in segments {
                        guard let segmentKey = seg["key"] as? String,
                              let files = seg["files"] as? [[String: Any]] else {
                            continue
                        }
                        let fileInfos = files.compactMap { file -> ServerFileInfo? in
                            guard let name = file["name"] as? String,
                                  let size = file["size"] as? Int else {
                                return nil
                            }
                            // sha256 can be null per the spec
                            let sha256 = file["sha256"] as? String ?? ""
                            return ServerFileInfo(name: name, sha256: sha256, size: size)
                        }
                        result[segmentKey] = fileInfos
                    }
                    return result
                }
            }
        } catch {
            Log.upload("getServerSegments failed: \(error)")
        }

        return nil
    }

    // MARK: - Private Methods

    /// Check if a segment needs to be uploaded by comparing file hashes
    private func segmentNeedsUpload(
        segmentURL: URL,
        segment: String,
        serverFiles: [ServerFileInfo]?
    ) -> Bool {
        // If no server files, definitely need upload
        guard let serverFiles = serverFiles, !serverFiles.isEmpty else {
            Log.upload("Segment \(segment): not on server")
            return true
        }

        // Build map by filename (files already have segment prefix)
        var serverFileMap: [String: ServerFileInfo] = [:]
        for file in serverFiles {
            serverFileMap[file.name] = file
        }

        // Get local media files
        let fm = FileManager.default
        guard let localFiles = try? fm.contentsOfDirectory(at: segmentURL, includingPropertiesForKeys: nil) else {
            return true
        }

        let mediaFiles = localFiles.filter { $0.pathExtension == "mp4" || $0.pathExtension == "m4a" }

        // Check each local file against server (filenames already match)
        for localFile in mediaFiles {
            let filename = localFile.lastPathComponent  // Already has segment prefix

            guard let serverFile = serverFileMap[filename] else {
                Log.upload("Segment \(segment): file \(filename) not on server")
                return true
            }

            guard let localHash = sha256(of: localFile) else {
                Log.upload("Segment \(segment): failed to hash \(filename)")
                return true
            }

            if localHash != serverFile.sha256 {
                Log.upload("Segment \(segment): hash mismatch for \(filename)")
                Log.upload("  local:  \(localHash)")
                Log.upload("  server: \(serverFile.sha256)")
                return true
            }
        }

        return false
    }

    private func uploadSegmentWithRetry(at segmentURL: URL) async -> UploadResult {
        let (day, segment) = convertSegmentPath(segmentURL)
        var attempts = 0

        while true {
            attempts += 1
            status = attempts == 1 ? .uploading(segment: segment) : .retrying(segment: segment, attempts: attempts)

            let result = await performUpload(segmentURL: segmentURL, day: day, segment: segment)

            switch result {
            case .success, .skipped, .notConfigured:
                status = .synced
                return result
            case .failure(let error):
                Log.upload("Attempt \(attempts) failed: \(error)")

                // Calculate delay
                let delay: TimeInterval
                if attempts <= retryDelays.count {
                    delay = retryDelays[attempts - 1]
                } else {
                    delay = 300  // 5 minutes
                }

                Log.upload("Retrying in \(Int(delay))s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Check if still configured or if sync was paused
                if !config.isUploadConfigured || syncPaused {
                    status = .notSynced
                    return .notConfigured
                }
            }
        }
    }

    private func performUpload(segmentURL: URL, day: String, segment: String) async -> UploadResult {
        guard let serverURL = config.serverURL,
              let serverKey = config.serverKey else {
            return .notConfigured
        }

        let urlString = "\(serverURL)/app/remote/ingest/\(serverKey)"
        guard let url = URL(string: urlString) else {
            return .failure(UploadError.invalidURL)
        }

        // Collect files in segment directory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: segmentURL, includingPropertiesForKeys: nil) else {
            return .failure(UploadError.noFiles)
        }

        let allMediaFiles = files.filter { $0.pathExtension == "mp4" || $0.pathExtension == "m4a" }
        guard !allMediaFiles.isEmpty else {
            return .failure(UploadError.noFiles)
        }

        // Separate mic files from other media files
        let micFiles = allMediaFiles.filter { $0.lastPathComponent.contains("_mic") }
        let nonMicFiles = allMediaFiles.filter { !$0.lastPathComponent.contains("_mic") }

        // Select which mic files to upload (1 or 2 based on priority and completeness)
        let selectedMicFiles = selectMicFilesForUpload(from: micFiles, segmentDirectory: segmentURL)

        // Combine: non-mic files + selected mic files
        let mediaFiles = nonMicFiles + selectedMicFiles

        // Debug: show form fields and local path
        let localPath = segmentURL.lastPathComponent
        let localDay = segmentURL.deletingLastPathComponent().lastPathComponent
        let fileNames = mediaFiles.map { $0.lastPathComponent }.joined(separator: ", ")
        Log.upload("POST local=\(localDay)/\(localPath) -> day=\(day) segment=\(segment) platform=darwin files=[\(fileNames)]")

        // Build multipart form data in a temporary file to avoid memory pressure
        // from large video files. The temp file is streamed to the server.
        let boundary = UUID().uuidString
        let tempURL = fm.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).tmp")

        do {
            // Create temp file and write multipart data incrementally
            fm.createFile(atPath: tempURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: tempURL)
            defer {
                try? fileHandle.close()
                try? fm.removeItem(at: tempURL)
            }

            // Write form fields
            try fileHandle.writeMultipartField(boundary: boundary, name: "segment", value: segment)
            try fileHandle.writeMultipartField(boundary: boundary, name: "day", value: day)
            try fileHandle.writeMultipartField(boundary: boundary, name: "platform", value: "darwin")

            // Stream each file to temp file (avoids loading all into memory at once)
            for fileURL in mediaFiles {
                let filename = fileURL.lastPathComponent
                let mimeType = fileURL.pathExtension == "mp4" ? "video/mp4" : "audio/mp4"

                // Get file size for logging
                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                let fileSize = attrs?[.size] as? Int ?? 0
                Log.upload("  + \(filename) (\(fileSize) bytes)")

                try fileHandle.writeMultipartFileHeader(boundary: boundary, filename: filename, mimeType: mimeType)

                // Stream file contents in chunks to avoid loading entire file into memory
                let sourceHandle = try FileHandle(forReadingFrom: fileURL)
                defer { try? sourceHandle.close() }

                let chunkSize = 1024 * 1024  // 1 MB chunks
                while true {
                    let chunk = sourceHandle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    try fileHandle.write(contentsOf: chunk)
                }

                try fileHandle.write(contentsOf: "\r\n".data(using: .utf8)!)
            }

            // Write closing boundary
            try fileHandle.write(contentsOf: "--\(boundary)--\r\n".data(using: .utf8)!)
            try fileHandle.synchronize()

            let totalSize = try fm.attributesOfItem(atPath: tempURL.path)[.size] as? Int ?? 0
            Log.upload("Total request body: \(totalSize) bytes (streaming from temp file)")

            // Create request and upload from temp file
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let (data, response) = try await session.upload(for: request, fromFile: tempURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(UploadError.invalidResponse)
            }

            let responseBody = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            Log.upload("Response: HTTP \(httpResponse.statusCode) - \(responseBody)")

            if httpResponse.statusCode == 200 {
                return .success
            } else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(UploadError.serverError(statusCode: httpResponse.statusCode, message: errorMessage))
            }
        } catch {
            // Clean up temp file on error
            try? fm.removeItem(at: tempURL)
            return .failure(error)
        }
    }

    private func collectAllSegments() -> [URL] {
        return collectSegmentsByDay().values.flatMap { $0 }.sorted { $0.path < $1.path }
    }

    /// Collect segments grouped by day (YYYYMMDD format)
    private func collectSegmentsByDay() -> [String: [URL]] {
        let fm = FileManager.default
        var segmentsByDay: [String: [URL]] = [:]

        // List all date directories
        guard let dateDirs = try? fm.contentsOfDirectory(
            at: storageManager.baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        for dateDir in dateDirs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dateDir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            // Convert date folder to server format (YYYY-MM-DD -> YYYYMMDD)
            let dayFolder = dateDir.lastPathComponent
            let day = dayFolder.replacingOccurrences(of: "-", with: "")

            // List segments in this date directory
            guard let segmentDirs = try? fm.contentsOfDirectory(
                at: dateDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            var segments: [URL] = []
            for segmentDir in segmentDirs {
                isDirectory = false
                guard fm.fileExists(atPath: segmentDir.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }

                // Skip incomplete segments (directory name ends with .incomplete)
                if segmentDir.lastPathComponent.hasSuffix(".incomplete") {
                    continue
                }

                segments.append(segmentDir)
            }

            if !segments.isEmpty {
                // Sort segments within the day
                segmentsByDay[day] = segments.sorted { $0.path < $1.path }
            }
        }

        return segmentsByDay
    }

    /// Convert local segment path to server format
    /// Input: .../captures/2025-01-03/143022_300/
    /// Output: (day: "20250103", segment: "143022_300")
    private func convertSegmentPath(_ segmentURL: URL) -> (day: String, segment: String) {
        let segmentFolder = segmentURL.lastPathComponent  // "143022_300"
        let dayFolder = segmentURL.deletingLastPathComponent().lastPathComponent  // "2025-01-03"

        // Convert day format (YYYY-MM-DD -> YYYYMMDD)
        let day = dayFolder.replacingOccurrences(of: "-", with: "")

        // Folder name is already the segment key
        return (day, segmentFolder)
    }

    // MARK: - Storage Cleanup

    private func cleanupOldSegments() async {
        let retentionBytes = Int64(config.localRetentionMB) * 1024 * 1024
        let fm = FileManager.default

        // Collect all segments grouped by day
        let segmentsByDay = collectSegmentsByDay()
        guard !segmentsByDay.isEmpty else { return }

        // Flatten to list for cleanup (oldest first)
        var segments = segmentsByDay.keys.sorted().flatMap { day in
            segmentsByDay[day] ?? []
        }
        guard !segments.isEmpty else { return }

        // Calculate total size
        var totalSize: Int64 = 0
        var segmentSizes: [URL: Int64] = [:]

        for segmentURL in segments {
            let size = directorySize(segmentURL)
            segmentSizes[segmentURL] = size
            totalSize += size
        }

        Log.upload("Total storage: \(totalSize / 1024 / 1024) MB, limit: \(config.localRetentionMB) MB")

        // Cache server segments by day to avoid repeated queries
        var serverSegmentsCache: [String: [String: [ServerFileInfo]]] = [:]

        // Delete oldest uploaded segments until under limit
        // Keep at least the most recent segment
        while totalSize > retentionBytes && segments.count > 1 {
            let oldestSegment = segments.removeFirst()
            let (day, segment) = convertSegmentPath(oldestSegment)

            // Get server segments for this day (cached)
            if serverSegmentsCache[day] == nil {
                serverSegmentsCache[day] = await getServerSegments(day: day) ?? [:]
            }
            let serverSegments = serverSegmentsCache[day] ?? [:]

            // Check if this segment exists on server (has files)
            if serverSegments[segment] != nil {
                let size = segmentSizes[oldestSegment] ?? 0
                do {
                    try fm.removeItem(at: oldestSegment)
                    totalSize -= size
                    Log.upload("Deleted old segment: \(oldestSegment.lastPathComponent) (\(size / 1024) KB)")

                    // Clean up empty date directory
                    let dateDir = oldestSegment.deletingLastPathComponent()
                    if let contents = try? fm.contentsOfDirectory(atPath: dateDir.path), contents.isEmpty {
                        try? fm.removeItem(at: dateDir)
                    }
                } catch {
                    Log.upload("Failed to delete segment: \(error)")
                }
            }
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var size: Int64 = 0
        for fileURL in contents {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }

    /// Compute SHA256 hash of a file
    private func sha256(of fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Mic Priority Selection

    /// Mic metadata entry from mics.json
    private struct MicEntry: Codable {
        let name: String
        let file: String
        let startOffset: Double
        let duration: Double
    }

    /// Mics metadata from segment
    private struct MicsMetadata: Codable {
        let segmentDuration: Double
        let mics: [MicEntry]
    }

    /// Select mic files to upload based on priority and completeness
    /// Returns list of mic file URLs to include in upload (1 or 2 files)
    private func selectMicFilesForUpload(
        from allMicFiles: [URL],
        segmentDirectory: URL
    ) -> [URL] {
        // Read mics.json metadata
        let metadataURL = segmentDirectory.appendingPathComponent("mics.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(MicsMetadata.self, from: data) else {
            // No metadata - fallback to first mic file
            Log.upload("No mics.json found, using first mic file")
            return allMicFiles.isEmpty ? [] : [allMicFiles[0]]
        }

        guard !metadata.mics.isEmpty else {
            return []
        }

        // Create lookup from filename to URL
        var fileURLsByName: [String: URL] = [:]
        for url in allMicFiles {
            fileURLsByName[url.lastPathComponent] = url
        }

        // Sort mics by priority (order in config.microphonePriority)
        let priorityOrder = config.microphonePriority.map { $0.name }
        let sortedMics = metadata.mics.sorted { mic1, mic2 in
            let idx1 = priorityOrder.firstIndex(of: mic1.name) ?? Int.max
            let idx2 = priorityOrder.firstIndex(of: mic2.name) ?? Int.max
            return idx1 < idx2
        }

        // Get highest priority mic that has a file
        guard let topMic = sortedMics.first(where: { fileURLsByName[$0.file] != nil }),
              let topMicURL = fileURLsByName[topMic.file] else {
            // No matching files - return first available
            return allMicFiles.isEmpty ? [] : [allMicFiles[0]]
        }

        // Check if top mic has complete coverage.
        // A mic is considered "complete" if it started within 5s of segment start
        // (allowing for hot-swap delays on segment rotation) and captured at least
        // 90% of the segment duration (allowing for minor timing variations).
        // If incomplete, we upload a backup mic to cover potential gaps.
        let startThreshold: Double = 5.0
        let durationThreshold: Double = 0.9

        let isComplete = topMic.startOffset <= startThreshold &&
                         topMic.duration >= (metadata.segmentDuration * durationThreshold)

        if isComplete {
            // Top mic covers full segment - just upload it
            Log.upload("Mic \(topMic.name) has full coverage, uploading single mic")
            return [topMicURL]
        }

        // Top mic is partial - also include next-priority mic for gap coverage
        Log.upload("Mic \(topMic.name) is partial (offset: \(String(format: "%.1f", topMic.startOffset))s, duration: \(String(format: "%.1f", topMic.duration))s), including backup")

        // Find next-priority mic with a file
        var result = [topMicURL]
        for mic in sortedMics where mic.file != topMic.file {
            if let url = fileURLsByName[mic.file] {
                result.append(url)
                Log.upload("Adding backup mic: \(mic.name)")
                break
            }
        }

        return result
    }
}

// MARK: - Errors

public enum UploadError: Error, LocalizedError {
    case invalidURL
    case noFiles
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .noFiles:
            return "No files to upload"
        case .invalidResponse:
            return "Invalid server response"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

// MARK: - FileHandle Extension for Multipart

private extension FileHandle {
    /// Writes a simple form field to the multipart body
    func writeMultipartField(boundary: String, name: String, value: String) throws {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        try write(contentsOf: header.data(using: .utf8)!)
    }

    /// Writes the header for a file part (caller must write file contents + trailing \r\n)
    func writeMultipartFileHeader(boundary: String, filename: String, mimeType: String) throws {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        try write(contentsOf: header.data(using: .utf8)!)
    }
}

// TODO: Future preprocessing pipeline before upload:
// 1. Audio transcription via Whisper → audio.jsonl
// 2. Frame extraction and OCR → screen.jsonl
// 3. Upload processed files instead of raw media
