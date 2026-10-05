// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

private let audioFrameCounters = ["received_frames", "accepted_frames", "dropped_frames"]

/// A complete observation must cover every retained counter. An older complete
/// zero cannot turn a later, larger lower bound into complete statistics.
func mergeAudioStatisticsFlags(_ older: [String: Any], _ newer: [String: Any]) -> [String: Bool] {
    guard older["statistics_available"] != nil || newer["statistics_available"] != nil
        || older["statistics_complete"] != nil || newer["statistics_complete"] != nil else { return [:] }
    let available = older["statistics_available"] as? Bool == true || newer["statistics_available"] as? Bool == true
    let complete = [older, newer].contains { candidate in
        candidate["statistics_available"] as? Bool == true && candidate["statistics_complete"] as? Bool == true
            && audioFrameCounters.allSatisfy {
                (candidate[$0] as? Int ?? 0) >= max(older[$0] as? Int ?? 0, newer[$0] as? Int ?? 0)
            }
    }
    return ["statistics_available": available, "statistics_complete": complete]
}

func mergeAudioFailures(_ older: [[String: Any]], _ newer: [[String: Any]]) -> [[String: Any]] {
    var failures: [[String: Any]] = []
    for failure in older + newer {
        if let index = failures.firstIndex(where: {
            $0["stage"] as? String == failure["stage"] as? String
                && $0["domain"] as? String == failure["domain"] as? String
                && $0["code"] as? Int == failure["code"] as? Int
        }) {
            failures[index]["count"] = max(failures[index]["count"] as? Int ?? 1, failure["count"] as? Int ?? 1)
        } else if failures.count < AudioCaptureRecorder.failureLimit { failures.append(failure) }
    }
    return failures
}

/// Merge durable capture evidence without blessing an earlier interrupted run.
/// Remix rows describe the current copy; one prior failure remains diagnostic.
func mergeAudioCaptureMetadata(_ older: [String: Any], _ newer: [String: Any]) -> [String: Any] {
    var merged = older.merging(newer) { _, new in new }
    let severity = ["finished": 0, "recording": 1, "unknown": 2, "interrupted": 3, "partial": 4, "failed": 5]
    if let oldState = older["state"] as? String,
       (severity[oldState] ?? 2) > (severity[newer["state"] as? String ?? "unknown"] ?? 2) { merged["state"] = oldState }
    if older["failures"] != nil || newer["failures"] != nil {
        merged["failures"] = mergeAudioFailures(older["failures"] as? [[String: Any]] ?? [], newer["failures"] as? [[String: Any]] ?? [])
    }
    for key in ["sources", "remix"] {
        let previousRows = older[key] as? [[String: Any]] ?? []
        var rows = Array(previousRows.prefix(AudioCaptureRecorder.sourceLimit))
        if previousRows.count > AudioCaptureRecorder.sourceLimit, (severity[merged["state"] as? String ?? "unknown"] ?? 2) < 4 { merged["state"] = "partial" }
        for row in newer[key] as? [[String: Any]] ?? [] {
            guard let id = row["source_id"] as? String else { continue }
            if let index = rows.firstIndex(where: { $0["source_id"] as? String == id }) {
                let previous = rows[index]
                var current = key == "sources" ? previous.merging(row) { _, new in new } : row
                if key == "sources" {
                    if let oldState = previous["state"] as? String, ["partial", "failed"].contains(oldState),
                       (severity[oldState] ?? 2) > (severity[row["state"] as? String ?? "unknown"] ?? 2) { current["state"] = oldState }
                    current["failures"] = mergeAudioFailures(previous["failures"] as? [[String: Any]] ?? [], row["failures"] as? [[String: Any]] ?? [])
                    let flags = mergeAudioStatisticsFlags(previous, row)
                    for (flag, value) in flags { current[flag] = value }
                    for counter in audioFrameCounters { current[counter] = max(previous[counter] as? Int ?? 0, row[counter] as? Int ?? 0) }
                    for flag in ["expected", "started"] { current[flag] = previous[flag] as? Bool == true || row[flag] as? Bool == true }
                    if flags["statistics_complete"] == true, previous["statistics_complete"] as? Bool == true,
                       row["statistics_complete"] as? Bool != true { current["writer_status"] = previous["writer_status"] }
                } else {
                    if let prior = previous["prior_outcome"] { current["prior_outcome"] = prior }
                    else if (previous["state"] as? String) != "complete" {
                        var firstFailure = previous
                        firstFailure.removeValue(forKey: "prior_outcome")
                        current["prior_outcome"] = firstFailure
                    }
                }
                rows[index] = current
            } else if rows.count < AudioCaptureRecorder.sourceLimit { rows.append(row) }
            else if (severity[merged["state"] as? String ?? "unknown"] ?? 2) < 4 { merged["state"] = "partial" }
        }
        if !rows.isEmpty { merged[key] = rows }
    }
    return merged
}
