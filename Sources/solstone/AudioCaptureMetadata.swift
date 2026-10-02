// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Merge durable capture evidence without blessing an earlier interrupted run.
/// Remix rows describe the current copy; one prior failure remains diagnostic.
func mergeAudioCaptureMetadata(_ older: [String: Any], _ newer: [String: Any]) -> [String: Any] {
    var merged = older.merging(newer) { _, new in new }
    let severity = ["finished": 0, "recording": 1, "unknown": 2, "interrupted": 3, "partial": 4, "failed": 5]
    if let oldState = older["state"] as? String,
       (severity[oldState] ?? 2) > (severity[newer["state"] as? String ?? "unknown"] ?? 2) { merged["state"] = oldState }
    for key in ["sources", "remix"] {
        var rows = older[key] as? [[String: Any]] ?? []
        for row in newer[key] as? [[String: Any]] ?? [] {
            guard let id = row["source_id"] as? String else { continue }
            if let index = rows.firstIndex(where: { $0["source_id"] as? String == id }) {
                var current = row
                let previous = rows[index]
                if key == "sources", (previous["state"] as? String) == "partial" || (previous["state"] as? String) == "failed" {
                    current = previous.merging(row) { _, new in new }
                    current["state"] = previous["state"]
                    let oldFailures = previous["failures"] as? [[String: Any]] ?? []
                    let newFailures = row["failures"] as? [[String: Any]] ?? []
                    current["failures"] = Array((oldFailures + newFailures).prefix(16))
                } else if key == "remix" {
                    if let prior = previous["prior_outcome"] { current["prior_outcome"] = prior }
                    else if (previous["state"] as? String) != "complete" {
                        var firstFailure = previous
                        firstFailure.removeValue(forKey: "prior_outcome")
                        current["prior_outcome"] = firstFailure
                    }
                }
                if key == "sources" {
                    for counter in ["received_frames", "accepted_frames", "dropped_frames"] {
                        if let old = previous[counter] as? Int {
                            current[counter] = max(old, row[counter] as? Int ?? 0)
                        }
                    }
                }
                rows[index] = current
            } else { rows.append(row) }
        }
        if !rows.isEmpty { merged[key] = rows }
    }
    return merged
}
