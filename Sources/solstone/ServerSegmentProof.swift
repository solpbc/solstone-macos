// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal struct SegmentHoldVerdict: Sendable, Equatable {
    let isHeld: Bool
    let reason: String
}

/// Terminal statuses that prove reconcile convergence after name and SHA match.
/// `.processed` means the journal intentionally consumed the raw byte after verified
/// processing and deliberately does not keep that raw file on journal disk; it makes the
/// segment eligible for configured local cache cleanup, but does not mean the raw byte is
/// still stored.
internal func proveServerHoldsUploadFiles(
    localSHAByFilename: [String: String],
    serverSegment: ServerSegmentInfo?
) -> SegmentHoldVerdict {
    guard let serverSegment else {
        return SegmentHoldVerdict(isHeld: false, reason: "not on server")
    }
    guard !localSHAByFilename.isEmpty else {
        return SegmentHoldVerdict(isHeld: false, reason: "no local files to prove")
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
        guard serverFile.status == .present || serverFile.status == .processed else {
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
