// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreFoundation
import CoreServices
import CryptoKit
import Darwin
import Foundation

enum ScreenshotMac {
    static let captureDomain = "com.apple.screencapture"
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    static let isScreenCaptureName = "kMDItemIsScreenCapture"
    static let stableAfter: TimeInterval = 2

    static func desktopURL() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func sameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func systemFolder() -> ScreenshotFolder {
        let raw = locationSetting(
            screenshot: CFPreferencesCopyAppValue("location-screenshot" as CFString, captureDomain as CFString) as? String,
            general: CFPreferencesCopyAppValue("location" as CFString, captureDomain as CFString) as? String
        )
        let expanded = raw.map { ($0 as NSString).expandingTildeInPath }
        let url = expanded.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? desktopURL()
        return folder(url)
    }

    /// Where this Mac saves a screenshot. Since macOS 27 the screenshot tool's own options write
    /// `location-screenshot` beside `location`, and a screenshot follows the first: with only
    /// `location` changed, screenshots kept going to the Desktop.
    static func locationSetting(screenshot: String?, general: String?) -> String? {
        if let screenshot, !screenshot.isEmpty { return screenshot }
        if let general, !general.isEmpty { return general }
        return nil
    }

    static func folder(_ url: URL) -> ScreenshotFolder {
        let standard = url.standardizedFileURL
        return ScreenshotFolder(
            path: standard.path,
            name: standard.lastPathComponent,
            isDesktop: sameFolder(standard, desktopURL())
        )
    }

    static func openFilesSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
        ]
        for text in urls {
            guard let url = URL(string: text) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    /// A boolean stored as a property-list xattr value.
    static func plistBool(_ data: Data) -> Bool {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? Bool ?? false
    }
}

/// What reading a file found, kept while its size and modification date stay the same, so a
/// folder of screenshots is hashed once rather than on every look.
final class ScreenshotReadCache: @unchecked Sendable {
    struct Key: Hashable {
        var path: String
        var size: Int
        var modified: Date
        var device: dev_t
        var inode: ino_t
    }

    struct Entry {
        var header: Data
        var sha256: String
        var pixels: Int64?
    }

    private let lock = NSLock()
    private var entries: [String: (key: Key, entry: Entry)] = [:]

