// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Walks the finite `pathComponents` of `start` to return its nearest `.app`
/// ancestor as a directory-form URL. Answers only absolute file URLs.
/// Pure — no Bundle/FileManager/IO; safe to unit-test on constructed URLs.
public func enclosingAppURL(from start: URL) -> URL? {
    let components = start.standardized.pathComponents
    guard start.isFileURL, components.first == "/" else { return nil }
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    var nearest: URL?
    for component in components.dropFirst() {
        current = current.appendingPathComponent(component, isDirectory: true)
        if current.pathExtension == "app" {
            nearest = current
        }
    }
    return nearest
}
