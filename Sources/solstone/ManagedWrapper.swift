// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal enum ManagedWrapper {
    static let appOwnedChildMarker = "# managed-version: app-owned-child"

    static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func shellSingleUnquoted(_ token: String) -> String? {
        guard token.hasPrefix("'"), token.hasSuffix("'") else { return nil }

        let unescaped = token.replacingOccurrences(of: "'\\''", with: "'")
        return String(unescaped.dropFirst().dropLast())
    }

    static func script(forTarget target: String) -> String {
        """
        #!/bin/sh
        \(appOwnedChildMarker)
        exec \(shellSingleQuoted(target)) "$@"
        """
    }

    static func execTarget(fromLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "exec "
        let suffix = " \"$@\""
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else { return nil }

        let tokenStart = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        let tokenEnd = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
        guard tokenStart <= tokenEnd else { return nil }

        return shellSingleUnquoted(String(trimmed[tokenStart..<tokenEnd]))
    }
}
