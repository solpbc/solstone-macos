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
        return FolderSyncFiles.canList(config) ? .present : .unreadable
    }

    /// Whether Obsidian's own list still points at a vault, from metadata alone so that
    /// opening Settings reads nothing inside a folder the owner hasn't chosen.
    static func looksLikeVault(_ root: URL) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(".obsidian").path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    static func walk(root: URL) -> ObsidianVaultWalkResult {
        FolderSyncFiles.withAccess(to: root) {
            let path = root.path
            let config = path + "/.obsidian"
            guard FolderSyncFiles.canList(path), FolderSyncFiles.canList(config) else { return .unreachable }
            var walk = ObsidianVaultWalk()
            descend(directory: path, relative: "", into: &walk)
            // The volume may have gone mid-walk; finding nothing then means nothing.
            guard !walk.rootUnreachable, FolderSyncFiles.canList(path), FolderSyncFiles.canList(config) else {
                return .unreachable
            }
            for path in walk.placeholderOnly where walk.notes[path] != nil {
                walk.notes[path]?.isPlaceholder = true
                walk.placeholderOnly.remove(path)
            }
            return .scanned(walk)
        }
    }

    private static func descend(directory: String, relative: String, into walk: inout ObsidianVaultWalk) {
        let result = FolderSyncFiles.list(directory) { entry in
            let name = entry.name
            let path = relative.isEmpty ? name : relative + "/" + name
            if entry.isDirectory {
                guard !name.hasPrefix("."), !skipsDirectory(named: name) else { return }
                if entry.isDataless {
                    walk.unreachableDirectories.insert(path)
                } else {
                    descend(directory: entry.path, relative: path, into: &walk)
                }
            } else if entry.isRegular {
                if name.hasPrefix(".") {
                    if let note = entry.cloudStubTarget, note.lowercased().hasSuffix(".md") {
                        walk.placeholderOnly.insert(relative.isEmpty ? note : relative + "/" + note)
                    }
                    return
                }
                guard name.lowercased().hasSuffix(".md") else { return }
                guard ObsidianWire.isSendablePath(path) else {
                    walk.unsendableNames += 1
                    return
                }
                walk.notes[path] = ObsidianVaultEntry(
                    mtimeMs: entry.modifiedMilliseconds,
                    size: entry.size,
                    fileID: UInt64(entry.info.st_ino),
                    isPlaceholder: entry.isDataless
                )
            }
        }
        guard result != .complete else { return }
        if relative.isEmpty {
            walk.rootUnreachable = true
        } else {
            walk.unreachableDirectories.insert(relative)
            if result != .deferred { walk.failedDirectories.insert(relative) }
        }
    }

    private static func skipsDirectory(named name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "templates" || lowered == "_templates"
    }
}
