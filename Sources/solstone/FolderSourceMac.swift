// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreFoundation
import CoreServices
import CryptoKit
import Darwin
import Foundation

/// One local regular file discovered during a non-hydrating recursive folder walk.
struct FolderScannedFile: Equatable, Sendable {
    var relativePath: String
    var absolutePath: String
    var fileExtension: String
    var sizeBytes: Int64
    var modifiedMs: Int64
    var createdMs: Int64?
    var device: UInt64
    var inode: UInt64
    var isSymlink: Bool
}

/// Output of one non-hydrating recursive folder walk.
struct FolderWalkResult: Equatable, Sendable {
    enum RootStatus: Equatable, Sendable {
        case ok
        case missing
        case accessOff
        case unreadable
    }

    var status: RootStatus = .ok
    /// True only when every non-dataless subdirectory was enumerated completely.
    var complete: Bool = true
    var files: [FolderScannedFile] = []
    /// Relative paths of dataless iCloud files, legacy `.icloud` stubs, or in-progress downloads.
    /// Tracked entries matching these paths must not be treated as deleted.
    var deferredPaths: Set<String> = []
    /// Relative directory prefixes (without trailing slash) that were unreadable or dataless.
    /// Tracked entries under these prefixes must not be treated as deleted.
    var unreachablePrefixes: [String] = []
    var unreadableDirs: Int = 0
}

/// Read result from safely streaming a local non-dataless file on disk.
struct FolderFileReadResult: Equatable, Sendable {
    var sha256: String
    var sizeBytes: Int64
    /// Populated when the caller requested inline bytes (e.g. text classification or note baseline).
    var inlineData: Data?
}

/// Lightweight non-hydrating stat probe for one file path.
struct FolderFileProbe: Equatable, Sendable {
    var isRegular: Bool
    var isSymlink: Bool
    var isDataless: Bool
}

/// Protocol abstracting macOS filesystem, metadata, image conversion, and access checks for tests.
protocol FolderSystemReading: Sendable {
    func homePath() -> String
    func checkFolderAccess(path: String) -> FolderWalkResult.RootStatus
    func isThirdPartyStoragePath(_ path: String) -> Bool
    func walk(rootPath: String, bookmark: Data?) -> FolderWalkResult
    func probeFile(path: String, rootPath: String, bookmark: Data?) -> FolderFileProbe?
    func readMetadata(path: String, canonicalRoot: String, isImage: Bool) -> (isScreenshot: Bool, platform: FolderPlatformMetadata?)
    func readAndHash(path: String, canonicalRoot: String, expectedDevice: UInt64?, expectedInode: UInt64?, maxInlineBytes: Int?) -> FolderFileReadResult?
    func stageFile(sourcePath: String, canonicalRoot: String, destinationURL: URL, expectedSHA256: String?, convertToPNG: Bool, maxImagePixels: Int64, maxBytes: Int64) -> FolderStagedFileResult
}

extension FolderSystemReading {
    func probeFile(path: String, rootPath: String, bookmark: Data?) -> FolderFileProbe? {
        guard let p = FolderSyncFile.probe(path: path) else { return nil }
        return FolderFileProbe(
            isRegular: p.isRegular,
            isSymlink: (p.info.st_mode & S_IFMT) == S_IFLNK,
            isDataless: p.isDataless
        )
    }
}

enum FolderStagedFileResult: Equatable, Sendable {
    case ready(sha256: String, sizeBytes: Int64, finalExtension: String)
    case missing
    case dataless
    case unreadable
    case invalidContent
}

/// Live macOS filesystem & metadata reader built directly on `FolderSyncFiles`.
struct FolderSourceMacReader: FolderSystemReading {
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"
    static let quarantineAttribute = "com.apple.quarantine"

    private struct DirIdentity: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    func homePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    func checkFolderAccess(path: String) -> FolderWalkResult.RootStatus {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let listing = FolderSyncFiles.withAccess(to: url) {
            FolderSyncFiles.withoutMaterialization {
                let status = FolderSyncFiles.directoryStatus(path)
                guard status == .complete else { return status }
                return FolderSyncFiles.canList(path) ? .complete : .denied
            } ?? .failed
        }
        switch listing {
        case .complete: return .ok
        case .missing: return .missing
        case .denied: return .accessOff
        case .deferred, .failed: return .unreadable
        }
    }

    func isThirdPartyStoragePath(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let home = homePath()
        let cloudStorage = home + "/Library/CloudStorage/"
        return expanded.hasPrefix(cloudStorage) || expanded == home + "/Library/CloudStorage"
    }

