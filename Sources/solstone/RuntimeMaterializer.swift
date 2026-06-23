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
        if try await verify(layout: finalLayout) == nil {
            try rewriteAliases(layout: finalLayout)
            garbageCollect(keeping: key, liveKey: liveKey)
            return MaterializedRuntime(key: key, layout: finalLayout)
        }

        let tempURL = runtimeRootURL.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        let tempLayout = SolstoneRuntimeLayout(rootURL: tempURL)
        var didRenameToFinal = false
        do {
            try tempLayout.ensureCreated()
            try createBundledPythonLink(layout: tempLayout)
            try await install(into: tempLayout)
            if let reason = try await verify(layout: tempLayout) {
                Logger.setup.notice("runtime materializer: staged runtime verification failed: \(reason, privacy: .public)")
                throw RuntimeMaterializerError.verificationFailed(reason)
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
            garbageCollect(keeping: key, liveKey: liveKey)
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

    private func projectWheelJournalSpec() throws -> String {
        try projectWheel().path + "[journal]"
    }

    private func install(into layout: SolstoneRuntimeLayout) async throws {
        let output = LockedRuntimeMaterializerOutput()
        let result = try await runner.run(
            executable: uvBinaryURL,
            arguments: [
                "tool",
                "install",
                try projectWheelJournalSpec(),
                "--with-executables-from",
                "solstone-journal-host",
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

    private func verify(layout: SolstoneRuntimeLayout) async throws -> String? {
        guard fileManager.isExecutableFile(atPath: layout.journalBinary.path) else {
            return "journal executable missing at \(layout.journalBinary.path)"
        }
        guard try await verifyJournalVersion(layout: layout) else {
            return "journal --version check failed (mismatch or non-zero exit)"
        }
        guard try await verifyJournalHostImports(layout: layout) else {
            return "journal host import (frontmatter) check failed"
        }
        guard try await verifyPython(at: bundledPythonURL) else {
            return "bundled python check failed at \(bundledPythonURL.path)"
        }
        let materializedPython = layout.binDir.appendingPathComponent("python3.13")
        if fileManager.fileExists(atPath: materializedPython.path) {
            let resolved = materializedPython.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == bundledPythonURL.standardizedFileURL.path else {
                return "materialized python3.13 link does not resolve to bundled python"
            }
        } else {
            try createBundledPythonLink(layout: layout)
        }
        guard try await verifyPython(at: materializedPython) else {
            return "materialized python check failed at \(materializedPython.path)"
        }
        do {
            let scripts = try discoverConsoleScripts(in: layout)
            let rootPath = layout.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            for script in scripts {
                let path = script.resolved.path
                guard path == rootPath || path.hasPrefix(rootPath + "/") else {
                    return "console script \(script.name) resolves outside runtime root: \(path)"
                }
            }
        } catch {
            return "console script discovery failed: \(error.localizedDescription)"
        }
        return nil
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

    private func verifyJournalHostImports(layout: SolstoneRuntimeLayout) async throws -> Bool {
        let consoleScript = layout.journalBinary.resolvingSymlinksInPath()
        let venvPython = consoleScript.deletingLastPathComponent().appendingPathComponent("python")
        let output = LockedRuntimeMaterializerOutput()
        let result = try await runner.run(
            executable: venvPython,
            arguments: ["-c", "import frontmatter"],
            environment: layout.uvEnvironment(),
            stdoutHandler: { _ in },
            stderrHandler: { data in output.append(data) }
        )
        if result.exitCode != 0 {
            Logger.setup.warning("runtime materializer: journal host import check failed: \(output.string(), privacy: .public)")
        }
        return result.exitCode == 0
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

    private func discoverConsoleScripts(in layout: SolstoneRuntimeLayout) throws -> [(name: String, entry: URL, resolved: URL)] {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: layout.binDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw RuntimeMaterializerError.verificationFailed(
                "could not enumerate runtime bin directory \(layout.binDir.path): \(error.localizedDescription)"
            )
        }

        var scripts: [(name: String, entry: URL, resolved: URL)] = []
        for entry in entries {
            let name = entry.lastPathComponent
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.fileExists(atPath: resolved.path) else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) target missing or dangling: \(resolved.path)"
                )
            }

            let data: Data
            do {
                data = try Data(contentsOf: resolved)
            } catch {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) target unreadable: \(resolved.path): \(error.localizedDescription)"
                )
            }

            guard let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let lines = text.components(separatedBy: "\n")
            guard Self.isUvPolyglot(lines) else {
                continue
            }
            scripts.append((name: name, entry: entry, resolved: resolved))
        }
        return scripts
    }

    /// Rewrites every uv polyglot console script discovered in `bin/` so it survives temp -> final rename.
    /// uv writes console entrypoints as absolute symlinks into `<tools>/.../bin/` and the scripts there
    /// carry an absolute python trampoline into the staging venv. Both reference the `.tmp-*` staging dir,
    /// which vanishes after rename. Rewrite entrypoint symlinks to relative targets and trampolines to the final venv python.
    private func makeRelocationSafe(layout: SolstoneRuntimeLayout, finalURL: URL) throws {
        let tempRoot = layout.rootURL.standardizedFileURL.path
        for script in try discoverConsoleScripts(in: layout) {
            let entry = script.entry
            let name = script.name
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
        guard Self.isUvPolyglot(lines) else {
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

    /// Fails loudly if any discovered uv console script would dangle post-rename. All scripts get
    /// static relocation checks; `sol` and `journal` also get a `--version` liveness probe. The
    /// probe is intentionally limited because entries like `mlx-vlm-server` do not implement `--version`.
    private func assertRelocationSafe(layout: SolstoneRuntimeLayout) async throws {
        let rootPath = layout.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let scripts = try discoverConsoleScripts(in: layout)
        for script in scripts {
            let name = script.name
            let entry = script.entry
            let resolved = script.resolved
            guard fileManager.isExecutableFile(atPath: resolved.path) else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) does not resolve to an executable: \(resolved.path)"
                )
            }
            try assertWithinRoot(resolved.path, rootPath: rootPath, what: "entrypoint \(name)")
            let destination = try fileManager.destinationOfSymbolicLink(atPath: entry.path)
            guard !destination.hasPrefix("/") else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) is not a relative symlink after relocation: \(destination)"
                )
            }

            let scriptText = try String(contentsOf: resolved, encoding: .utf8)
            let lines = scriptText.components(separatedBy: "\n")
            guard lines.first == "#!/bin/sh" else {
                throw RuntimeMaterializerError.verificationFailed("console script \(name) lost its space-safe shebang")
            }
            if lines.contains(where: { containsStagingSegment(in: $0) }) {
                throw RuntimeMaterializerError.verificationFailed("console script \(name) references staging dir after relocation")
            }
            guard lines.count >= 2,
                  let interpreterPath = uvPolyglotInterpreterPath(from: lines[1]) else {
                throw RuntimeMaterializerError.verificationFailed("console script \(name) lost its uv python trampoline")
            }
            let standardizedInterpreter = URL(fileURLWithPath: interpreterPath).standardizedFileURL.path
            try assertWithinRoot(standardizedInterpreter, rootPath: rootPath, what: "entrypoint \(name) trampoline")
        }

        let probeNames: Set<String> = ["sol", "journal"]
        let probes: [(name: String, executable: URL)] = scripts
            .filter { probeNames.contains($0.name) }
            .map { (name: $0.name, executable: $0.resolved) }
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

    private static func isUvPolyglot(_ lines: [String]) -> Bool {
        lines.count >= 2 && lines[0] == "#!/bin/sh" && lines[1].hasPrefix("'''exec' '")
    }

    private func uvPolyglotInterpreterPath(from line: String) -> String? {
        let prefix = "'''exec' "
        guard line.hasPrefix(prefix) else { return nil }
        var index = line.index(line.startIndex, offsetBy: prefix.count)
        guard index < line.endIndex, line[index] == "'" else { return nil }
        index = line.index(after: index)

        var value = ""
        while index < line.endIndex {
            let character = line[index]
            if character == "'" {
                let backslashIndex = line.index(after: index)
                if backslashIndex < line.endIndex,
                   line[backslashIndex] == "\\" {
                    let escapedQuoteIndex = line.index(after: backslashIndex)
                    if escapedQuoteIndex < line.endIndex,
                       line[escapedQuoteIndex] == "'" {
                        let reopenQuoteIndex = line.index(after: escapedQuoteIndex)
                        if reopenQuoteIndex < line.endIndex,
                           line[reopenQuoteIndex] == "'" {
                            value.append("'")
                            index = line.index(after: reopenQuoteIndex)
                            continue
                        }
                    }
                }
                return value
            }
            value.append(character)
            index = line.index(after: index)
        }
        return nil
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
        let script = ManagedWrapper.script(forTarget: target.path)
        try Data((script + "\n").utf8).write(to: wrapper, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    private func garbageCollect(keeping key: String, liveKey: String?) {
        Self.sweepRuntimeGenerations(in: runtimeRootURL, currentKey: key, liveKey: liveKey, fileManager: fileManager)
    }

    /// Remove every directory in `root` whose name is a valid runtime-generation key
    /// other than `currentKey` and `liveKey`, regardless of version. Never throws:
    /// enumeration and per-entry delete failures are logged and skipped so a GC failure
    /// can never abort an otherwise-successful materialize.
    internal static func sweepRuntimeGenerations(in root: URL, currentKey: String, liveKey: String?, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Logger.setup.warning("runtime GC: could not enumerate runtime root: \(error.localizedDescription, privacy: .public)")
            return
        }
        for child in children {
            let name = child.lastPathComponent
            guard isRuntimeGenerationDirectory(name: name) else { continue }
            guard name != currentKey, name != liveKey else { continue }
            do {
                try fileManager.removeItem(at: child)
            } catch {
                Logger.setup.warning("runtime GC: could not remove orphaned generation \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// True when `name` is a complete runtime-generation key: `<version>_py<build>_<hash>`
    /// with `<hash>` exactly 16 lowercase hex chars. Whole-name (anchored) match.
    internal static func isRuntimeGenerationDirectory(name: String) -> Bool {
        name.wholeMatch(of: /[0-9][0-9A-Za-z.+-]*_py[0-9]+_[0-9a-f]{16}/) != nil
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
