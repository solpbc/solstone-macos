// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

public func updateAnnouncementVersion(
    for status: DurableUpdateStatus,
    lastAnnounced: String?
) -> String? {
    let version: String? = switch status {
    case .available(let version, _), .staged(let version, _):
        version
    case .failedWithAvailable, .deferred, .failed, .upToDate, .idle:
        nil
    }

    guard version != lastAnnounced else { return nil }
    return version
}
