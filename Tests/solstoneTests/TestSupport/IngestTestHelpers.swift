// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal func completeUploadResponseJSON(
    status: String = "ok",
    segment: String = "120000_300",
    existingSegment: String? = nil,
    segmentOriginal: String? = nil,
    descriptors: [(submitted: String, written: String, size: UInt64, sha256: String, disposition: String)] = [],
    meta: String = "{}"
) -> String {
    var parts: [String] = ["\"status\":\"\(status)\""]
    if status == "duplicate" {
        let existing = existingSegment ?? segment
        parts.append("\"existing_segment\":\"\(existing)\"")
    } else {
        parts.append("\"segment\":\"\(segment)\"")
    }
    if let segmentOriginal {
        parts.append("\"segment_original\":\"\(segmentOriginal)\"")
    }
    let descriptorStrings = descriptors.map { desc in
        "{\"submitted\":\"\(desc.submitted)\",\"written\":\"\(desc.written)\",\"size\":\(desc.size),\"sha256\":\"\(desc.sha256)\",\"disposition\":\"\(desc.disposition)\"}"
    }.joined(separator: ",")
    parts.append("\"file_descriptors\":[\(descriptorStrings)]")
    parts.append("\"meta\":\(meta)")
    return "{\(parts.joined(separator: ","))}"
}
