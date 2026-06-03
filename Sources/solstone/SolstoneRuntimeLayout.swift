// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin

struct SolstoneRuntimeLayout: Sendable {
    enum Mode: Sendable, Equatable {
        case flat
        case versioned(String)
    }

    let rootURL: URL
    let mode: Mode

    init(rootURL: URL = SolstoneRuntimeLayout.defaultRootURL, mode: Mode = .flat) {
        self.rootURL = rootURL
        self.mode = mode
    }

    static var defaultRootURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("sol/runtime", isDirectory: true)
    }

    static func bundledPythonURL(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL.appendingPathComponent("Contents/Resources/python/bin/python3.13")
    }

    var pythonDir: URL { rootURL.appendingPathComponent("python", isDirectory: true) }
    var cacheDir: URL { rootURL.appendingPathComponent("cache", isDirectory: true) }
    var versionsDir: URL { rootURL.appendingPathComponent("versions", isDirectory: true) }
    var currentLink: URL { rootURL.appendingPathComponent("current") }

    var toolsDir: URL {
        switch mode {
        case .flat:
            return rootURL.appendingPathComponent("tools", isDirectory: true)
        case .versioned(let id):
            return versionRoot(id).appendingPathComponent("tools", isDirectory: true)
        }
    }

    var binDir: URL {
        switch mode {
        case .flat:
            return rootURL.appendingPathComponent("bin", isDirectory: true)
        case .versioned(let id):
            return versionRoot(id).appendingPathComponent("bin", isDirectory: true)
        }
    }

    var solBinary: URL { binDir.appendingPathComponent("sol") }
    var journalBinary: URL { binDir.appendingPathComponent("journal") }

    func ensureCreated() throws {
        let fileManager = FileManager.default
        for dir in [rootURL, pythonDir, cacheDir, toolsDir, binDir] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func readActiveVersion(rootURL: URL = defaultRootURL) -> String? {
        let layout = SolstoneRuntimeLayout(rootURL: rootURL)
        let destination: String
        do {
            destination = try FileManager.default.destinationOfSymbolicLink(atPath: layout.currentLink.path)
        } catch {
            return nil
        }

        let targetURL: URL
        if destination.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: destination, isDirectory: true)
        } else {
            targetURL = rootURL.appendingPathComponent(destination, isDirectory: true)
        }

        let resolvedTarget = targetURL.standardizedFileURL
        let resolvedVersionsDir = layout.versionsDir.standardizedFileURL
        guard resolvedTarget.deletingLastPathComponent().path == resolvedVersionsDir.path else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedTarget.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        let id = resolvedTarget.lastPathComponent
        return id.isEmpty ? nil : id
    }

    static func active(rootURL: URL = defaultRootURL) -> SolstoneRuntimeLayout {
        if let version = readActiveVersion(rootURL: rootURL) {
            return SolstoneRuntimeLayout(rootURL: rootURL, mode: .versioned(version))
        }
        return SolstoneRuntimeLayout(rootURL: rootURL)
    }

    static func staging(rootURL: URL = defaultRootURL, version: String) -> SolstoneRuntimeLayout {
        SolstoneRuntimeLayout(rootURL: rootURL, mode: .versioned(version))
    }

    static func solCandidatePaths(rootURL: URL = defaultRootURL) -> [String] {
        var paths: [String] = []
        if let version = readActiveVersion(rootURL: rootURL) {
            paths.append(SolstoneRuntimeLayout(rootURL: rootURL, mode: .versioned(version)).solBinary.path)
        }
        paths.append(SolstoneRuntimeLayout(rootURL: rootURL).solBinary.path)
        return paths
    }

    func activate() throws {
        guard case .versioned(let id) = mode else {
            throw ActivationError.cannotActivateFlatLayout
        }

        let fileManager = FileManager.default
        let target = versionRoot(id)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ActivationError.versionDirectoryMissing(target.path)
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let tempLink = rootURL.appendingPathComponent(".current.new-\(UUID().uuidString)")
        let relativeTarget = "versions/\(id)"
        do {
            try fileManager.createSymbolicLink(atPath: tempLink.path, withDestinationPath: relativeTarget)
            if Darwin.rename(tempLink.path, currentLink.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: tempLink)
            throw error
        }
    }

    func uvEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["UV_PYTHON_INSTALL_DIR"] = pythonDir.path
        environment["UV_PYTHON_CACHE_DIR"] = pythonDir.path
        environment["UV_CACHE_DIR"] = cacheDir.path
        environment["UV_TOOL_DIR"] = toolsDir.path
        environment["UV_TOOL_BIN_DIR"] = binDir.path
        return environment
    }

    private func versionRoot(_ id: String) -> URL {
        versionsDir.appendingPathComponent(id, isDirectory: true)
    }

    enum ActivationError: LocalizedError, Equatable {
        case cannotActivateFlatLayout
        case versionDirectoryMissing(String)

        var errorDescription: String? {
            switch self {
            case .cannotActivateFlatLayout:
                return "cannot activate a flat runtime layout"
            case .versionDirectoryMissing(let path):
                return "version directory missing at \(path)"
            }
        }
    }
}
