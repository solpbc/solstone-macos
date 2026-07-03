// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CryptoKit
import os
import SolstoneCore

/// File info returned by the server for a segment
public struct ServerFileInfo: Sendable {
    public let name: String           // Simplified name, e.g., "audio.m4a"
    public let submittedName: String  // Original filename as uploaded
    public let sha256: String
    public let size: Int
    public let status: ServerFileStatus
    public let currentPath: String?
}

public enum ServerFileStatus: String, Sendable {
    case present
    case relocated
    case missing
    case unknown
}

/// Segment info from server including collision resolution
public struct ServerSegmentInfo: Sendable {
    public let key: String           // Actual key on server (may differ if collision)
    public let originalKey: String?  // Original submitted key (if collision occurred)
    public let files: [ServerFileInfo]
}

/// Result of an upload attempt
public enum UploadResult: Sendable {
    case success(UploadSuccessInfo)
    case failure(Error)
    case skipped
    case notConfigured
}

public struct UploadSuccessInfo: Sendable, Equatable {
    public let status: IngestUploadStatus
    public let storedSegmentKey: String?
}

public enum IngestUploadStatus: Sendable, Equatable {
    case ok
    case collision
    case duplicate
    case unknown(String)
}

/// Upload errors
public enum UploadError: Error, LocalizedError {
    case invalidURL
    case noFiles
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "invalid journal address"
        case .noFiles:
            return "No files to upload"
        case .invalidResponse:
            return "invalid journal response"
        case .serverError(let code, let message):
            return "journal error (\(code)): \(message)"
        }
    }
}

/// Stateless networking client for uploads
/// All methods are thread-safe and can be called from any actor
public struct UploadClient: Sendable {
    private let session: URLSession

    public init(sessionConfiguration: URLSessionConfiguration? = nil) {
        let config: URLSessionConfiguration
        if let sessionConfiguration {
            config = sessionConfiguration
        } else {
            config = .default
            config.timeoutIntervalForRequest = 300  // 5 min for large files
            config.timeoutIntervalForResource = 600  // 10 min total
        }
        self.session = URLSession(configuration: config)
    }

    static func isLocalNetworkHost(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            return false
        }

        let normalizedHost = trimmedHost.hasSuffix(".") ? String(trimmedHost.dropLast()) : trimmedHost
        let lowercaseHost = normalizedHost.lowercased()

        if lowercaseHost == "localhost" || lowercaseHost == "::1" {
            return false
        }

        if lowercaseHost.contains(":") {
            if lowercaseHost.hasPrefix("fe80:") {
                return true
            }

            if lowercaseHost.hasPrefix("fc") || lowercaseHost.hasPrefix("fd") {
                return true
            }

            return false
        }

        let parts = lowercaseHost.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let octets = parts.compactMap { Int($0) }
            guard octets.count == 4, octets.allSatisfy({ 0...255 ~= $0 }) else {
                return false
            }