    func walk(rootPath: String, bookmark: Data?) -> FolderWalkResult {
        let resolvedURL = Self.resolveAccessURL(path: rootPath, bookmark: bookmark)
        let effectivePath = resolvedURL.path
        return FolderSyncFiles.withAccess(to: resolvedURL) {
            FolderSyncFiles.withoutMaterialization {
                Self.walkUnlocked(rootPath: effectivePath)
            } ?? FolderWalkResult(status: .unreadable, complete: false)
        }
    }

    private static func walkUnlocked(rootPath: String) -> FolderWalkResult {
        let rootStatus = FolderSyncFiles.directoryStatus(rootPath)
        switch rootStatus {
        case .complete:
            break
        case .missing:
            return FolderWalkResult(status: .missing, complete: false)
        case .denied:
            return FolderWalkResult(status: .accessOff, complete: false)
        case .deferred, .failed:
            return FolderWalkResult(status: .unreadable, complete: false)
        }

        guard let canonicalRoot = FolderSourceClassify.realpathString(rootPath) else {
            return FolderWalkResult(status: .unreadable, complete: false)
        }

        var rootStat = stat()
        guard stat(canonicalRoot, &rootStat) == 0 else {
            return FolderWalkResult(status: errno == ENOENT ? .missing : (errno == EPERM || errno == EACCES ? .accessOff : .unreadable), complete: false)
        }

        var result = FolderWalkResult(status: .ok, complete: true)
        var visitedDirs: Set<DirIdentity> = [DirIdentity(dev: rootStat.st_dev, ino: rootStat.st_ino)]

        func descend(dirPath: String, relPrefix: String) {
            var children: [FolderSyncFile] = []
            let listing = FolderSyncFiles.list(dirPath) { entry in
                children.append(entry)
            }
            switch listing {
            case .complete:
                break
            case .denied:
                if relPrefix.isEmpty {
                    result.status = .accessOff
                } else {
                    result.unreachablePrefixes.append(relPrefix)
                    result.unreadableDirs += 1
                }
                result.complete = false
                return
            case .missing:
                if relPrefix.isEmpty {
                    result.status = .missing
                } else {
                    result.unreachablePrefixes.append(relPrefix)
                }
                result.complete = false
                return
            case .deferred, .failed:
                if relPrefix.isEmpty {
                    result.status = .unreadable
                } else {
                    result.unreachablePrefixes.append(relPrefix)
                    result.unreadableDirs += 1
                }
                result.complete = false
                return
            }

            children.sort { $0.name < $1.name }

            for entry in children {
                let relPath = relPrefix.isEmpty ? entry.name : "\(relPrefix)/\(entry.name)"

                // Legacy iCloud stub (`.foo.icloud`) stands for `foo` without hydrating it.
                if let stubTarget = entry.cloudStubTarget {
                    let targetRel = relPrefix.isEmpty ? stubTarget : "\(relPrefix)/\(stubTarget)"
                    result.deferredPaths.insert(targetRel)
                    continue
                }

                // Skip dotfiles, hidden macOS items, and OS/editor junk.
                if entry.isHidden || FolderSourceClassify.isJunkEntry(entry.name) {
                    continue
                }

                // In-progress downloads (including Safari `.download` packages) wait until finished.
                if FolderSourceClassify.isPartialDownload(entry.name) {
                    result.deferredPaths.insert(relPath)
                    continue
                }

                let mode = entry.info.st_mode & S_IFMT

                if mode == S_IFLNK {
                    guard FolderSourceClassify.symlinkStaysInside(canonicalRoot: canonicalRoot, entryPath: entry.path) else {
                        continue
                    }
                    var targetInfo = stat()
                    guard stat(entry.path, &targetInfo) == 0 else { continue }
                    if FolderSyncFile.isDataless(flags: targetInfo.st_flags) {
                        result.deferredPaths.insert(relPath)
                        continue
                    }
                    let targetMode = targetInfo.st_mode & S_IFMT
                    if targetMode == S_IFDIR {
                        let identity = DirIdentity(dev: targetInfo.st_dev, ino: targetInfo.st_ino)
                        if visitedDirs.insert(identity).inserted {
                            descend(dirPath: entry.path, relPrefix: relPath)
                        }
                    } else if targetMode == S_IFREG {
                        guard FolderSourceClassify.isValidRelativePath(relPath) else { continue }
                        result.files.append(makeScannedFile(
                            relPath: relPath,
                            absPath: entry.path,
                            info: targetInfo,
                            isSymlink: true
                        ))
                    }
                    continue
                }

                if entry.isDirectory {
                    if entry.isDataless {
                        result.complete = false
                        result.unreachablePrefixes.append(relPath)
                        continue
                    }
                    let identity = DirIdentity(dev: entry.info.st_dev, ino: entry.info.st_ino)
                    if visitedDirs.insert(identity).inserted {
                        descend(dirPath: entry.path, relPrefix: relPath)
                    }
                    continue
                }

                if entry.isRegular {
                    // Never read xattrs, Spotlight metadata, or bytes for an evicted iCloud file.
                    if entry.isDataless {
                        result.deferredPaths.insert(relPath)
                        continue
                    }
                    guard FolderSourceClassify.isValidRelativePath(relPath) else { continue }
                    result.files.append(makeScannedFile(
                        relPath: relPath,
                        absPath: entry.path,
                        info: entry.info,
                        isSymlink: false
                    ))
                }
            }
        }

        descend(dirPath: canonicalRoot, relPrefix: "")
        return result
    }

