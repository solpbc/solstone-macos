// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// Metadata from one directory entry. Reading it leaves dataless files on their provider.
struct FolderSyncFile {
    var path: String
    var name: String
    var info: stat

    var isDirectory: Bool { info.st_mode & S_IFMT == S_IFDIR }
    var isRegular: Bool { info.st_mode & S_IFMT == S_IFREG }
    var isHidden: Bool { name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 }
    var isDataless: Bool { Self.isDataless(flags: info.st_flags) }
    var size: Int64 { Int64(info.st_size) }
    var modified: Date {
        Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
    }
    var modifiedMilliseconds: Int64 {
        Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
    }

    static func isDataless(flags: UInt32) -> Bool { flags & UInt32(SF_DATALESS) != 0 }

    /// A legacy iCloud stub stands for a sibling that may have no directory entry yet.
    var cloudStubTarget: String? {
        guard isRegular, name.hasPrefix("."), name.lowercased().hasSuffix(".icloud") else { return nil }
        let target = String(name.dropFirst().dropLast(".icloud".count))
        return target.isEmpty || target.hasPrefix(".") ? nil : target
    }

    static func probe(path: String) -> Self? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Self(path: path, name: (path as NSString).lastPathComponent, info: info)
    }
}

enum FolderSyncFiles {
    enum Listing: Equatable {
        case complete, denied, missing, deferred, failed
    }

    static func withAccess<Result>(to url: URL, _ work: () -> Result) -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return work()
    }

    static func directoryStatus(_ path: String) -> Listing {
        var info = stat()
        guard stat(path, &info) == 0 else { return classify(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .failed }
        return FolderSyncFile.isDataless(flags: info.st_flags) ? .deferred : .complete
    }

    static func canList(_ path: String) -> Bool {
        guard directoryStatus(path) == .complete, let handle = opendir(path) else { return false }
        closedir(handle)
        return true
    }

    /// Visit one level. A partial enumeration cannot establish that any unvisited file is gone.
    static func list(_ path: String, visit: (FolderSyncFile) -> Void) -> Listing {
        let status = directoryStatus(path)
        guard status == .complete else { return status }
        guard let handle = opendir(path) else { return classify(errno) }
        defer { closedir(handle) }
        var result: Listing = .complete
        while true {
            errno = 0
            guard let entry = readdir(handle) else { return errno == 0 ? result : .failed }
            guard let name = entryName(entry) else { continue }
            guard name != ".", name != ".." else { continue }
            let child = path + "/" + name
            var info = stat()
            guard lstat(child, &info) == 0 else {
                if errno != ENOENT { result = .failed }
                continue
            }
            visit(FolderSyncFile(path: child, name: name, info: info))
        }
    }

    static func hasSettled(modified: Date?, now: Date, delay: TimeInterval) -> Bool {
        modified.map { now.timeIntervalSince($0) >= delay } ?? false
    }

    /// Guard synchronous reads on this thread against eviction between a stat and an open/read.
    static func withoutMaterialization<Result>(_ work: () -> Result) -> Result? {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(type, scope)
        guard previous >= 0, setiopolicy_np(type, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return nil }
        defer { _ = setiopolicy_np(type, scope, previous) }
        return work()
    }

    private static func classify(_ code: Int32) -> Listing {
        switch code {
        case EPERM, EACCES: return .denied
        case ENOENT: return .missing
        default: return .failed
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
}