            switch (octets[0], octets[1]) {
            case (127, _):
                return false
            case (10, _):
                return true
            case (172, 16...31):
                return true
            case (192, 168):
                return true
            case (169, 254):
                return true
            case (100, 64...127):
                return true  // CGNAT / Tailscale (RFC 6598, 100.64.0.0/10)
            default:
                return false
            }
        }

        if lowercaseHost.hasSuffix(".local") {
            return true
        }

        return !lowercaseHost.contains(".")
    }

    static func errorMessage(for error: URLError, host: String) -> String {
        if isLocalNetworkHost(host) {
            switch error.code {
            case .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "Can't reach local network. Open System Settings → Privacy & Security → Local Network and allow solstone."
            default:
                break
            }
        }

        switch error.code {
        case .notConnectedToInternet:
            return "No internet connection"
        case .cannotFindHost:
            return "journal not found"
        case .cannotConnectToHost:
            return "can't reach your journal"
        case .timedOut:
            return "Connection timed out"
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Connection Test

    /// Test connection to server, returns error message if failed, nil on success
    public func testConnection(serverURL: String, serverKey: String) async -> String? {
        // Use segments endpoint with current date to test connection
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let today = dateFormatter.string(from: Date())
        let urlString = "\(serverURL)/app/observer/ingest/segments/\(today)"
        Logger.upload.info("testConnection: GET \(urlString, privacy: .public)")

        guard let url = URL(string: urlString) else {
            Logger.upload.info("testConnection: invalid URL")
            return "Invalid URL"
        }
        let host = url.host ?? ""

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10  // Quick timeout for connection test
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // Use ephemeral session for connection test (no caching)
        let testSession = URLSession(configuration: .ephemeral)
        defer { testSession.invalidateAndCancel() }

        do {
            Logger.upload.info("testConnection: sending request...")
            let (data, response) = try await testSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "<none>"
                Logger.upload.info("testConnection: HTTP \(httpResponse.statusCode, privacy: .public)")
                Logger.upload.info("testConnection: Content-Type: \(contentType, privacy: .public)")
                Logger.upload.info("testConnection: Body: \(bodyPreview, privacy: .public)")

                // Check if response is JSON (not HTML login page)
                if contentType.contains("text/html") || bodyPreview.contains("<!DOCTYPE") || bodyPreview.contains("<html") {
                    Logger.upload.info("testConnection: got HTML instead of JSON - endpoint may not exist")
                    return "journal returned a login page (restart solstone?)"
                }

                switch httpResponse.statusCode {
                case 200:
                    Logger.upload.info("testConnection: SUCCESS")
                    return nil  // Success
                case 401:
                    return "Invalid API key"
                case 403:
                    return "Observer disabled"
                case 404:
                    return "journal endpoint not found (update solstone?)"
                default:
                    return "journal error (\(httpResponse.statusCode))"
                }
            }
            return "Invalid response"
        } catch let error as URLError {
            Logger.upload.info("testConnection: URLError \(error.code.rawValue, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            return Self.errorMessage(for: error, host: host)
        } catch {
            Logger.upload.info("testConnection: error \(error, privacy: .public)")
            return error.localizedDescription
        }
    }

    // MARK: - Server Queries

    /// Get all segments with file info for a given day from the server
    /// Throws on non-200 or unparseable responses; returns empty array if day legitimately has no segments.
    public func getServerSegments(
        serverURL: String,
        serverKey: String,
        day: String
    ) async throws -> [ServerSegmentInfo] {
        let urlString = "\(serverURL)/app/observer/ingest/segments/\(day)"
        guard let url = URL(string: urlString) else {
            throw UploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UploadError.serverError(statusCode: -1, message: "segment listing")
            }
            guard httpResponse.statusCode == 200 else {
                throw UploadError.serverError(statusCode: httpResponse.statusCode, message: "segment listing")
            }
            guard let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw UploadError.invalidResponse
            }

            // Parse JSON: [{"key": "...", "original_key": "...", "files": [...]}]
            return segments.compactMap { seg -> ServerSegmentInfo? in
                guard let segmentKey = seg["key"] as? String,
                      let files = seg["files"] as? [[String: Any]] else {
                    return nil
                }

                let originalKey = seg["original_key"] as? String

                let fileInfos = files.compactMap { file -> ServerFileInfo? in
                    guard let name = file["name"] as? String,
                          let size = file["size"] as? Int else {
                        return nil
                    }
                    let submittedName = file["submitted_name"] as? String ?? name
                    let sha256 = file["sha256"] as? String ?? ""
                    let status = ServerFileStatus(rawValue: file["status"] as? String ?? "") ?? .unknown
                    let currentPath = file["current_path"] as? String
                    return ServerFileInfo(
                        name: name,
                        submittedName: submittedName,
                        sha256: sha256,
                        size: size,
                        status: status,
                        currentPath: currentPath
                    )
                }

                return ServerSegmentInfo(
                    key: segmentKey,
                    originalKey: originalKey,
                    files: fileInfos
                )
            }
        } catch let error as URLError {
            throw error
        } catch {
            Logger.upload.info("getServerSegments failed: \(error, privacy: .public)")
            throw error
        }
    }

    func buildObserverStatusRequest(
        serverURL: String,
        serverKey: String,
        paused: Bool,
        health: ObserverHealthSnapshot?
    ) throws -> URLRequest {
        let urlString = "\(serverURL)/app/observer/ingest/event"
        guard let url = URL(string: urlString) else {
            throw UploadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 5
        if let health {
            var payload: [String: Any] = [
                "tract": "observe",
                "event": "status",
                "paused": paused,
                "source": "heartbeat",
                "stream_type": health.streamType,
                "version": health.version,
                "uptime": health.uptimeSeconds,
                "pending_queue_depth": health.pendingQueueDepth,
                "recent_error_count": health.recentErrorCount,
            ]
            if let name = health.name {
                payload["name"] = name
            }
            if let lastSuccessfulSync = health.lastSuccessfulSync {
                payload["last_successful_sync"] = ISO8601DateFormatter().string(from: lastSuccessfulSync)
            }
            if let lastErrorReason = health.lastErrorReason {
                payload["last_error_reason"] = lastErrorReason
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } else {
            request.httpBody = try JSONSerialization.data(
                withJSONObject: [
                    "tract": "observe",
                    "event": "status",
                    "paused": paused,
                    "source": "heartbeat",
                ]
            )
        }
        return request
    }

    public func postObserverStatus(
        serverURL: String,
        serverKey: String,
        paused: Bool,
        health: ObserverHealthSnapshot?
    ) async throws {
        let request = try buildObserverStatusRequest(
            serverURL: serverURL,
            serverKey: serverKey,
            paused: paused,
            health: health
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw UploadError.serverError(
                statusCode: httpResponse.statusCode,
                message: errorMessage
            )
        }
    }

    // MARK: - Upload

    /// Upload a segment to the server
    public func uploadSegment(
        serverURL: String,
        serverKey: String,
        segmentURL: URL,
        day: String,
        segment: String,
        mediaFiles: [URL],
        metadataJSON: String? = nil
    ) async -> UploadResult {
        let urlString = "\(serverURL)/app/observer/ingest"
        guard let url = URL(string: urlString) else {
            return .failure(UploadError.invalidURL)
        }

        guard !mediaFiles.isEmpty else {
            return .failure(UploadError.noFiles)
        }

        let fm = FileManager.default

        // Debug logging
        let fileNames = mediaFiles.map { $0.lastPathComponent }.joined(separator: ", ")
        Logger.upload.info("POST day=\(day, privacy: .public) segment=\(segment, privacy: .public) platform=darwin files=[\(fileNames, privacy: .public)]")

        // Build multipart form data in a temporary file to avoid memory pressure
        let boundary = UUID().uuidString
        let tempURL = fm.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).tmp")

        do {
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

            // Write metadata if provided
            if let metadataJSON = metadataJSON {
                try fileHandle.writeMultipartField(boundary: boundary, name: "meta", value: metadataJSON)
                Logger.upload.info("  + meta: \(metadataJSON.prefix(200), privacy: .public)...")
            }

            // Stream each file to temp file
            for fileURL in mediaFiles {
                let filename = fileURL.lastPathComponent
                let mimeType = fileURL.pathExtension == "mp4" ? "video/mp4" : "audio/mp4"

                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                let fileSize = attrs?[.size] as? Int ?? 0
                Logger.upload.info("  + \(filename, privacy: .public) (\(fileSize, privacy: .public) bytes)")

                try fileHandle.writeMultipartFileHeader(boundary: boundary, filename: filename, mimeType: mimeType)

                // Stream file contents in chunks
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
            Logger.upload.info("Total request body: \(totalSize, privacy: .public) bytes")

            // Create request and upload
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.upload(for: request, fromFile: tempURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(UploadError.invalidResponse)
            }

            let responseBody = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            Logger.upload.info("Response: HTTP \(httpResponse.statusCode, privacy: .public) - \(responseBody, privacy: .public)")

            if httpResponse.statusCode == 200 {
                return .success(Self.parseUploadSuccessInfo(from: data))
            } else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(UploadError.serverError(statusCode: httpResponse.statusCode, message: errorMessage))
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            return .failure(error)
        }
    }

    // MARK: - File Comparison

    /// Strip segment prefix from filename (e.g., "143022_300_audio.m4a" -> "audio.m4a")
    public func stripSegmentPrefix(_ filename: String, segment: String) -> String {
        let prefix = "\(segment)_"
        if filename.hasPrefix(prefix) {
            return String(filename.dropFirst(prefix.count))
        }
        return filename
    }

    /// Compute SHA256 hash of a file using incremental streaming (no full-file memory load)
    public func sha256(of fileURL: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024  // 1 MB chunks
        while true {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func parseUploadSuccessInfo(from data: Data) -> UploadSuccessInfo {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return UploadSuccessInfo(status: .ok, storedSegmentKey: nil)
        }

        guard let rawStatus = object["status"] as? String else {
            return UploadSuccessInfo(status: .ok, storedSegmentKey: nil)
        }

        switch rawStatus {
        case "ok":
            return UploadSuccessInfo(
                status: .ok,
                storedSegmentKey: extractSegmentKey(from: object["segment"])
            )
        case "collision":
            return UploadSuccessInfo(
                status: .collision,
                storedSegmentKey: extractSegmentKey(from: object["segment"])
            )
        case "duplicate":
            return UploadSuccessInfo(
                status: .duplicate,
                storedSegmentKey: extractSegmentKey(from: object["existing_segment"])
            )
        default:
            return UploadSuccessInfo(
                status: .unknown(rawStatus),
                storedSegmentKey: extractSegmentKey(from: object["segment"]) ?? extractSegmentKey(from: object["existing_segment"])
            )
        }
    }

    private static func extractSegmentKey(from value: Any?) -> String? {
        if let key = value as? String, !key.isEmpty {
            return key
        }
        if let object = value as? [String: Any],
           let key = object["key"] as? String,
           !key.isEmpty {
            return key
        }
        return nil
    }
}

// MARK: - FileHandle Extension for Multipart

private extension FileHandle {
    func writeMultipartField(boundary: String, name: String, value: String) throws {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        try write(contentsOf: header.data(using: .utf8)!)
    }

    func writeMultipartFileHeader(boundary: String, filename: String, mimeType: String) throws {
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        try write(contentsOf: header.data(using: .utf8)!)
    }
}
