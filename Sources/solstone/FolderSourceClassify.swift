// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation

/// Deterministic file classification, partial-download / junk filtering, symlink
/// confinement, bounded LCS note net-diff detection, and folder overlap checking.
enum FolderSourceClassify {
    private static let partialSuffixes = [
        ".crdownload",
        ".part",
        ".download",
        ".opdownload",
        ".filepart",
        ".tmp",
    ]

    private static let junkNames: Set<String> = [
        "thumbs.db",
        "desktop.ini",
        "ehthumbs.db",
        ".ds_store",
        "icon\r",
    ]

    /// Whether a directory entry looks like an unfinished download or temporary save
    /// that must wait until it finishes (including Safari `.download` packages).
    static func isPartialDownload(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return partialSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Whether a directory entry is a hidden dotfile, OS metadata junk, or temporary lock file.
    static func isJunkEntry(_ fileName: String) -> Bool {
        if fileName.isEmpty || fileName.hasPrefix(".") || fileName.hasPrefix("~$") || fileName.hasSuffix("~") {
            return true
        }
        if fileName.hasPrefix("#") && fileName.hasSuffix("#") {
            return true
        }
        let lower = fileName.lowercased()
        if lower.hasSuffix(".swp") || lower.hasSuffix(".swo") || lower.hasSuffix(".swx") {
            return true
        }
        return junkNames.contains(lower)
    }

    /// Whether a relative forward-slash path satisfies the Protocol v3 path contract.
    static func isValidRelativePath(_ relPath: String) -> Bool {
        guard !relPath.isEmpty, relPath.utf8.count <= FolderSourceWireConstants.maxPathBytes else {
            return false
        }
        guard !relPath.hasPrefix("/"), !relPath.hasSuffix("/"), !relPath.contains("\\") else {
            return false
        }
        guard !relPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return false
        }
        for component in relPath.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." {
                return false
            }
        }
        return true
    }

    /// Whether a symlink resolves inside `canonicalRoot`. Broken symlinks or targets
    /// escaping the chosen folder return `false`.
    static func symlinkStaysInside(canonicalRoot: String, entryPath: String) -> Bool {
        guard let resolved = realpathString(entryPath) else { return false }
        return resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/")
    }

    static func realpathString(_ path: String) -> String? {
        guard let cstr = Darwin.realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }

    /// Classify UTF-8 text bytes into `.notes`, `.documents`, or `.other` per triage ruleset v8.
    /// `structured_prose`: >= 1,500 words, >= 70% prose, >= 2 ATX heading levels.
    /// `long_prose`: >= 5,000 words, >= 70% prose.
    static func classifyTextFile(_ data: Data, supported: FolderSupportedList) -> FolderFileKind {
        if Int64(data.count) > supported.maxNoteBytes {
            return .documents
        }
        if data.contains(0) {
            return .other
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .other
        }
        var totalWords = 0
        var proseLines = 0
        var nonEmptyLines = 0
        var headingLevels: Set<Int> = []
        var inFence = false

        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                nonEmptyLines += 1
                return
            }
            nonEmptyLines += 1
            if inFence { return }

            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                headingLevels.insert(hashes)
                let rest = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
                totalWords += wordCount(rest)
                proseLines += 1
                return
            }

            let words = wordCount(line)
            totalWords += words
            let isListOrTable = line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("|")
                || line.hasPrefix("> ")
            if !isListOrTable || words >= 6 {
                proseLines += 1
            }
        }

        let proseOK = nonEmptyLines > 0 && proseLines * 100 >= nonEmptyLines * 70
        let longProse = proseOK && totalWords >= supported.longProseMinWords
        let structuredProse = proseOK
            && totalWords >= supported.structuredProseMinWords
            && headingLevels.count >= supported.structuredProseMinHeadingLevels
        return (longProse || structuredProse) ? .documents : .notes
    }

    private static func wordCount(_ line: String) -> Int {
        line.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Deterministic sorting table: assigns a file kind and decides whether bytes travel
    /// (`.content`), only details travel (`.metadataOnly`), or the file is skipped (`.ignore`).
    static func classifyFile(
        extension ext: String?,
        sizeBytes: Int64,
        isScreenshot: Bool,
        noteBytes: Data?,
        kinds: FolderKinds,
        supported: FolderSupportedList
    ) -> (FolderFileKind, FolderDeliveryMode) {
        let lowerExt = (ext ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let isImage = supported.isImageExtension(lowerExt)

        let fileKind: FolderFileKind
        if isScreenshot && isImage {
            fileKind = .screenshots
        } else if supported.noteExtensions.contains(lowerExt) {
            if sizeBytes > supported.maxNoteBytes {
                fileKind = .documents
            } else if let noteBytes {
                fileKind = classifyTextFile(noteBytes, supported: supported)
            } else {
                fileKind = .notes
            }
        } else if supported.documentExtensions.contains(lowerExt) {
            fileKind = .documents
        } else if supported.transcriptExtensions.contains(lowerExt) {
            fileKind = .transcripts
        } else if isImage {
            fileKind = .photos
        } else {
            fileKind = .other
        }

        let withinSize = sizeBytes >= 0 && sizeBytes <= supported.maxContentBytes
        let delivery: FolderDeliveryMode
        if fileKind == .other {
            delivery = kinds.other ? .metadataOnly : .ignore
        } else if kinds.includes(fileKind) && withinSize {
            delivery = .content
        } else if kinds.other {
            delivery = .metadataOnly
        } else {
            delivery = .ignore
        }
        return (fileKind, delivery)
    }

    /// Compute a compact net line diff between `before` and `after`.
    /// Returns `nil` when the net line content is unchanged (including revert-to-baseline).
    static func netLineDiff(before: String, after: String) -> String? {
        if before == after { return nil }
        let oldLines = splitLines(before)
        let newLines = splitLines(after)

        var prefix = 0
        while prefix < oldLines.count && prefix < newLines.count && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var oldEnd = oldLines.count
        var newEnd = newLines.count
        while oldEnd > prefix && newEnd > prefix && oldLines[oldEnd - 1] == newLines[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }

        let oldMid = Array(oldLines[prefix..<oldEnd])
        let newMid = Array(newLines[prefix..<newEnd])
        var out = ""

        if oldMid.count * newMid.count <= 64_000 {
            let m = oldMid.count
            let n = newMid.count
            var dp = Array(repeating: 0, count: (m + 1) * (n + 1))
            let idx = { (i: Int, j: Int) in i * (n + 1) + j }
            if m > 0 && n > 0 {
                for i in stride(from: m - 1, through: 0, by: -1) {
                    for j in stride(from: n - 1, through: 0, by: -1) {
                        if oldMid[i] == newMid[j] {
                            dp[idx(i, j)] = dp[idx(i + 1, j + 1)] + 1
                        } else {
                            dp[idx(i, j)] = max(dp[idx(i + 1, j)], dp[idx(i, j + 1)])
                        }
                    }
                }
            }
            var i = 0
            var j = 0
            while i < m && j < n {
                if oldMid[i] == newMid[j] {
                    i += 1
                    j += 1
                } else if dp[idx(i + 1, j)] >= dp[idx(i, j + 1)] {
                    out += "- \(oldMid[i])\n"
                    i += 1
                } else {
                    out += "+ \(newMid[j])\n"
                    j += 1
                }
            }
            while i < m {
                out += "- \(oldMid[i])\n"
                i += 1
            }
            while j < n {
                out += "+ \(newMid[j])\n"
                j += 1
            }
        } else {
            for line in oldMid { out += "- \(line)\n" }
            for line in newMid { out += "+ \(line)\n" }
        }

        return out.isEmpty ? nil : out
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        text.enumerateLines { line, _ in lines.append(line) }
        return lines
    }

    /// Normalize a path for overlap comparison without touching or hydrating files inside it.
    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = realpathString(expanded) ?? URL(fileURLWithPath: expanded).standardizedFileURL.path
        if resolved.count > 1 && resolved.hasSuffix("/") {
            return String(resolved.dropLast())
        }
        return resolved
    }

    /// Whether two canonical directory paths are equal or one contains the other.
    static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aPrefix = a == "/" ? "/" : a + "/"
        let bPrefix = b == "/" ? "/" : b + "/"
        return a.hasPrefix(bPrefix) || b.hasPrefix(aPrefix)
    }

    enum OverlapCheckResult: Equatable, Sendable {
        case none
        case alreadyAdded(id: String, name: String)
        case overlap(FolderOverlapInfo)
    }

    /// Check candidate path against configured folders, Obsidian vault, and Screenshots folder.
    static func detectOverlap(
        candidatePath: String,
        obsidian: (path: String, name: String)?,
        screenshots: (path: String, name: String)?,
        existingFolders: [(id: String, path: String, name: String)]
    ) -> OverlapCheckResult {
        let candidate = canonicalPath(candidatePath)
        for existing in existingFolders {
            let norm = canonicalPath(existing.path)
            if candidate == norm {
                return .alreadyAdded(id: existing.id, name: existing.name)
            }
            if pathsOverlap(candidate, norm) {
                return .overlap(FolderOverlapInfo(targetKind: .folder, targetName: existing.name, targetFolderID: existing.id))
            }
        }
        if let obsidian, pathsOverlap(candidate, canonicalPath(obsidian.path)) {
            return .overlap(FolderOverlapInfo(targetKind: .obsidian, targetName: obsidian.name, targetFolderID: nil))
        }
        if let screenshots, pathsOverlap(candidate, canonicalPath(screenshots.path)) {
            return .overlap(FolderOverlapInfo(targetKind: .screenshots, targetName: screenshots.name, targetFolderID: nil))
        }
        return .none
    }

    /// Stable client-assigned folder ID matching `^[a-z0-9][a-z0-9_-]{0,63}$`.
    static func makeFolderID(name: String, canonicalPath: String) -> String {
        var slug = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
            if slug.count >= 40 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "folder" }
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        let hex8 = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(slug)-\(hex8)"
    }

    /// Clean display name for wire `meta.folder.name` (1..=128 UTF-8 bytes, non-blank, no control chars).
    static func usableFolderName(_ raw: String) -> String {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Folder" }
        if cleaned.utf8.count <= FolderSourceWireConstants.maxFolderNameBytes {
            return cleaned
        }
        var end = cleaned.startIndex
        var bytes = 0
        for idx in cleaned.indices {
            let step = String(cleaned[idx]).utf8.count
            if bytes + step > FolderSourceWireConstants.maxFolderNameBytes { break }
            bytes += step
            end = cleaned.index(after: idx)
        }
        let truncated = String(cleaned[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated.isEmpty ? "Folder" : truncated
    }

    /// Friendly display path relative to the owner's home directory using ` › ` separators.
    static func displayPath(_ folderPath: String, homePath: String) -> String {
        let normFolder = canonicalPath(folderPath)
        let normHome = canonicalPath(homePath)
        let relative: String
        if normFolder == normHome {
            relative = URL(fileURLWithPath: normFolder).lastPathComponent
        } else if normFolder.hasPrefix(normHome + "/") {
            relative = String(normFolder.dropFirst(normHome.count + 1))
        } else {
            relative = normFolder
        }
        let parts = relative.split(separator: "/").map(String.init)
        return parts.isEmpty ? normFolder : parts.joined(separator: " › ")
    }

    /// Format byte counts compactly for preview (`46 MB`, `1.2 GB`, `820 KB`).
    static func formatBytes(_ bytes: Int64) -> String {
        let b = max(0, bytes)
        let kb: Double = 1_000
        let mb: Double = 1_000_000
        let gb: Double = 1_000_000_000
        if Double(b) >= gb {
            return String(format: "%.1f GB", Double(b) / gb)
        }
        if Double(b) >= mb {
            let val = Double(b) / mb
            return val >= 10 ? String(format: "%.0f MB", val) : String(format: "%.1f MB", val)
        }
        if Double(b) >= kb {
            return String(format: "%.0f KB", Double(b) / kb)
        }
        return "\(b) B"
    }
}
