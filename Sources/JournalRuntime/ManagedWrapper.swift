// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal enum ManagedWrapper {
    static let appOwnedChildMarker = "# managed-version: app-owned-child"

    enum AliasReason: String, Equatable, Sendable, CustomStringConvertible {
        case metadataError
        case readError
        case decodeError
        case readlinkError
        case notRegularFile
        case symlink
        case unmarked
        case noncanonicalBody
        case targetOutsideRoot
        case wrapperDirectoryError
        case writeError
        case modeError
        case renameError

        var description: String { rawValue }
    }

    enum AliasReference: Equatable, Sendable {
        case determinate(pinnedGenerationKeys: Set<String>)
        case indeterminate(reason: AliasReason)
    }

    enum AliasLeafDecision: Equatable, Sendable {
        case absent
        case appOwned(target: String, mode: Int)
        case external(reason: AliasReason, reference: AliasReference)
    }

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

    static func canonicalScriptData(forTarget target: String) -> Data {
        Data((script(forTarget: target) + "\n").utf8)
    }

    static func canonicalTarget(fromExactScriptData data: Data) -> String? {
        guard let contents = String(data: data, encoding: .utf8) else { return nil }
        let lines = scriptLines(contents)
        guard let target = literalExecTarget(in: lines) else { return nil }
        return canonicalScriptData(forTarget: target) == data ? target : nil
    }

    static func scriptLines(_ contents: String) -> [Substring] {
        contents.split(separator: "\n", omittingEmptySubsequences: false)
    }

    static func containsAppOwnedChildMarker(in lines: [Substring]) -> Bool {
        lines.contains { line in
            let trimmedLeading = line.drop(while: { $0.isWhitespace })
            return trimmedLeading == appOwnedChildMarker
        }
    }

    static func literalExecTarget(in lines: [Substring]) -> String? {
        lines.lazy.compactMap { execTarget(fromLine: String($0)) }.first
    }

    static func solBinDereferencedTarget(in lines: [Substring]) -> String? {
        guard lines.contains(where: { execDereferencesSolBin(String($0)) }) else { return nil }
        return lines.reversed().lazy
            .compactMap { solBinAssignment(fromLine: String($0)) }
            .first
    }

    static func isUnderRoot(_ path: String, root: String) -> Bool {
        let pathComponents = normalizedPathComponents(path)
        let rootComponents = normalizedPathComponents(root)
        guard !rootComponents.isEmpty,
              pathComponents.count >= rootComponents.count else {
            return false
        }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
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

    /// True when the line is the `$SOL_BIN`-dereference exec form: `exec "$SOL_BIN" "$@"`.
    static func execDereferencesSolBin(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "exec \"$SOL_BIN\" \"$@\""
    }

    /// Extracts the single-quoted value of a `SOL_BIN='...'` assignment on one line.
    /// Returns nil for comments, non-assignments, or non-single-quoted values
    /// (so an unquoted or double-quoted value yields no target -> safe).
    static func solBinAssignment(fromLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }
        let prefix = "SOL_BIN="
        guard trimmed.hasPrefix(prefix) else { return nil }
        return shellSingleUnquoted(String(trimmed.dropFirst(prefix.count)))
    }

    private static func normalizedPathComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }
}
