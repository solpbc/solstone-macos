// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Walks up from `start` to the nearest ancestor (inclusive of `start`) whose
/// path component has the `app` extension, returning that URL. Returns nil if no
/// such ancestor exists. Pure — no Bundle/FileManager/IO; safe to unit-test on
/// constructed URLs.
public func enclosingAppURL(from start: URL) -> URL? {
    var current = start
    while true {
        if current.pathExtension == "app" {
            return current
        }
        let parent = current.deletingLastPathComponent()
        // Terminate at filesystem root: deletingLastPathComponent stops changing the path.
        if parent.path == current.path {
            return nil
        }
        current = parent
    }
}
