// SPDX-License-Identifier: AGPL-3.0-only
//
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

public enum SolMacSymlinkInstaller {
    public static func ensureInstalled() {
        let sourceCLI = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sol-mac")
        let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/sol-mac")
        ensure(sourceCLI: sourceCLI, destination: destination)
    }

    internal static func ensure(sourceCLI: URL, destination: URL) {
        let parent = destination.deletingLastPathComponent()
        if !ensureParentDirectory(at: parent) {
            let savedErrno = errno
            logFailure(savedErrno)
            return
        }

        var fileStatus = stat()
        let result = destination.path.withCString { lstat($0, &fileStatus) }
        if result != 0 {
            let savedErrno = errno
            if savedErrno == ENOENT {
                atomicSymlink(target: sourceCLI.path, at: destination)
                return
            }

            logFailure(savedErrno)
            return
        }

        if (fileStatus.st_mode & S_IFMT) == S_IFLNK {
            guard let existingTarget = readLink(at: destination) else {
                return
            }

            if existingTarget.contains("solstone.app/Contents/MacOS/sol-mac") {
                if existingTarget == sourceCLI.path {
                    return
                }

                atomicSymlink(target: sourceCLI.path, at: destination)
                return
            }

            Logger.setup.debug("\(SolMacCopy.INSTALL_SKIP_LOG, privacy: .public)")
            return
        }

        Logger.setup.debug("\(SolMacCopy.INSTALL_SKIP_LOG, privacy: .public)")
    }

    private static func atomicSymlink(target: String, at destination: URL) {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent("sol-mac.tmp.\(UUID().uuidString.prefix(8))")

        let symlinkResult = target.withCString { targetPath in
            tempURL.path.withCString { tempPath in
                symlink(targetPath, tempPath)
            }
        }
        if symlinkResult != 0 {
            logFailure(errno)
            return
        }

        let renameResult = tempURL.path.withCString { tempPath in
            destination.path.withCString { destinationPath in
                rename(tempPath, destinationPath)
            }
        }
        if renameResult != 0 {
            let savedErrno = errno
            _ = tempURL.path.withCString { unlink($0) }
            logFailure(savedErrno)
            return
        }

        Logger.setup.info("\(SolMacCopy.INSTALL_SUCCESS_LOG, privacy: .public)")
    }

    private static func readLink(at destination: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = destination.path.withCString { readlink($0, &buffer, buffer.count - 1) }
        if length < 0 {
            logFailure(errno)
            return nil
        }

        let bytes = buffer[..<Int(length)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func ensureParentDirectory(at parent: URL) -> Bool {
        let components = parent.pathComponents
        var currentPath = ""

        for component in components {
            if component == "/" {
                currentPath = "/"
                continue
            }

            if currentPath == "/" {
                currentPath += component
            } else if currentPath.isEmpty {
                currentPath = component
            } else {
                currentPath += "/\(component)"
            }

            var fileStatus = stat()
            let statusResult = currentPath.withCString { stat($0, &fileStatus) }
            if statusResult == 0 {
                if (fileStatus.st_mode & S_IFMT) != S_IFDIR {
                    errno = ENOTDIR
                    return false
                }
                continue
            }

            let savedErrno = errno
            if savedErrno != ENOENT {
                errno = savedErrno
                return false
            }

            let mkdirResult = currentPath.withCString { mkdir($0, 0o755) }
            if mkdirResult == 0 {
                continue
            }

            let mkdirErrno = errno
            if mkdirErrno != EEXIST {
                errno = mkdirErrno
                return false
            }

            var existingStatus = stat()
            let existingResult = currentPath.withCString { stat($0, &existingStatus) }
            if existingResult != 0 {
                return false
            }
            if (existingStatus.st_mode & S_IFMT) != S_IFDIR {
                errno = ENOTDIR
                return false
            }
        }

        return true
    }

    private static func logFailure(_ errorNumber: Int32) {
        let description = String(cString: strerror(errorNumber))
        Logger.setup.warning("\(SolMacCopy.INSTALL_FAILURE_LOG, privacy: .public): errno=\(errorNumber) (\(description, privacy: .public))")
    }
}