    func entry(_ key: Key) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let known = entries[key.path], known.key == key else { return nil }
        return known.entry
    }

    func store(_ entry: Entry, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        entries[key.path] = (key, entry)
    }

    /// Forget files the folder no longer offers.
    func keep(paths: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { paths.contains($0.key) }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

struct ScreenshotMacReader: ScreenshotReading {
    let cache = ScreenshotReadCache()

    func systemFolder() -> ScreenshotFolder { ScreenshotMac.systemFolder() }

    func homePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    func list(_ folder: ScreenshotFolder, now: Date) -> ScreenshotList {
        let url = URL(fileURLWithPath: folder.path, isDirectory: true)
        var files: [ScreenshotCandidate] = []
        var stubPaths: [String] = []
        let result = FolderSyncFiles.withAccess(to: url) {
            FolderSyncFiles.withoutMaterialization {
                FolderSyncFiles.list(folder.path) { entry in
                    guard entry.isRegular else { return }
                    if let target = entry.cloudStubTarget {
                        // A stub can keep a known path waiting. It does not prove a screenshot.
                        stubPaths.append(url.appendingPathComponent(target).path)
                    }
                    guard !entry.isHidden else { return }
                    guard Self.marked(entry.path) else {
                        if entry.isDataless { files.append(Self.deferred(path: entry.path)) }
                        return
                    }
                    let child = URL(fileURLWithPath: entry.path)
                    let values = try? child.resourceValues(forKeys: [.creationDateKey])
                    files.append(Self.read(child, entry: entry, created: values?.creationDate, now: now, cache: cache))
                }
            }
        }
        switch result {
        case .complete:
            let named = Set(files.map(\.path))
            files.append(contentsOf: stubPaths.filter { !named.contains($0) }.map(Self.deferred))
            cache.keep(paths: Set(files.map(\.path)))
            return .files(files)
        case .denied: return .denied
        case .missing: return .missing
        default: return .failed
        }
    }

    func startDownload(_ file: ScreenshotCandidate) throws {
        let selected = FolderSyncFiles.withoutMaterialization {
            guard let entry = FolderSyncFile.probe(path: file.path), entry.isRegular,
                  entry.modified == file.fileDate, entry.size == file.byteCount,
                  Self.marked(entry.path) else { return nil as FolderSyncFile? }
            return entry
        } ?? nil
        guard let selected else { throw CocoaError(.fileReadNoSuchFile) }
        if selected.isDataless {
            try FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: file.path))
        }
    }

    private static func deferred(path: String) -> ScreenshotCandidate {
        ScreenshotCandidate(
            path: path, marked: false, platformDate: nil, fileDate: nil,
            byteCount: 0, stable: false, header: Data(), sha256: nil, pixelCount: nil,
            unreadable: false, fileExtension: "", cloudOnly: true
        )
    }

    private static func marked(_ path: String) -> Bool {
        if xattrBool(path) { return true }
        return spotlightBool(path)
    }

    private static func xattrBool(_ path: String) -> Bool {
        let size = getxattr(path, ScreenshotMac.screenCaptureAttribute, nil, 0, 0, 0)
        guard size > 0, size < 1 << 20 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, ScreenshotMac.screenCaptureAttribute, buffer.baseAddress, size, 0, 0)
        }
        guard read == size else { return false }
        return ScreenshotMac.plistBool(data)
    }

    private static func spotlightBool(_ path: String) -> Bool {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return false }
        return (MDItemCopyAttribute(item, ScreenshotMac.isScreenCaptureName as CFString) as? Bool) == true
    }

    static func read(
        _ url: URL, entry: FolderSyncFile, created: Date?, now: Date, cache: ScreenshotReadCache? = nil
    ) -> ScreenshotCandidate {
        let path = entry.path
        let mtime = entry.modified
        let platform = spotlightDate(path) ?? created
        let size = Int(entry.size)
        let stable = FolderSyncFiles.hasSettled(modified: mtime, now: now, delay: ScreenshotMac.stableAfter)
        let key = ScreenshotReadCache.Key(
            path: path, size: size, modified: mtime, device: entry.info.st_dev, inode: entry.info.st_ino
        )
        let known = stable ? cache?.entry(key) : nil
        var candidate = ScreenshotCandidate(
            path: path, marked: true, platformDate: platform, fileDate: mtime,
            byteCount: size, stable: stable, header: known?.header ?? Data(), sha256: known?.sha256,
            pixelCount: known?.pixels, unreadable: false, fileExtension: url.pathExtension,
            cloudOnly: entry.isDataless
        )
        guard stable, !entry.isDataless, known == nil else { return candidate }
        if let bytes = FolderSyncFiles.withoutMaterialization({ readBytes(entry) }) ?? nil {
            cache?.store(bytes, for: key)
            candidate.header = bytes.header
            candidate.sha256 = bytes.sha256
            candidate.pixelCount = bytes.pixels
        } else if FolderSyncFile.probe(path: path)?.isDataless == true {
            candidate.cloudOnly = true
        } else {
            candidate.unreadable = true
        }
        return candidate
    }

    private static func readBytes(
        _ entry: FolderSyncFile, copyingTo output: FileHandle? = nil
    ) -> ScreenshotReadCache.Entry? {
        let size = Int(entry.size)
        let descriptor = open(entry.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == entry.info.st_dev, info.st_ino == entry.info.st_ino,
              !FolderSyncFile.isDataless(flags: info.st_flags) else { return nil }
        var hasher = SHA256()
        var header = Data()
        var pixels: Int64?
        do {
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
                if header.count < 64 { header.append(chunk.prefix(64 - header.count)) }
                hasher.update(data: chunk)
                try output?.write(contentsOf: chunk)
            }
            if output != nil {
                try output?.close()
            } else if ScreenshotBytes.kind(header: header) == .jpeg, size <= ScreenshotBytes.maxBytes {
                try file.seek(toOffset: 0)
                pixels = ScreenshotBytes.pixelCount(data: try file.read(upToCount: min(size, 1 << 20)) ?? header)
            } else if size <= ScreenshotBytes.maxBytes {
                pixels = ScreenshotBytes.pixelCount(data: header)
            }
            guard fstat(descriptor, &info) == 0, info.st_size == entry.info.st_size,
                  info.st_mtimespec.tv_sec == entry.info.st_mtimespec.tv_sec,
                  info.st_mtimespec.tv_nsec == entry.info.st_mtimespec.tv_nsec else { return nil }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return ScreenshotReadCache.Entry(header: header, sha256: hash, pixels: pixels)
        } catch {
            return nil
        }
    }

    /// Stage the selected source bytes before conversion. The immutable copy is checked
    /// against the hash that earned this upload's ledger row.
    static func stage(_ upload: ScreenshotUpload, at destination: URL) -> Bool {
        FolderSyncFiles.withoutMaterialization {
            guard let entry = FolderSyncFile.probe(path: upload.sourcePath),
                  entry.isRegular, !entry.isDataless, marked(entry.path) else { return false }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let output = try? FileHandle(forWritingTo: destination) else { return false }
            return readBytes(entry, copyingTo: output)?.sha256 == upload.hash
        } ?? false
    }

    private static func spotlightDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemContentCreationDate) as? Date
    }
}

struct ScreenshotLiveTransport: ScreenshotTransport {
    var journal = UploadClient()

    func capabilities(serverURL: String) async throws -> [String] {
        try await journal.capabilities(serverURL: serverURL)
    }

    func send(
        _ upload: ScreenshotUpload, serverURL: String, isCurrent: @Sendable () async -> Bool
    ) async -> FolderSyncAnswer {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("solstone-screenshots-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return .retry
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let scale = await ScreenshotPrepare.displayBackingScale()
        guard !Task.isCancelled, await isCurrent() else { return .retry }
        let source = staging.appendingPathComponent("original")
        guard ScreenshotMacReader.stage(upload, at: source) else { return .retry }
        let named = staging.appendingPathComponent(upload.fileName)
        let prepared = ScreenshotPrepare.prepare(source: source, destination: named, pdfScale: scale)
        if let answer = ScreenshotPrepare.answer(for: prepared) { return answer }
        return await journal.uploadFolderFile(
            named, serverURL: serverURL, day: upload.day, segment: upload.segment,
            metadata: [
                "screenshot": .object([
                    "v": .integer(1),
                    "captured_at": .string(upload.capturedAt),
                    "taken_from": .string(upload.takenFrom),
                ]),
            ],
            source: "screenshots", bodyURL: staging.appendingPathComponent("body"),
            isCurrent: isCurrent, classify: classifyScreenshot
        )
    }
}
