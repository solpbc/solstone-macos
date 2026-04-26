// SPDX-License-Identifier: AGPL-3.0-only
//
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
@testable import solstone

@Suite("SolMacSymlinkInstaller")
struct SolMacInstallerTests {
    @Test func createsSymlinkWhenNoneExists() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceCLI = try makeSourceCLI(in: workspace)
        let destination = workspace.appendingPathComponent(".local/bin/sol-mac")

        SolMacSymlinkInstaller.ensure(sourceCLI: sourceCLI, destination: destination)

        let status = try lstatInfo(at: destination)
        #expect((status.st_mode & S_IFMT) == mode_t(S_IFLNK))
        #expect(try readlinkTarget(at: destination) == sourceCLI.path)
    }

    @Test func noOpWhenSymlinkAlreadyPointsAtDesiredTarget() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceCLI = try makeSourceCLI(in: workspace)
        let destination = workspace.appendingPathComponent(".local/bin/sol-mac")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createSymlink(target: sourceCLI.path, at: destination)

        let before = try lstatInfo(at: destination)

        SolMacSymlinkInstaller.ensure(sourceCLI: sourceCLI, destination: destination)

        let after = try lstatInfo(at: destination)
        #expect((after.st_mode & S_IFMT) == mode_t(S_IFLNK))
        #expect(before.st_ino == after.st_ino)
        #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
        #expect(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        #expect(try readlinkTarget(at: destination) == sourceCLI.path)
    }

    @Test func replacesSymlinkWhenItPointsAtDifferentSolstoneApp() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceCLI = try makeSourceCLI(in: workspace)
        let destination = workspace.appendingPathComponent(".local/bin/sol-mac")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createSymlink(target: "/some/other/solstone.app/Contents/MacOS/sol-mac", at: destination)

        SolMacSymlinkInstaller.ensure(sourceCLI: sourceCLI, destination: destination)

        #expect(try readlinkTarget(at: destination) == sourceCLI.path)
        let siblings = try FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(!siblings.contains(where: { $0.lastPathComponent.hasPrefix("sol-mac.tmp.") }))
    }

    @Test func leavesUserOwnedRegularFileAlone() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceCLI = try makeSourceCLI(in: workspace)
        let destination = workspace.appendingPathComponent(".local/bin/sol-mac")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("echo override\n".utf8)
        try original.write(to: destination)

        SolMacSymlinkInstaller.ensure(sourceCLI: sourceCLI, destination: destination)

        let status = try lstatInfo(at: destination)
        #expect((status.st_mode & S_IFMT) == mode_t(S_IFREG))
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test func leavesForeignSymlinkAlone() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceCLI = try makeSourceCLI(in: workspace)
        let destination = workspace.appendingPathComponent(".local/bin/sol-mac")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try createSymlink(target: "/usr/bin/true", at: destination)

        SolMacSymlinkInstaller.ensure(sourceCLI: sourceCLI, destination: destination)

        #expect(try readlinkTarget(at: destination) == "/usr/bin/true")
    }

    @Test func failureToCreateParentDirIsLoggedNotThrown() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sourceCLI = try makeSourceCLI(in: workspace)
        let localFile = workspace.appendingPathComponent(".local")
        try Data("not a directory\n".utf8).write(to: localFile)
        let destination = localFile.appendingPathComponent("bin/sol-mac")

        SolMacSymlinkInstaller.ensure(sourceCLI: sourceCLI, destination: destination)

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeWorkspace() -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sol-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSourceCLI(in workspace: URL) throws -> URL {
        let sourceCLI = workspace.appendingPathComponent("solstone.app/Contents/MacOS/sol-mac")
        try FileManager.default.createDirectory(
            at: sourceCLI.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: sourceCLI.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        return sourceCLI
    }

    private func createSymlink(target: String, at destination: URL) throws {
        let result = target.withCString { targetPath in
            destination.path.withCString { destinationPath in
                symlink(targetPath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func lstatInfo(at url: URL) throws -> stat {
        var fileStatus = stat()
        let result = url.path.withCString { lstat($0, &fileStatus) }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fileStatus
    }

    private func readlinkTarget(at url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = url.path.withCString { readlink($0, &buffer, buffer.count - 1) }
        guard length >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = buffer[..<Int(length)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
