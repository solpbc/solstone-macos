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
        var didRenameToFinal = false
        do {
            try tempLayout.ensureCreated()
            try createBundledPythonLink(layout: tempLayout)
            try await install(into: tempLayout)
            guard try await verify(layout: tempLayout) else {
                throw RuntimeMaterializerError.verificationFailed("staged runtime verification failed")
            }
            try makeRelocationSafe(layout: tempLayout, finalURL: finalURL)
            try? fileManager.removeItem(at: finalURL)
            try fileManager.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
            // Make staging references relocation-safe before rename; assert post-rename reality before shipping it.
            if Darwin.rename(tempURL.path, finalURL.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            didRenameToFinal = true
            try await assertRelocationSafe(layout: finalLayout)
            try rewriteAliases(layout: finalLayout)
            try garbageCollect(keeping: key, liveKey: liveKey)
            return MaterializedRuntime(key: key, layout: finalLayout)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            if didRenameToFinal {
                try? fileManager.removeItem(at: finalURL)
            }
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

    /// Rewrites uv's staging-absolute entrypoint references so they survive the temp -> final rename.
    /// uv writes `<bin>/{journal,sol}` as absolute symlinks into `<tools>/.../bin/` and the console
    /// scripts there carry an absolute python trampoline into the staging venv. Both reference the
    /// `.tmp-*` staging dir, which vanishes after the rename. Rewrite the entrypoint symlinks to
    /// relative targets (move-proof) and the console-script trampoline to the final venv python.
    private func makeRelocationSafe(layout: SolstoneRuntimeLayout, finalURL: URL) throws {
        let tempRoot = layout.rootURL.standardizedFileURL.path
        for entry in [layout.journalBinary, layout.solBinary] {
            let name = entry.lastPathComponent
            // Read uv's absolute symlink target into the staging tools tree.
            let targetPath = try fileManager.destinationOfSymbolicLink(atPath: entry.path)
            guard targetPath.hasPrefix(tempRoot + "/") else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) symlink target escapes staging root: \(targetPath)"
                )
            }
            let targetRelToRoot = String(targetPath.dropFirst(tempRoot.count + 1))
            // Rewrite the console-script python trampoline from the staging venv python to the final venv python.
            let consoleScript = URL(fileURLWithPath: targetPath)
            let finalVenvPython = consoleScript.deletingLastPathComponent().appendingPathComponent("python").path
                .replacingOccurrences(of: tempRoot, with: finalURL.standardizedFileURL.path)
            try rewriteConsoleScriptPython(of: consoleScript, to: finalVenvPython)
            // Replace the absolute entrypoint symlink with a relative one.
            try fileManager.removeItem(at: entry)
            try fileManager.createSymbolicLink(atPath: entry.path, withDestinationPath: "../" + targetRelToRoot)
        }
    }

    private func rewriteConsoleScriptPython(of script: URL, to interpreter: String) throws {
        let original = try String(contentsOf: script, encoding: .utf8)
        var lines = original.components(separatedBy: "\n")
        guard lines.count >= 2,
              lines[0] == "#!/bin/sh",
              lines[1].hasPrefix("'''exec' '") else {
            throw RuntimeMaterializerError.verificationFailed(
                "console script \(script.lastPathComponent) does not match uv polyglot trampoline"
            )
        }
        lines[1] = "'''exec' " + shellSingleQuoted(interpreter) + " \"$0\" \"$@\""
        let rewritten = lines.joined(separator: "\n")
        let attrs = try fileManager.attributesOfItem(atPath: script.path)
        try Data(rewritten.utf8).write(to: script, options: .atomic)
        if let perms = attrs[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: perms], ofItemAtPath: script.path)
        }
    }

    /// Fails loudly if any entrypoint would dangle post-rename: resolves the real path of
    /// `bin/{journal,sol}` and the rewritten console script and asserts neither references a
    /// `.tmp-*` staging segment, then executes both final entrypoints. This is the completeness
    /// guarantee against post-rename reality; `isExecutableFile` follows symlinks and false-passes
    /// against the still-present temp tree, so the check must run after the temp dir is gone.
    private func assertRelocationSafe(layout: SolstoneRuntimeLayout) async throws {
        let rootPath = layout.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        // In production the injected runner is SubprocessRunner, so this is a real kernel exec of
        // the relocated polyglot; the regression test also execs the bin entrypoints hermetically.
        let entries = [layout.journalBinary, layout.solBinary]
        var probes: [(name: String, executable: URL)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.isExecutableFile(atPath: resolved.path) else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) does not resolve to an executable: \(resolved.path)"
                )
            }
            try assertWithinRoot(resolved.path, rootPath: rootPath, what: "entrypoint \(name)")

            let script = try String(contentsOf: resolved, encoding: .utf8)
            let lines = script.components(separatedBy: "\n")
            guard lines.first == "#!/bin/sh" else {
                throw RuntimeMaterializerError.verificationFailed("console script \(name) lost its space-safe shebang")
            }
            if lines.contains(where: { containsStagingSegment(in: $0) }) {
                throw RuntimeMaterializerError.verificationFailed("console script \(name) references staging dir after relocation")
            }
            probes.append((name: name, executable: resolved))
        }

        let environment = layout.uvEnvironment()
        let runner = self.runner
        try await withThrowingTaskGroup(of: Void.self) { group in
            for probe in probes {
                let name = probe.name
                let executable = probe.executable
                group.addTask {
                    let output = LockedRuntimeMaterializerOutput()
                    let result: SubprocessResult
                    do {
                        result = try await runner.run(
                            executable: executable,
                            arguments: ["--version"],
                            environment: environment,
                            timeout: .seconds(30),
                            stdoutHandler: { data in output.append(data) },
                            stderrHandler: { _ in }
                        )
                    } catch {
                        throw RuntimeMaterializerError.verificationFailed(
                            "entrypoint \(name) did not execute and report the pinned version after relocation: \(error.localizedDescription)"
                        )
                    }
                    let stdout = output.string()
                    let parsed = SolVersionParser.parse(stdout)
                    guard result.exitCode == 0,
                          parsed == BundleConfig.solstonePinVersion else {
                        throw RuntimeMaterializerError.verificationFailed(
                            "entrypoint \(name) did not execute and report the pinned version after relocation: exit=\(result.exitCode) parsed=\(parsed ?? "nil")"
                        )
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private func assertWithinRoot(_ path: String, rootPath: String, what: String) throws {
        if containsStagingSegment(in: path) {
            throw RuntimeMaterializerError.verificationFailed("\(what) references staging dir: \(path)")
        }
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw RuntimeMaterializerError.verificationFailed("\(what) escapes runtime root: \(path)")
        }
    }

    private func containsStagingSegment(in text: String) -> Bool {
        text.split(separator: "/").contains { $0.hasPrefix(".tmp-") }
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
