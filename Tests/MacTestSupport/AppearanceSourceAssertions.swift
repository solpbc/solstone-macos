// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The sun arc and the mark follow the owner's system appearance; no source sets it.
/// Each package scans its own source directories with this one rule.
public enum AppearanceSourceAssertions {
    public static let forbiddenTokens = [
        "preferredColorScheme", ".colorScheme(", "environment(\\.colorScheme", "NSApp.appearance",
        "NSApplication.shared.appearance", ".appearance =", "NSAppearance.current"
    ]

    /// Returns one line per violation. A comment may name what code must not do; code may not do it.
    public static func violations(in source: String, file: String) -> [String] {
        let codeLines = source
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        return forbiddenTokens.compactMap { token in
            codeLines.contains { $0.contains(token) } ? "\(file) sets the appearance via \(token)" : nil
        }
    }

    /// Swift files under `directory`, or nil when it cannot be read. Callers require a non-empty result
    /// so a moved directory can never pass as a clean scan.
    public static func swiftFiles(under directory: URL) -> [URL]? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
