// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct SolstoneRuntimeLayout: Sendable {
    let rootURL: URL

    init(rootURL: URL = SolstoneRuntimeLayout.defaultRootURL) {
        self.rootURL = rootURL
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
    var toolsDir: URL { rootURL.appendingPathComponent("tools", isDirectory: true) }
    var binDir: URL { rootURL.appendingPathComponent("bin", isDirectory: true) }
    var solBinary: URL { binDir.appendingPathComponent("sol") }

    func ensureCreated() throws {
        let fileManager = FileManager.default
        for dir in [rootURL, pythonDir, cacheDir, toolsDir, binDir] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
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
}
