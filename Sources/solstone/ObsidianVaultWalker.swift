// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// What one scan found on disk. Nothing here has opened a note.
struct ObsidianVaultEntry: Equatable, Sendable {
    var mtimeMs: Int64
    var size: Int64
    var fileID: UInt64
    /// The content isn't local yet. A placeholder is not a note, and is never empty or deleted.
    var isPlaceholder: Bool
}

struct ObsidianVaultWalk: Equatable, Sendable {
    var notes: [String: ObsidianVaultEntry] = [:]
    /// Notes known only by an iCloud `.<name>.icloud` sibling.
    var placeholderOnly: Set<String> = []
    /// Folders this scan couldn't see into. Their notes are neither here nor gone.
    var unreachableDirectories: Set<String> = []
    /// The folders among those that failed to list, rather than not being on this device.
    var failedDirectories: Set<String> = []
    /// Notes skipped because the journal can't take their names.
    var unsendableNames = 0
    /// The vault's own top level couldn't be listed in full.
    var rootUnreachable = false

    func isUnderUnreachableDirectory(_ path: String) -> Bool {
        var ancestor = path[...]
        while let slash = ancestor.lastIndex(of: "/") {
            ancestor = ancestor[..<slash]
            if unreachableDirectories.contains(String(ancestor)) { return true }
        }
        return false
    }
}

enum ObsidianVaultWalkResult: Equatable, Sendable {
    /// The vault or its `.obsidian` folder couldn't be read. Nothing can be concluded.
    case unreachable
    case scanned(ObsidianVaultWalk)
}

enum ObsidianVaultWalker {
    /// `SF_DATALESS`: the file's content lives elsewhere and reading it would download it.
    static let datalessFlag: UInt32 = 0x4000_0000

    static func isDataless(flags: UInt32) -> Bool { flags & datalessFlag != 0 }

    enum ConfigFolder: Equatable, Sendable {
        case present, absent, unreadable
    }

    /// Whether a folder is an Obsidian vault: it has a `.obsidian` directory the app can read.
    static func configFolder(in root: URL) -> ConfigFolder {
        let config = root.appendingPathComponent(".obsidian").path
        var info = stat()
        guard lstat(config, &info) == 0 else {
            return errno == EPERM || errno == EACCES ? .unreadable : .absent
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .absent }
        guard let handle = opendir(config) else { return .unreadable }
        closedir(handle)
        return .present
    }

    /// Whether Obsidian's own list still points at a vault, from metadata alone so that
    /// opening Settings reads nothing inside a folder the owner hasn't chosen.
    static func looksLikeVault(_ root: URL) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(".obsidian").path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    static func walk(root: URL) -> ObsidianVaultWalkResult {
        let rootPath = root.path
        guard directoryOpens(rootPath), directoryOpens(rootPath + "/.obsidian") else { return .unreachable }
        var walk = ObsidianVaultWalk()
        descend(directory: rootPath, relative: "", into: &walk)
        // The volume may have gone mid-walk; finding nothing then means nothing.
        guard !walk.rootUnreachable, directoryOpens(rootPath), directoryOpens(rootPath + "/.obsidian") else { return .unreachable }
        for path in walk.placeholderOnly where walk.notes[path] != nil {
            walk.notes[path]?.isPlaceholder = true
            walk.placeholderOnly.remove(path)
        }
        return .scanned(walk)
    }

    private static func directoryOpens(_ path: String) -> Bool {
        guard let handle = opendir(path) else { return false }
        closedir(handle)
        return true
    }

    private static func descend(directory: String, relative: String, into walk: inout ObsidianVaultWalk) {
        func markUnreachable() {
            if relative.isEmpty {
                walk.rootUnreachable = true
            } else {
                walk.unreachableDirectories.insert(relative)
                walk.failedDirectories.insert(relative)
            }
        }
        guard let handle = opendir(directory) else {
            markUnreachable()
            return
        }
        defer { closedir(handle) }
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                // A listing cut short says nothing about the names it didn't reach.
                if errno != 0 { markUnreachable() }
                return
            }
            guard let name = entryName(entry), name != ".", name != ".." else { continue }
            let path = directory + "/" + name
            let relativePath = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno != ENOENT { markUnreachable() }
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard !name.hasPrefix("."), !skipsDirectory(named: name) else { continue }
                if isDataless(flags: info.st_flags) {
                    // Listing a dataless folder would download its listing. Its notes keep their rows.
                    walk.unreachableDirectories.insert(relativePath)
                    continue
                }
                descend(directory: path, relative: relativePath, into: &walk)
            case S_IFREG:
                if name.hasPrefix(".") {
                    if let note = iCloudPlaceholderTarget(name) {
                        walk.placeholderOnly.insert(relative.isEmpty ? note : relative + "/" + note)
                    }
                    continue
                }
                guard name.lowercased().hasSuffix(".md") else { continue }
                guard ObsidianWire.isSendablePath(relativePath) else {
                    walk.unsendableNames += 1
                    continue
                }
                walk.notes[relativePath] = ObsidianVaultEntry(
                    mtimeMs: Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000,
                    size: Int64(info.st_size),
                    fileID: UInt64(info.st_ino),
                    isPlaceholder: isDataless(flags: info.st_flags)
                )
            default:
                continue
            }
        }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String? {
        let length = Int(entry.pointee.d_namlen)
        return withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
                String(validating: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
            }
        }
    }

    private static func skipsDirectory(named name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "templates" || lowered == "_templates"
    }

    /// The note an iCloud placeholder like `.note.md.icloud` stands for, when it stands for a note.
    private static func iCloudPlaceholderTarget(_ name: String) -> String? {
        guard name.hasPrefix("."), name.lowercased().hasSuffix(".icloud") else { return nil }
        let inner = String(name.dropFirst().dropLast(".icloud".count))
        guard !inner.isEmpty, !inner.hasPrefix("."), inner.lowercased().hasSuffix(".md") else { return nil }
        return inner
    }
}
