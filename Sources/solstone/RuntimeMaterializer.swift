// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation
import os

internal struct MaterializedRuntime: Sendable {
    let key: String
    let layout: SolstoneRuntimeLayout
}

internal protocol RuntimeMaterializing: Sendable {
    func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime
}

internal final class RuntimeMaterializer: RuntimeMaterializing, @unchecked Sendable {
    private let runtimeRootURL: URL
    private let uvBinaryURL: URL
    private let bundledPythonURL: URL
    private let wheelhouseURL: URL
    private let wrapperDirURL: URL
    private let runner: SubprocessRunning
    private let fileManager: FileManager

    internal init(
        runtimeRootURL: URL = SolstoneRuntimeLayout.defaultRootURL,
        uvBinaryURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/uv"),
        bundledPythonURL: URL = SolstoneRuntimeLayout.bundledPythonURL(),
        wheelhouseURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wheelhouse", isDirectory: true),
        wrapperDirURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true),
        runner: SubprocessRunning = SubprocessRunner(),
        fileManager: FileManager = .default
    ) {
        self.runtimeRootURL = runtimeRootURL
        self.uvBinaryURL = uvBinaryURL
        self.bundledPythonURL = bundledPythonURL
        self.wheelhouseURL = wheelhouseURL
        self.wrapperDirURL = wrapperDirURL
        self.runner = runner
        self.fileManager = fileManager
    }

    internal func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime {
        let key = try runtimeKey()
        let finalURL = runtimeRootURL.appendingPathComponent(key, isDirectory: true)
        let finalLayout = SolstoneRuntimeLayout(rootURL: finalURL)
        if try await verify(layout: finalLayout) {
            try rewriteAliases(layout: finalLayout)
            try garbageCollect(keeping: key, liveKey: liveKey)
            return MaterializedRuntime(key: key, layout: finalLayout)
        }

        let tempURL = runtimeRootURL.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        let tempLayout = SolstoneRuntimeLayout(rootURL: tempURL)
        do {
            try tempLayout.ensureCreated()
            try createBundledPythonLink(layout: tempLayout)
            try await install(into: tempLayout)
            guard try await verify(layout: tempLayout) else {
                throw RuntimeMaterializerError.verificationFailed("staged runtime verification failed")
            }
            try? fileManager.removeItem(at: finalURL)
            try fileManager.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
            // Atomicity (temp -> verify -> rename), not `journal --version`, is the completeness guarantee.
            if Darwin.rename(tempURL.path, finalURL.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try rewriteAliases(layout: finalLayout)
            try garbageCollect(keeping: key, liveKey: liveKey)
            return MaterializedRuntime(key: key, layout: finalLayout)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private func runtimeKey() throws -> String {
        let hash = try wheelhouseHash16()
        return "\(BundleConfig.solstonePinVersion)_py\(BundleConfig.bundledPythonBuild)_\(hash)"
    }

    private func wheelhouseHash16() throws -> String {
        let manifest = wheelhouseURL.appendingPathComponent("MANIFEST.sha256")
        if let data = try? Data(contentsOf: manifest) {
            return sha256Hex(data).prefixString(16)
        }
        Logger.setup.warning("runtime materializer: wheelhouse manifest missing, hashing sorted wheel filenames")
        let wheels = try wheelFiles()
        let input = wheels.map(\.lastPathComponent).sorted().joined(separator: "\n") + "\n"
        return sha256Hex(Data(input.utf8)).prefixString(16)
    }

    private func wheelFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: wheelhouseURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "whl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func projectWheel() throws -> URL {
        let prefix = "solstone-\(BundleConfig.solstonePinVersion)-"
        let matches = try wheelFiles().filter {
            $0.lastPathComponent.hasPrefix(prefix)
        }
        guard matches.count == 1, let wheel = matches.first else {
            throw RuntimeMaterializerError.wheelhouseInvalid("expected exactly one \(prefix)*.whl, found \(matches.count)")
        }
        return wheel
    }

    private func install(into layout: SolstoneRuntimeLayout) async throws {
        let output = LockedRuntimeMaterializerOutput()
        let result = try await runner.run(
            executable: uvBinaryURL,
            arguments: [
                "tool",
                "install",
                try projectWheel().path,
                "--find-links",
                wheelhouseURL.path,
                "--no-index",
                "--offline",
                "--python",
                bundledPythonURL.path,
                "--no-python-downloads",
                "--force"
            ],
            environment: layout.uvEnvironment(),
            stdoutHandler: { data in output.append(data) },
            stderrHandler: { data in output.append(data) }
        )
        guard result.exitCode == 0 else {
            throw RuntimeMaterializerError.installFailed(sanitizeJournalDiagnosticOutput(output.string()) ?? output.string())
        }
    }

    private func verify(layout: SolstoneRuntimeLayout) async throws -> Bool {
        guard fileManager.isExecutableFile(atPath: layout.journalBinary.path) else {
            return false
        }
        guard try await verifyJournalVersion(layout: layout) else {
            return false
        }
        guard try await verifyPython(at: bundledPythonURL) else {
            return false
        }
        let materializedPython = layout.binDir.appendingPathComponent("python3.13")
        if fileManager.fileExists(atPath: materializedPython.path) {
            let resolved = materializedPython.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == bundledPythonURL.standardizedFileURL.path else {
                return false
            }
        } else {
            try createBundledPythonLink(layout: layout)
        }
        return try await verifyPython(at: materializedPython)
    }

    private func verifyJournalVersion(layout: SolstoneRuntimeLayout) async throws -> Bool {
        let output = LockedRuntimeMaterializerOutput()
        let result = try await runner.run(
            executable: layout.journalBinary,
            arguments: ["--version"],
            environment: layout.uvEnvironment(),
            stdoutHandler: { data in output.append(data) },
            stderrHandler: { _ in }
        )
        guard result.exitCode == 0,
              let version = SolVersionParser.parse(output.string()) else {
            return false
        }
        return version == BundleConfig.solstonePinVersion
    }

    private func verifyPython(at url: URL) async throws -> Bool {
        let output = LockedRuntimeMaterializerOutput()
        let result = try await runner.run(
            executable: url,
            arguments: ["-c", "print(1)"],
            environment: nil,
            stdoutHandler: { data in output.append(data) },
            stderrHandler: { data in output.append(data) }
        )
        return result.exitCode == 0 && output.string().contains("1")
    }

    private func createBundledPythonLink(layout: SolstoneRuntimeLayout) throws {
        try fileManager.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        let link = layout.binDir.appendingPathComponent("python3.13")
        if fileManager.fileExists(atPath: link.path) {
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: bundledPythonURL)
    }

    private func rewriteAliases(layout: SolstoneRuntimeLayout) throws {
        try fileManager.createDirectory(at: wrapperDirURL, withIntermediateDirectories: true)
        try writeWrapper(named: "sol", target: layout.solBinary)
        try writeWrapper(named: "journal", target: layout.journalBinary)
    }

    private func writeWrapper(named name: String, target: URL) throws {
        let wrapper = wrapperDirURL.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        # managed-version: app-owned-child
        exec '\(target.path)' "$@"
        """
        try Data((script + "\n").utf8).write(to: wrapper, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    private func garbageCollect(keeping key: String, liveKey: String?) throws {
        guard fileManager.fileExists(atPath: runtimeRootURL.path) else { return }
        let children = try fileManager.contentsOfDirectory(
            at: runtimeRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where isMaterializedRuntimeDirectory(child) {
            let name = child.lastPathComponent
            guard name != key, name != liveKey else { continue }
            try fileManager.removeItem(at: child)
        }
    }

    private func isMaterializedRuntimeDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("\(BundleConfig.solstonePinVersion)_py")
            && !name.hasPrefix(".tmp-")
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

internal enum RuntimeMaterializerError: LocalizedError, Sendable, Equatable {
    case wheelhouseInvalid(String)
    case installFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .wheelhouseInvalid(let message),
             .installFailed(let message),
             .verificationFailed(let message):
            return message
        }
    }
}

private final class LockedRuntimeMaterializerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }

    func string() -> String {
        lock.withLock {
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}

private extension String {
    func prefixString(_ count: Int) -> String {
        String(prefix(count))
    }
}