    private static func makeScannedFile(
        relPath: String,
        absPath: String,
        info: stat,
        isSymlink: Bool
    ) -> FolderScannedFile {
        let modifiedMs = Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
        let birthSec = Int64(info.st_birthtimespec.tv_sec)
        let createdMs: Int64? = birthSec > 0
            ? birthSec * 1000 + Int64(info.st_birthtimespec.tv_nsec) / 1_000_000
            : nil
        let ext = (relPath as NSString).pathExtension.lowercased()
        return FolderScannedFile(
            relativePath: relPath,
            absolutePath: absPath,
            fileExtension: ext,
            sizeBytes: Int64(info.st_size),
            modifiedMs: modifiedMs,
            createdMs: createdMs,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            isSymlink: isSymlink
        )
    }

    func probeFile(path: String, rootPath: String, bookmark: Data?) -> FolderFileProbe? {
        let accessURL = Self.resolveAccessURL(path: rootPath, bookmark: bookmark)
        return FolderSyncFiles.withAccess(to: accessURL) {
            FolderSyncFiles.withoutMaterialization {
                guard let target = FolderSourceClassify.realpathString(path),
                      target.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/"),
                      let p = FolderSyncFile.probe(path: target) else { return nil }
                return FolderFileProbe(
                    isRegular: p.isRegular,
                    isSymlink: (p.info.st_mode & S_IFMT) == S_IFLNK,
                    isDataless: p.isDataless
                )
            } ?? nil
        }
    }

    func readMetadata(path: String, canonicalRoot: String, isImage: Bool) -> (isScreenshot: Bool, platform: FolderPlatformMetadata?) {
        FolderSyncFiles.withoutMaterialization {
            guard let opened = Self.openLocalRegularFile(path: path, canonicalRoot: canonicalRoot) else {
                return (false, nil)
            }
            defer { close(opened.fd) }
            // Spotlight accepts the volume's stable file-ID pathname. xattrs use the same opened file.
            let referencePath = "/.vol/\(opened.info.st_dev)/\(opened.info.st_ino)"
            var meta = FolderPlatformMetadata()
            var isScreenshot = false

            if let whereFroms = Self.readWhereFroms(opened.fd, referencePath: referencePath), !whereFroms.isEmpty {
                meta.whereFroms = whereFroms
                meta.originURL = whereFroms.first
                if whereFroms.count >= 2 {
                    meta.referrerURL = whereFroms[1]
                }
            }

            if let quarantine = Self.readQuarantine(opened.fd) {
                meta.quarantine = quarantine.raw
                meta.downloadedBy = quarantine.agent
            }

            if isImage && Self.isScreenCapture(opened.fd, referencePath: referencePath) {
                isScreenshot = true
                meta.sourceApp = Self.spotlightCreator(referencePath) ?? "Screenshot"
            }

            return (isScreenshot, meta.sanitized())
        } ?? (false, nil)
    }

