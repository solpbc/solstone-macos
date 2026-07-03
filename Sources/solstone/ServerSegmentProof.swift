// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal struct SegmentHoldVerdict: Sendable, Equatable {
    let isHeld: Bool
    let reason: String
}

internal func proveServerHoldsUploadFiles(
    localSHAByFilename: [String: String],
    serverSegment: ServerSegmentInfo?
) -> SegmentHoldVerdict {
    guard let serverSegment else {
        return SegmentHoldVerdict(isHeld: false, reason: "not on server")
    }
    guard !localSHAByFilename.isEmpty else {
        return SegmentHoldVerdict(isHeld: true, reason: "held")
    }

    var serverFilesByEffectiveName: [String: ServerFileInfo] = [:]
    for file in serverSegment.files {
        let effectiveName = file.submittedName.isEmpty ? file.name : file.submittedName
        serverFilesByEffectiveName[effectiveName] = file
    }

    for filename in localSHAByFilename.keys.sorted() {
        guard let localSHA = localSHAByFilename[filename], !localSHA.isEmpty else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): empty local sha")
        }
        guard let serverFile = serverFilesByEffectiveName[filename] else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): missing on server")
        }
        guard serverFile.status == .present || serverFile.status == .relocated else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): \(serverFile.status.rawValue) status")
        }
        guard !serverFile.sha256.isEmpty else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): empty server sha")
        }
        guard serverFile.sha256 == localSHA else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): sha mismatch")
        }
    }

    return SegmentHoldVerdict(isHeld: true, reason: "held")
}
