// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal struct SegmentHoldVerdict: Sendable, Equatable {
    let isHeld: Bool
    let reason: String
}

internal struct LocalUploadFileProof: Sendable, Equatable {
    let sha256: String
    let size: UInt64
}

/// Terminal statuses that prove reconcile convergence after name and SHA match.
/// `.processed` means the journal intentionally consumed the raw byte after verified
/// processing and deliberately does not keep that raw file on journal disk; it makes the
/// segment eligible for configured local cache cleanup, but does not mean the raw byte is
/// still stored.
internal func proveServerHoldsUploadFiles(
    localFilesByFilename: [String: LocalUploadFileProof],
    serverSegment: ServerSegmentInfo?
) -> SegmentHoldVerdict {
    guard let serverSegment else {
        return SegmentHoldVerdict(isHeld: false, reason: "not on server")
    }
    guard !localFilesByFilename.isEmpty else {
        return SegmentHoldVerdict(isHeld: false, reason: "no local files to prove")
    }

    var serverFilesByEffectiveName: [String: ServerFileInfo] = [:]
    for file in serverSegment.files {
        let effectiveName = file.submittedName.isEmpty ? file.name : file.submittedName
        serverFilesByEffectiveName[effectiveName] = file
    }

    for filename in localFilesByFilename.keys.sorted() {
        guard let localFile = localFilesByFilename[filename], !localFile.sha256.isEmpty else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): empty local sha")
        }
        guard let serverFile = serverFilesByEffectiveName[filename] else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): missing on server")
        }
        guard serverFile.status.provesHold else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): non-held custody")
        }
        guard !serverFile.sha256.isEmpty else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): empty server sha")
        }
        guard serverFile.sha256 == localFile.sha256 else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): sha mismatch")
        }
        guard serverFile.size == localFile.size else {
            return SegmentHoldVerdict(isHeld: false, reason: "\(filename): size mismatch")
        }
    }

    return SegmentHoldVerdict(isHeld: true, reason: "held")
}
