// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// Mark a segment as failed by renaming from .incomplete to .failed.
public func markIncompleteSegmentAsFailed(_ url: URL) async {
    let fm = FileManager.default
    let dirName = url.lastPathComponent

    guard dirName.hasSuffix(".incomplete") else { return }

    let failedName = String(dirName.dropLast(".incomplete".count)) + ".failed"
    let parentDir = url.deletingLastPathComponent()
    let failedURL = parentDir.appendingPathComponent(failedName)

    do {
        try fm.moveItem(at: url, to: failedURL)
        Logger.storage.warning("Marked segment as failed: \(dirName, privacy: .public) -> \(failedName, privacy: .public)")
    } catch {
        Logger.storage.error("Failed to mark segment as failed: \(error, privacy: .public)")
    }
}
