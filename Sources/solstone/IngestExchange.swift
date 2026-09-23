// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct IngestServerError: Sendable, Equatable {
    public var statusCode: Int
    public var reasonCode: String?
    public var bodyStatus: String?
    public var failedDisposition: IngestProtocolV3.UploadFileDisposition?

    public init(
        statusCode: Int,
        reasonCode: String? = nil,
        bodyStatus: String? = nil,
        failedDisposition: IngestProtocolV3.UploadFileDisposition? = nil
    ) {
        self.statusCode = statusCode
        self.reasonCode = reasonCode
        self.bodyStatus = bodyStatus
        self.failedDisposition = failedDisposition
    }
}

internal struct IngestErrorBody: Decodable, Sendable {
    let status: String?
    let reasonCode: String?

    enum CodingKeys: String, CodingKey {
        case status
        case reasonCode = "reason_code"
    }
}

internal func parseIngestErrorBody(_ data: Data) -> (status: String?, reasonCode: String?) {
    guard let parsed = try? JSONDecoder().decode(IngestErrorBody.self, from: data) else {
        return (nil, nil)
    }
    return (parsed.status, parsed.reasonCode)
}

public enum DeviceScope: Sendable, Equatable {
    case revoked
    case notServing
    case journalRefused(reasonCode: String)
}

public enum SegmentScope: Sendable, Equatable {
    case deterministic(status: Int, reasonCode: String?)
    case receivedNotWritten
    case segmentRemoved
}

public enum UploadAttemptClass: Sendable, Equatable {
    case deviceScoped(DeviceScope)
    case segmentScoped(SegmentScope)
    case transport
}

public enum DayReadClass: Error, Sendable, Equatable {
    case journalRejectedDay(day: String, reasonCode: String)
    case notServing
    case journalRefused(reasonCode: String)
    case revoked
    case transport
    case undecoded
    case listingFailed
}

public func classifyUpload(_ error: Error) -> UploadAttemptClass {
    if error is URLError {
        return .transport
    }

    if let uploadError = error as? UploadError {
        switch uploadError {
        case .invalidURL, .noFiles, .invalidRequest, .invalidResponse:
            return .transport
        case .serverError(let serverError):
            let statusCode = serverError.statusCode
            let reasonCode = serverError.reasonCode

            if statusCode == 403 {
                return .deviceScoped(.revoked)
            }
            if statusCode == 404 || statusCode == 426 {
                return .deviceScoped(.notServing)
            }
            if statusCode == 409 && (reasonCode == "pairing_identity_unavailable" || reasonCode == "foreign_stream_binding") {
                return .deviceScoped(.journalRefused(reasonCode: reasonCode!))
            }
            if statusCode == 503 {
                if let reasonCode {
                    return .deviceScoped(.journalRefused(reasonCode: reasonCode))
                } else {
                    return .transport
                }
            }
            if reasonCode == "segment_removed" {
                return .segmentScoped(.segmentRemoved)
            }
            if serverError.failedDisposition == .receivedNotWritten {
                return .segmentScoped(.receivedNotWritten)
            }
            if serverError.failedDisposition != nil || ((200...299).contains(statusCode) && serverError.bodyStatus == nil && reasonCode == nil) {
                return .segmentScoped(.deterministic(status: statusCode, reasonCode: nil))
            }
            if statusCode == 413 {
                return .segmentScoped(.deterministic(status: 413, reasonCode: reasonCode))
            }
            if let reasonCode {
                return .segmentScoped(.deterministic(status: statusCode, reasonCode: reasonCode))
            }
            return .transport
        }
    }

    return .transport
}

public func classifyDayRead(_ error: Error, day: String) -> DayReadClass {
    if error is URLError {
        return .transport
    }

    if let uploadError = error as? UploadError {
        switch uploadError {
        case .invalidURL, .noFiles, .invalidRequest:
            return .transport
        case .invalidResponse:
            return .undecoded
        case .serverError(let serverError):
            let statusCode = serverError.statusCode
            let reasonCode = serverError.reasonCode

            if statusCode == 403 {
                return .revoked
            }
            if statusCode == 404 || statusCode == 426 {
                return .notServing
            }
            if statusCode == 409 && reasonCode == "ambiguous_segment_file_name" {
                return .journalRejectedDay(day: day, reasonCode: "ambiguous_segment_file_name")
            }
            if statusCode == 500 && reasonCode == "journal_read_failed" {
                return .journalRejectedDay(day: day, reasonCode: "journal_read_failed")
            }
            if statusCode == 409 && reasonCode == "stream_binding_incomplete" {
                return .notServing
            }
            if statusCode == 409 && (reasonCode == "pairing_identity_unavailable" || reasonCode == "foreign_stream_binding") {
                return .journalRefused(reasonCode: reasonCode!)
            }
            if statusCode == 503 {
                if let reasonCode {
                    return .journalRefused(reasonCode: reasonCode)
                } else {
                    return .transport
                }
            }
            if reasonCode != nil {
                return .listingFailed
            }
            return .transport
        }
    }

    return .transport
}
