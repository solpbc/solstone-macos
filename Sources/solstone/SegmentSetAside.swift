// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum SegmentSetAsideStage: String, Sendable {
    case metadataHandoff = "metadata_handoff"
    case nativeOwnership = "native_ownership"
    case duration = "duration"
    case listing = "listing"
    case remixTimeout = "remix_timeout"
    case remix = "remix"
    case reconstruction = "reconstruction"
    case metadataWrite = "metadata_write"
    case fileRename = "file_rename"
    case directoryRename = "directory_rename"
    case metadataSeal = "metadata_seal"
}

struct SegmentSetAsideRecord: Equatable, Sendable {
    var count: Int
    var lastStage: String?
    var lastEventAt: Date?
    static let empty = SegmentSetAsideRecord(count: 0, lastStage: nil, lastEventAt: nil)
    mutating func note(_ stage: String, at date: Date) {
        count += 1
        lastStage = stage
        lastEventAt = date
    }
    func ageSeconds(at now: Date) -> Int? {
        guard let lastEventAt else { return nil }
        return Int(now.timeIntervalSince(lastEventAt))
    }
    var stageToken: String { lastStage ?? "none" }
}

@MainActor
func applySegmentReconciliation(
    _ reconciliation: SegmentReconciliation,
    setLiveError: @MainActor (String?) -> Void,
    recordSetAside: @MainActor (String) -> Void,
    triggerSync: @MainActor () -> Void,
    incrementReconciled: @MainActor (Int) -> Void
) {
    switch reconciliation {
    case .failed(let stage):
        recordSetAside(stage)
    case .recovered(let n):
        incrementReconciled(n)
        triggerSync()
    case .normal, .audioLoss(_):
        triggerSync()
    }
}