    func readAndHash(
        path: String,
        canonicalRoot: String,
        expectedDevice: UInt64?,
        expectedInode: UInt64?,
        maxInlineBytes: Int?
    ) -> FolderFileReadResult? {
        FolderSyncFiles.withoutMaterialization {
            guard let resolved = Self.openLocalRegularFile(path: path, canonicalRoot: canonicalRoot) else {
                return nil
            }
            let fd = resolved.fd
            let initialStat = resolved.info
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }

            if let expectedDevice, UInt64(initialStat.st_dev) != expectedDevice { return nil }
            if let expectedInode, UInt64(initialStat.st_ino) != expectedInode { return nil }

            var hasher = SHA256()
            var totalBytes: Int64 = 0
            var inline = Data()
            let captureInline = maxInlineBytes != nil && Int64(initialStat.st_size) <= Int64(maxInlineBytes ?? 0)

            do {
                while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
                    totalBytes += Int64(chunk.count)
                    guard totalBytes <= initialStat.st_size else { return nil }
                    hasher.update(data: chunk)
                    if captureInline, let cap = maxInlineBytes, inline.count + chunk.count <= cap {
                        inline.append(chunk)
                    }
                }
                var finalStat = stat()
                guard fstat(fd, &finalStat) == 0,
                      finalStat.st_size == initialStat.st_size,
                      finalStat.st_mtimespec.tv_sec == initialStat.st_mtimespec.tv_sec,
                      finalStat.st_mtimespec.tv_nsec == initialStat.st_mtimespec.tv_nsec,
                      !FolderSyncFile.isDataless(flags: finalStat.st_flags) else {
                    return nil
                }
                let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                return FolderFileReadResult(
                    sha256: hex,
                    sizeBytes: totalBytes,
                    inlineData: captureInline ? inline : nil
                )
            } catch {
                return nil
            }
        } ?? nil
    }

    func stageFile(
        sourcePath: String,
        canonicalRoot: String,
        destinationURL: URL,
        expectedSHA256: String?,
        convertToPNG: Bool,
        maxImagePixels: Int64,
        maxBytes: Int64
    ) -> FolderStagedFileResult {
        FolderSyncFiles.withoutMaterialization {
            // Check dataless before opening so we never hydrate.
            var preStat = stat()
            guard lstat(sourcePath, &preStat) == 0 else {
                return errno == ENOENT ? .missing : .unreadable
            }
            if FolderSyncFile.isDataless(flags: preStat.st_flags) {
                return .dataless
            }

            guard let opened = Self.openLocalRegularFile(path: sourcePath, canonicalRoot: canonicalRoot) else {
                return .unreadable
            }
            let fd = opened.fd
            let initialStat = opened.info
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? input.close() }

            let maxRawBytes: Int64 = convertToPNG ? max(maxBytes * 2, 100 * 1024 * 1024) : maxBytes
            if Int64(initialStat.st_size) > maxRawBytes {
                return .invalidContent
            }

            let rawDest: URL
            if convertToPNG {
                rawDest = destinationURL.deletingLastPathComponent().appendingPathComponent("raw-\(UUID().uuidString)")
            } else {
                rawDest = destinationURL
            }
            defer {
                if convertToPNG {
                    try? FileManager.default.removeItem(at: rawDest)
                }
            }

            guard FileManager.default.createFile(atPath: rawDest.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let output = try? FileHandle(forWritingTo: rawDest) else {
                return .unreadable
            }
            defer { try? output.close() }

            var hasher = SHA256()
            var copied: Int64 = 0
            do {
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    copied += Int64(chunk.count)
                    if copied > maxRawBytes {
                        try? output.close()
                        try? FileManager.default.removeItem(at: rawDest)
                        return .invalidContent
                    }
                    hasher.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
                try output.close()
                var finalStat = stat()
                guard fstat(fd, &finalStat) == 0,
                      finalStat.st_size == initialStat.st_size,
                      finalStat.st_mtimespec.tv_sec == initialStat.st_mtimespec.tv_sec,
                      finalStat.st_mtimespec.tv_nsec == initialStat.st_mtimespec.tv_nsec,
                      !FolderSyncFile.isDataless(flags: finalStat.st_flags) else {
                    try? FileManager.default.removeItem(at: rawDest)
                    return .unreadable
                }
            } catch {
                try? FileManager.default.removeItem(at: rawDest)
                return .unreadable
            }

            let rawHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let expectedSHA256, rawHex != expectedSHA256 {
                // Source file changed on disk since queueing; caller will re-scan.
                try? FileManager.default.removeItem(at: rawDest)
                return .unreadable
            }

            if !convertToPNG {
                let ext = (sourcePath as NSString).pathExtension.lowercased()
                return .ready(sha256: rawHex, sizeBytes: copied, finalExtension: ext.isEmpty ? "bin" : ext)
            }

            // Convert convertible image formats (HEIC, TIFF, GIF, BMP) to PNG via ImageIO.
            let prepared = ScreenshotPrepare.prepare(source: rawDest, destination: destinationURL, pdfScale: 2)
            switch prepared {
            case .ready:
                guard let pngData = try? Data(contentsOf: destinationURL, options: [.mappedIfSafe]) else {
                    return .unreadable
                }
                if Int64(pngData.count) > maxBytes {
                    try? FileManager.default.removeItem(at: destinationURL)
                    return .invalidContent
                }
                if let pixels = ScreenshotBytes.pixelCount(data: pngData), pixels > maxImagePixels {
                    try? FileManager.default.removeItem(at: destinationURL)
                    return .invalidContent
                }
                let pngHex = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
                return .ready(sha256: pngHex, sizeBytes: Int64(pngData.count), finalExtension: "png")
            case .undecodable, .overLimit:
                return .invalidContent
            case .retry:
                return .unreadable
            }
        } ?? .unreadable
    }

    private static func openLocalRegularFile(path: String, canonicalRoot: String) -> (fd: Int32, info: stat)? {
        // Resolve every component (including intermediate directories) and ensure the final
        // target stays inside the chosen canonical folder root before opening with O_NOFOLLOW.
        guard let resolved = FolderSourceClassify.realpathString(path),
              resolved.hasPrefix(canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/") else {
            return nil
        }
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              !FolderSyncFile.isDataless(flags: info.st_flags) else {
            close(fd)
            return nil
        }
        return (fd, info)
    }

    // MARK: - macOS xattr & Spotlight provenance parsing

    private static func readWhereFroms(_ fd: Int32, referencePath path: String) -> [String]? {
        if let data = readXattr(fd: fd, name: whereFromsAttribute),
           let parsed = parseWhereFromsPlist(data), !parsed.isEmpty {
            return parsed
        }
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let values = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else {
            return nil
        }
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    static func parseWhereFromsPlist(_ data: Data) -> [String]? {
        guard let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return nil
        }
        let cleaned = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func readQuarantine(_ fd: Int32) -> (raw: String, agent: String?)? {
        guard let data = readXattr(fd: fd, name: quarantineAttribute),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseQuarantine(raw)
    }

    /// Parse `com.apple.quarantine` (`flags;hex_timestamp;agent_name;uuid`) into raw + downloaded_by agent.
    static func parseQuarantine(_ raw: String) -> (raw: String, agent: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ";", omittingEmptySubsequences: false)
        var agent: String?
        if parts.count >= 3 {
            let decoded = unescapeQuarantineField(String(parts[2]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !decoded.isEmpty {
                agent = decoded
            }
        }
        return (trimmed, agent)
    }

    private static func unescapeQuarantineField(_ value: String) -> String {
        var result = ""
        var i = value.startIndex
        while i < value.endIndex {
            if value[i] == "\\",
               let next = value.index(i, offsetBy: 1, limitedBy: value.endIndex),
               next < value.endIndex,
               value[next] == "x",
               let hexEnd = value.index(i, offsetBy: 4, limitedBy: value.endIndex) {
                let hexStart = value.index(i, offsetBy: 2)
                if let byte = UInt8(value[hexStart..<hexEnd], radix: 16), byte >= 0x20, byte != 0x7F {
                    result.append(Character(UnicodeScalar(byte)))
                    i = hexEnd
                    continue
                }
            }
            result.append(value[i])
            i = value.index(after: i)
        }
        return result
    }

    private static func isScreenCapture(_ fd: Int32, referencePath path: String) -> Bool {
        if let data = readXattr(fd: fd, name: ScreenshotMac.screenCaptureAttribute),
           ScreenshotMac.plistBool(data) {
            return true
        }
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return false }
        return (MDItemCopyAttribute(item, ScreenshotMac.isScreenCaptureName as CFString) as? Bool) == true
    }

    private static func spotlightCreator(_ path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let creator = MDItemCopyAttribute(item, kMDItemCreator) as? String else {
            return nil
        }
        let trimmed = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readXattr(fd: Int32, name: String) -> Data? {
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        guard size > 0, size < (1 << 20) else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            fgetxattr(fd, name, buffer.baseAddress, size, 0, 0)
        }
        guard read == size else { return nil }
        return data
    }

    // MARK: - Optional bookmark helper

    static func makeBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveAccessURL(path: String, bookmark: Data?) -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

/// Native macOS picker & System Settings launcher for folders.
enum FolderSourceMacUI {
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = FolderSourceCopy.chooseFolder
        panel.prompt = FolderSourceCopy.chooseFolder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }

    @MainActor
    static func openFilesSettings() {
        ScreenshotMac.openFilesSettings()
    }
}
