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
        var modified: Date?
    }

    struct Entry {
        var header: Data
        var sha256: String
        var pixels: Int64?
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    func entry(_ key: Key) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func store(_ entry: Entry, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = entry
    }

    /// Forget files the folder no longer offers.
    func keep(paths: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { paths.contains($0.key.path) }
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
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch let error as NSError {
            return Self.classify(error)
        }
        var files: [ScreenshotCandidate] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let path = child.path
            guard Self.marked(path) else { continue }
            files.append(Self.read(child, values: values, now: now, cache: cache))
        }
        cache.keep(paths: Set(files.map(\.path)))
        return .files(files)
    }

    private static func classify(_ error: NSError) -> ScreenshotList {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return .denied }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) { return .denied }
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return .missing }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return .missing }
        return .failed
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

    static func read(_ url: URL, values: URLResourceValues?, now: Date, cache: ScreenshotReadCache? = nil) -> ScreenshotCandidate {
        let path = url.path
        let mtime = values?.contentModificationDate
        let created = values?.creationDate
        let platform = spotlightDate(path) ?? created
        let size = values?.fileSize ?? 0
        let stable = mtime.map { now.timeIntervalSince($0) >= ScreenshotMac.stableAfter } ?? false
        let key = ScreenshotReadCache.Key(path: path, size: size, modified: mtime)
        if stable, let known = cache?.entry(key) {
            return ScreenshotCandidate(
                path: path, marked: true, platformDate: platform, fileDate: mtime,
                byteCount: size, stable: stable, header: known.header, sha256: known.sha256,
                pixelCount: known.pixels, unreadable: false, fileExtension: url.pathExtension
            )
        }
        var header = Data()
        var hash: String?
        var pixels: Int64?
        var unreadable = false
        if let file = FileHandle(forReadingAtPath: path) {
            defer { try? file.close() }
            var hasher = SHA256()
            var first = Data()
            do {
                while true {
                    let chunk = try file.read(upToCount: 1 << 20) ?? Data()
                    if chunk.isEmpty { break }
                    if first.count < 64 { first.append(chunk.prefix(64 - first.count)) }
                    hasher.update(data: chunk)
                }
                header = first
                hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                if ScreenshotBytes.kind(header: header) == .jpeg, size <= ScreenshotBytes.maxBytes {
                    try file.seek(toOffset: 0)
                    let scan = try file.read(upToCount: min(size, 1 << 20)) ?? header
                    pixels = ScreenshotBytes.pixelCount(data: scan)
                } else if size <= ScreenshotBytes.maxBytes {
                    pixels = ScreenshotBytes.pixelCount(data: header)
                }
            } catch {
                unreadable = true
            }
        } else {
            unreadable = true
        }
        if stable, !unreadable, let hash {
            cache?.store(ScreenshotReadCache.Entry(header: header, sha256: hash, pixels: pixels), for: key)
        }
        return ScreenshotCandidate(
            path: path, marked: true, platformDate: platform, fileDate: mtime,
            byteCount: size, stable: stable, header: header, sha256: hash,
            pixelCount: pixels, unreadable: unreadable || hash == nil,
            fileExtension: url.pathExtension
        )
    }

    private static func spotlightDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemContentCreationDate) as? Date
    }
}

struct ScreenshotLiveTransport: ScreenshotTransport {
    func capabilities(serverURL: String) async throws -> [String] {
        try await UploadClient().journalCapabilities(serverURL: serverURL)
    }

    func send(_ upload: ScreenshotUpload, serverURL: String) async -> ScreenshotAnswer {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("solstone-screenshots-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return .retry
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let named = staging.appendingPathComponent(upload.fileName)
        let scale = await ScreenshotPrepare.displayBackingScale()
        let preparedFile = ScreenshotPrepare.prepare(
            source: URL(fileURLWithPath: upload.sourcePath),
            destination: named,
            pdfScale: scale
        )
        if let answer = ScreenshotPrepare.answer(for: preparedFile) { return answer }
        do {
            let body = staging.appendingPathComponent("body")
            let prepared = try UploadClient().prepareUpload(
                serverURL: serverURL,
                day: upload.day,
                segment: upload.segment,
                mediaFiles: [named],
                metadata: [
                    "screenshot": .object([
                        "v": .integer(1),
                        "captured_at": .string(upload.capturedAt),
                        "taken_from": .string(upload.takenFrom),
                    ]),
                ],
                source: "screenshots",
                bodyURL: body
            )
            return await UploadClient().uploadScreenshotStaged(prepared: prepared)
        } catch {
            return .retry
        }
    }
}
