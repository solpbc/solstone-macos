// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CryptoKit
import SolstoneCaptureCore

/// File info returned by the server for a segment
public struct ServerFileInfo: Sendable {
    public let name: String           // Simplified name, e.g., "audio.m4a"
    public let submittedName: String  // Original filename as uploaded
    public let sha256: String
    public let size: Int
}

/// Segment info from server including collision resolution
public struct ServerSegmentInfo: Sendable {
    public let key: String           // Actual key on server (may differ if collision)
    public let originalKey: String?  // Original submitted key (if collision occurred)
    public let files: [ServerFileInfo]
}

/// Result of an upload attempt
public enum UploadResult: Sendable {
    case success
    case failure(Error)
    case skipped
    case notConfigured
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

/// Stateless networking client for uploads
/// All methods are thread-safe and can be called from any actor
public struct UploadClient: Sendable {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 min for large files
        config.timeoutIntervalForResource = 600  // 10 min total
        self.session = URLSession(configuration: config)
    }

    // MARK: - Connection Test

    /// Test connection to server, returns error message if failed, nil on success
    public func testConnection(serverURL: String, serverKey: String) async -> String? {
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

                // Check if response is JSON (not HTML login page)
                if contentType.contains("text/html") || bodyPreview.contains("<!DOCTYPE") || bodyPreview.contains("<html") {
                    Log.upload("testConnection: got HTML instead of JSON - endpoint may not exist")
                    return "Server returned login page (restart server?)"
                }

                switch httpResponse.statusCode {
                case 200:
                    Log.upload("testConnection: SUCCESS")
                    return nil  // Success
                case 401:
                    return "Invalid API key"
                case 403:
                    return "Remote disabled"
                case 404:
                    return "Endpoint not found (server update needed?)"
                default:
                    return "Server error (\(httpResponse.statusCode))"
                }
            }
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

    // MARK: - Server Queries

    /// Get all segments with file info for a given day from the server
    /// Returns nil on error, empty array if day has no segments
    public func getServerSegments(
        serverURL: String,
        serverKey: String,
        day: String
    ) async -> [ServerSegmentInfo]? {
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
                // Parse JSON: [{"key": "...", "original_key": "...", "files": [...]}]
                if let segments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
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
                            return ServerFileInfo(name: name, submittedName: submittedName, sha256: sha256, size: size)
                        }

                        return ServerSegmentInfo(
                            key: segmentKey,
                            originalKey: originalKey,
                            files: fileInfos
                        )
                    }
                }
            }
        } catch {
            Log.upload("getServerSegments failed: \(error)")
        }

        return nil
    }

    // MARK: - Upload

    /// Upload a segment to the server
    public func uploadSegment(
        serverURL: String,
        serverKey: String,
        segmentURL: URL,
        day: String,
        segment: String,
        mediaFiles: [URL]
    ) async -> UploadResult {
        let urlString = "\(serverURL)/app/remote/ingest/\(serverKey)"
        guard let url = URL(string: urlString) else {
            return .failure(UploadError.invalidURL)
        }

        guard !mediaFiles.isEmpty else {
            return .failure(UploadError.noFiles)
        }

        let fm = FileManager.default

        // Debug logging
        let fileNames = mediaFiles.map { $0.lastPathComponent }.joined(separator: ", ")
        Log.upload("POST day=\(day) segment=\(segment) platform=darwin files=[\(fileNames)]")

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

            // Stream each file to temp file
            for fileURL in mediaFiles {
                let filename = fileURL.lastPathComponent
                let mimeType = fileURL.pathExtension == "mp4" ? "video/mp4" : "audio/mp4"

                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                let fileSize = attrs?[.size] as? Int ?? 0
                Log.upload("  + \(filename) (\(fileSize) bytes)")

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
            Log.upload("Total request body: \(totalSize) bytes")

            // Create request and upload
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

    /// Compute SHA256 hash of a file
    public func sha256(of fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
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
