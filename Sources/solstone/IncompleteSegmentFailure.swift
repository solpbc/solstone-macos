// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// The first free set-aside name for `stem` in `parent`: `{stem}.failed`, or `{stem}.{n}.failed` (n from 2)
/// when that name is taken. An existing set-aside folder is never replaced, and a second failure under the
/// same name never blocks the first from being set aside.
func freeFailedSegmentURL(parent: URL, stem: String) -> URL {
    var failedURL = parent.appendingPathComponent("\(stem).failed")
    var suffix = 1
    var info = stat()
    while lstat(failedURL.path, &info) == 0 {
        suffix += 1
        failedURL = parent.appendingPathComponent("\(stem).\(suffix).failed")
    }
    return failedURL
}

/// Mark a segment as failed by renaming from .incomplete to the first free .failed name.
@discardableResult
public func markIncompleteSegmentAsFailed(_ url: URL) async -> Bool {
    let fm = FileManager.default
    let dirName = url.lastPathComponent

    guard dirName.hasSuffix(".incomplete") else { return dirName.hasSuffix(".failed") }

    let stem = String(dirName.dropLast(".incomplete".count))
    let failedURL = freeFailedSegmentURL(parent: url.deletingLastPathComponent(), stem: stem)
    let failedName = failedURL.lastPathComponent

    do {
        try fm.moveItem(at: url, to: failedURL)
        Logger.storage.warning("Marked segment as failed: \(dirName, privacy: .public) -> \(failedName, privacy: .public)")
        return true
    } catch {
        Logger.storage.error("Failed to mark segment as failed: \(error, privacy: .public)")
        return false
    }
}

/// True when a set-aside folder holds nothing but bookkeeping: no file, or only `.DS_Store`, a
/// `*_meta.json` and the capture zone. Such a folder has no recording to deliver or keep.
/// Anything else, a subfolder included, counts as a recording. A folder that can't be read is kept.
func setAsideFolderHoldsNoRecording(_ url: URL) -> Bool {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
    return names.allSatisfy { name in
        name == ".DS_Store" || name == StorageManager.captureZoneFileName || name.hasSuffix("_meta.json")
    }
}
