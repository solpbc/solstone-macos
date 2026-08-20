// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CryptoKit
import os
import SolstoneCore

/// File info returned by the server for a segment
struct ServerFileInfo: Sendable {
    let name: String           // Simplified name, e.g., "audio.m4a"
    let submittedName: String  // Original filename as uploaded
    let sha256: String
    let size: UInt64
    let status: IngestProtocolV3.Custody
}

/// Segment info from server including collision resolution
struct ServerSegmentInfo: Sendable {
    let key: String           // Actual key on server (may differ if collision)
    let originalKey: String?  // Original submitted key (if collision occurred)
    let files: [ServerFileInfo]
}

/// Result of an upload attempt
enum UploadResult: Sendable {
    case success(UploadSuccessInfo)
    case failure(Error)
}

struct UploadSuccessInfo: Sendable, Equatable {
    let status: IngestProtocolV3.UploadStatus
    let storedSegmentKey: String
}

/// Upload errors
public enum UploadError: Error, LocalizedError {
    case invalidURL
    case noFiles
    case invalidRequest
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "invalid journal address"
        case .noFiles:
            return "No files to upload"
        case .invalidRequest:
            return "upload exceeds journal limits"
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
                return "can't reach your journal at this address. check that it's running and reachable."
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

    // MARK: - Protocol v3 reads

    func getManifest(serverURL: String) async throws -> IngestProtocolV3.Manifest {
        try await get(serverURL: serverURL, path: IngestProtocolV3.manifestPath, as: IngestProtocolV3.Manifest.self)
    }

    func getManifestDay(serverURL: String, day: String) async throws -> IngestProtocolV3.ManifestDay {
        let response = try await get(
            serverURL: serverURL,
            path: IngestProtocolV3.manifestDayPath(day),
            as: IngestProtocolV3.ManifestDay.self
        )
        try response.validate(expectedDay: day)
        return response
    }

    func getSegmentsDay(serverURL: String, day: String) async throws -> IngestProtocolV3.SegmentsDay {
        try await get(
            serverURL: serverURL,
            path: IngestProtocolV3.segmentsDayPath(day),
            as: IngestProtocolV3.SegmentsDay.self
        )
    }

    /// Checks the paired journal's v3 read route. This intentionally has no
    /// bearer credential: linked-device access is authenticated by the tunnel.
    public func testPairedIngestConnection(serverURL: String) async -> String? {
        guard let url = URL(string: "\(serverURL)\(IngestProtocolV3.manifestPath)") else {
            return "Invalid URL"
        }
        do {
            _ = try await getManifest(serverURL: serverURL)
            return nil
        } catch let error as URLError {
            return Self.errorMessage(for: error, host: url.host ?? "")
        } catch let UploadError.serverError(statusCode, _) {
            switch statusCode {
            case 403:
                return "this Mac is disabled"
            case 404:
                return "journal endpoint not found (update sol?)"
            default:
                return "journal error (\(statusCode))"
            }
        } catch let error as UploadError {
            return error.errorDescription ?? "Invalid response"
        } catch {
            return error.localizedDescription
        }
    }

    private func get<Response: Decodable>(serverURL: String, path: String, as _: Response.Type) async throws -> Response {
        guard let url = URL(string: "\(serverURL)\(path)") else {
            throw UploadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(IngestProtocolV3.headerValue, forHTTPHeaderField: IngestProtocolV3.headerName)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw UploadError.serverError(
                statusCode: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UploadError.invalidResponse
        }
    }

    func buildObserverStatusRequest(
        serverURL: String,
        serverKey: String,
        paused: Bool,
        health: ObserverHealthSnapshot?
    ) throws -> URLRequest {
        let urlString = "\(serverURL)/app/devices/ingest/event"
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
    func uploadSegment(
        serverURL: String,
        day: String,
        segment: String,
        mediaFiles: [URL],
        metadata: [String: IngestJSONValue]?,
        boundary: String = UUID().uuidString
    ) async -> UploadResult {
        guard !mediaFiles.isEmpty else {
            return .failure(UploadError.noFiles)
        }

        let fm = FileManager.default
        let fileNames = mediaFiles.map { $0.lastPathComponent }.joined(separator: ", ")
        Logger.upload.info("POST day=\(day, privacy: .public) segment=\(segment, privacy: .public) files=[\(fileNames, privacy: .public)]")
        let tempURL = fm.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).tmp")

        do {
            let prepared = try IngestV3UploadRequestBuilder.build(
                baseURL: serverURL,
                day: day,
                segment: segment,
                selectedFiles: mediaFiles,
                meta: metadata,
                boundary: boundary,
                bodyURL: tempURL
            )
            defer { try? fm.removeItem(at: tempURL) }

            let totalSize = try fm.attributesOfItem(atPath: tempURL.path)[.size] as? Int ?? 0
            Logger.upload.info("Total request body: \(totalSize, privacy: .public) bytes")

            let (data, response) = try await session.upload(for: prepared.request, fromFile: prepared.bodyURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(UploadError.invalidResponse)
            }

            let responseBody = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            Logger.upload.info("Response: HTTP \(httpResponse.statusCode, privacy: .public) - \(responseBody, privacy: .public)")

            if (200...299).contains(httpResponse.statusCode) {
                let parsed = try JSONDecoder().decode(IngestProtocolV3.UploadResponse.self, from: data)
                return .success(UploadSuccessInfo(status: parsed.status, storedSegmentKey: parsed.storedSegmentKey))
            } else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(UploadError.serverError(statusCode: httpResponse.statusCode, message: errorMessage))
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            return .failure(error)
        }
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

}
