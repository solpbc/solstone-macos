// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Darwin
import Foundation
import os
import SolstoneCore

public struct MaterializedRuntime: Sendable {
    public let key: String
    public let layout: SolstoneRuntimeLayout

    public init(key: String, layout: SolstoneRuntimeLayout) {
        self.key = key
        self.layout = layout
    }
}

public protocol RuntimeMaterializing: Sendable {
    func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime
}

internal enum RuntimeAliasDecision: String, Equatable, Sendable {
    case absent
    case appOwned
    case external
}

internal enum RuntimeAliasOutcome: String, Equatable, Sendable {
    case created
    case refreshed
    case repaired
    case current
    case skipped
    case error
}

internal struct RuntimeAliasLogEvent: Equatable, Sendable {
    let alias: String
    let decision: RuntimeAliasDecision
    let outcome: RuntimeAliasOutcome
    let reason: ManagedWrapper.AliasReason?
    let detail: String?
}

public final class RuntimeMaterializer: RuntimeMaterializing, @unchecked Sendable {
    private static let bundledPythonLinkName = "python3.13"
    private static let exportedEntryClassificationPrefixByteLimit = 4096
    private static let requiredPostRenameProbeEntryNames: Set<String> = ["sol", "journal"]

    private enum ExportedEntryClassification {
        case uvPolyglot
        case uvPlainShebang
        case native

        var isUvAuthored: Bool {
            switch self {
            case .uvPolyglot, .uvPlainShebang:
                return true
            case .native:
                return false
            }
        }
    }

    private enum ExportedEntryContainmentPhase {
        case staging
        case postRename
    }

    private struct ExportedEntry {
        let name: String
        let entry: URL
        let rawDestination: String
        let resolved: URL
        let classification: ExportedEntryClassification
        let inspectedPrefix: Data
    }

    private struct ExportedEntryInspection {
        let classification: ExportedEntryClassification
        let inspectedPrefix: Data
    }

    private let runtimeRootURL: URL
    private let uvBinaryURL: URL
    private let bundledPythonURL: URL
    private let wheelhouseURL: URL
    private let wrapperDirURL: URL
    private let runner: SubprocessRunning
    private let fileManager: FileManager
    private let installTimeout: Duration
    private let verifyTimeout: Duration
    private let aliasLogSink: (@Sendable (RuntimeAliasLogEvent) -> Void)?

    public convenience init(
        runtimeRootURL: URL = SolstoneRuntimeLayout.defaultRootURL,
        uvBinaryURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/uv"),
        bundledPythonURL: URL = SolstoneRuntimeLayout.bundledPythonURL(),
        wheelhouseURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wheelhouse", isDirectory: true),
        wrapperDirURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true),
        installTimeout: Duration = .seconds(180),
        verifyTimeout: Duration = .seconds(120),
        runner: SubprocessRunning = SubprocessRunner(),
        fileManager: FileManager = .default
    ) {
        self.init(
            runtimeRootURL: runtimeRootURL,
            uvBinaryURL: uvBinaryURL,
            bundledPythonURL: bundledPythonURL,
            wheelhouseURL: wheelhouseURL,
            wrapperDirURL: wrapperDirURL,
            installTimeout: installTimeout,
            verifyTimeout: verifyTimeout,
            runner: runner,
            fileManager: fileManager,
            aliasLogSink: nil
        )
    }

    internal init(
        runtimeRootURL: URL = SolstoneRuntimeLayout.defaultRootURL,
        uvBinaryURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/uv"),
        bundledPythonURL: URL = SolstoneRuntimeLayout.bundledPythonURL(),
        wheelhouseURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wheelhouse", isDirectory: true),
        wrapperDirURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true),
        installTimeout: Duration = .seconds(180),
        verifyTimeout: Duration = .seconds(120),
        runner: SubprocessRunning = SubprocessRunner(),
        fileManager: FileManager = .default,
        aliasLogSink: (@Sendable (RuntimeAliasLogEvent) -> Void)?
    ) {
        self.runtimeRootURL = runtimeRootURL
        self.uvBinaryURL = uvBinaryURL
        self.bundledPythonURL = bundledPythonURL
        self.wheelhouseURL = wheelhouseURL
        self.wrapperDirURL = wrapperDirURL
        self.runner = runner
        self.fileManager = fileManager
        self.installTimeout = installTimeout
        self.verifyTimeout = verifyTimeout
        self.aliasLogSink = aliasLogSink
    }

    public func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime {
        let key = try runtimeKey()
        let finalURL = runtimeRootURL.appendingPathComponent(key, isDirectory: true)
        let finalLayout = SolstoneRuntimeLayout(rootURL: finalURL)
        if try await verify(layout: finalLayout, phase: .postRename) == nil {
            let aliasRewrite = rewriteAliases(layout: finalLayout)
            garbageCollect(keeping: key, liveKey: liveKey, aliasRewrite: aliasRewrite)
            return MaterializedRuntime(key: key, layout: finalLayout)
        }

        let tempURL = runtimeRootURL.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        let tempLayout = SolstoneRuntimeLayout(rootURL: tempURL)
        var didRenameToFinal = false
        do {
            try tempLayout.ensureCreated()
            try createBundledPythonLink(layout: tempLayout)
            try await install(into: tempLayout)
            if let reason = try await verify(layout: tempLayout, phase: .staging) {
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
            let aliasRewrite = rewriteAliases(layout: finalLayout)
            garbageCollect(keeping: key, liveKey: liveKey, aliasRewrite: aliasRewrite)
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

    private func projectLeafWheel() throws -> URL {
        let prefix = "solstone_journal-\(BundleConfig.solstonePinVersion)-"
        let matches = try wheelFiles().filter {
            $0.lastPathComponent.hasPrefix(prefix)
        }
        guard matches.count == 1, let wheel = matches.first else {
            throw RuntimeMaterializerError.wheelhouseInvalid("expected exactly one \(prefix)*.whl, found \(matches.count)")
        }
        return wheel
    }

    private func modelsWheel() throws -> URL {
        let prefix = "solstone_journal_models-"
        let matches = try wheelFiles().filter {
            $0.lastPathComponent.hasPrefix(prefix)
        }
        guard matches.count == 1, let wheel = matches.first else {
            throw RuntimeMaterializerError.wheelhouseInvalid("expected exactly one \(prefix)*.whl, found \(matches.count)")
        }
        return wheel
    }

    private func validateWheelhouseContents() throws {
        _ = try projectWheel()
        _ = try projectLeafWheel()
        _ = try modelsWheel()
    }

    private func install(into layout: SolstoneRuntimeLayout) async throws {
        try validateWheelhouseContents()
        let output = LockedRuntimeMaterializerOutput()
        let result = try await runner.run(
            executable: uvBinaryURL,
            arguments: [
                "tool",
                "install",
                try projectLeafWheel().path,
                "--with-executables-from",
                "solstone",
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
            timeout: installTimeout,
            stdoutHandler: { data in output.append(data) },
            stderrHandler: { data in output.append(data) }
        )
        if result.terminationReason == .uncaughtSignal {
            throw RuntimeMaterializerError.installFailed("journal runtime install timed out after \(installTimeout)")
        }
        guard result.exitCode == 0 else {
            throw RuntimeMaterializerError.installFailed(sanitizeJournalDiagnosticOutput(output.string()) ?? output.string())
        }
    }

    private func verify(layout: SolstoneRuntimeLayout, phase: ExportedEntryContainmentPhase) async throws -> String? {
        guard fileManager.isExecutableFile(atPath: layout.journalBinary.path) else {
            return "journal executable missing at \(layout.journalBinary.path)"
        }
        guard fileManager.isExecutableFile(atPath: layout.solBinary.path) else {
            return "sol executable missing at \(layout.solBinary.path)"
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
        let materializedPython = layout.binDir.appendingPathComponent(Self.bundledPythonLinkName)
        if fileManager.fileExists(atPath: materializedPython.path) {
            let resolved = materializedPython.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == bundledPythonURL.standardizedFileURL.path else {
                return "materialized \(Self.bundledPythonLinkName) link does not resolve to bundled python"
            }
        } else {
            try createBundledPythonLink(layout: layout)
        }
        guard try await verifyPython(at: materializedPython) else {
            return "materialized python check failed at \(materializedPython.path)"
        }
        do {
            let entries = try discoverExportedEntries(in: layout)
            for entry in entries {
                try assertUniversalExportedEntryContract(entry, rootURL: layout.rootURL, phase: phase)
                if entry.classification.isUvAuthored {
                    try assertUvAuthoredEntryContract(entry, rootURL: layout.rootURL, phase: phase)
                }
            }
        } catch let error as RuntimeMaterializerError {
            return error.localizedDescription
        } catch {
            return "entrypoint discovery failed: \(error.localizedDescription)"
        }
        return nil
    }

    private func verifyJournalVersion(layout: SolstoneRuntimeLayout) async throws -> Bool {
        let output = LockedRuntimeMaterializerOutput()
        let result = try await runner.run(
            executable: layout.journalBinary,
            arguments: ["--version"],
            environment: layout.uvEnvironment(),
            timeout: verifyTimeout,
            stdoutHandler: { data in output.append(data) },
            stderrHandler: { _ in }
        )
        if result.terminationReason == .uncaughtSignal {
            throw RuntimeMaterializerError.verificationFailed("journal runtime version check timed out after \(verifyTimeout)")
        }
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
            timeout: verifyTimeout,
            stdoutHandler: { _ in },
            stderrHandler: { data in output.append(data) }
        )
        if result.terminationReason == .uncaughtSignal {
            throw RuntimeMaterializerError.verificationFailed("journal runtime host import check timed out after \(verifyTimeout)")
        }
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
            timeout: verifyTimeout,
            stdoutHandler: { data in output.append(data) },
            stderrHandler: { data in output.append(data) }
        )
        if result.terminationReason == .uncaughtSignal {
            throw RuntimeMaterializerError.verificationFailed("journal runtime python check timed out after \(verifyTimeout) at \(url.path)")
        }
        return result.exitCode == 0 && output.string().contains("1")
    }

    private func createBundledPythonLink(layout: SolstoneRuntimeLayout) throws {
        try fileManager.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
        let link = layout.binDir.appendingPathComponent(Self.bundledPythonLinkName)
        if fileManager.fileExists(atPath: link.path) {
            try fileManager.removeItem(at: link)
        }
        try fileManager.createSymbolicLink(at: link, withDestinationURL: bundledPythonURL)
    }

    private func discoverExportedEntries(in layout: SolstoneRuntimeLayout) throws -> [ExportedEntry] {
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

        var exportedEntries: [ExportedEntry] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name == Self.bundledPythonLinkName {
                continue
            }
            guard isSymbolicLink(entry) else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) is not a symlink: \(entry.path)"
                )
            }
            let rawDestination = try fileManager.destinationOfSymbolicLink(atPath: entry.path)
            let diagnosticResolved = entry.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.fileExists(atPath: diagnosticResolved.path) else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) target missing or dangling: \(diagnosticResolved.path)"
                )
            }

            let resolvedPath: String
            do {
                resolvedPath = try canonicalExistingPath(diagnosticResolved.path)
            } catch {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(name) target missing or dangling: \(diagnosticResolved.path)"
                )
            }
            let resolved = URL(fileURLWithPath: resolvedPath)
            let inspection = try classifyExportedEntry(named: name, resolved: resolved, rootURL: layout.rootURL)
            exportedEntries.append(ExportedEntry(
                name: name,
                entry: entry,
                rawDestination: rawDestination,
                resolved: resolved,
                classification: inspection.classification,
                inspectedPrefix: inspection.inspectedPrefix
            ))
        }
        return exportedEntries
    }

    private func classifyExportedEntry(named name: String, resolved: URL, rootURL: URL) throws -> ExportedEntryInspection {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.exportedEntryClassificationPrefixByteLimit) ?? Data()
        } catch {
            throw RuntimeMaterializerError.verificationFailed(
                "entrypoint \(name) target unreadable: \(resolved.path): \(error.localizedDescription)"
            )
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return ExportedEntryInspection(classification: .native, inspectedPrefix: data)
        }
        let lines = text.components(separatedBy: "\n")
        if Self.isUvPolyglot(lines) {
            return ExportedEntryInspection(classification: .uvPolyglot, inspectedPrefix: data)
        }
        if let line = lines.first,
           let interpreter = uvPlainShebangInterpreterPath(from: line),
           pathIsLexicallyUnderRoot(interpreter, rootURL: rootURL) {
            return ExportedEntryInspection(classification: .uvPlainShebang, inspectedPrefix: data)
        }
        return ExportedEntryInspection(classification: .native, inspectedPrefix: data)
    }

    /// Makes every exported entry in `bin/` survive temp -> final rename.
    /// uv writes exported entries as absolute symlinks into `<tools>/.../bin/`; uv-authored targets
    /// carry either a polyglot trampoline or a plain absolute python shebang into the staging venv.
    /// Rewrite every exported symlink to a relative target, and rewrite every uv-authored target to
    /// the relocation-safe polyglot form naming the final venv python.
    private func makeRelocationSafe(layout: SolstoneRuntimeLayout, finalURL: URL) throws {
        let stagingRootPath = try canonicalExistingPath(layout.rootURL.path)
        for entry in try discoverExportedEntries(in: layout) {
            try assertUniversalExportedEntryContract(entry, rootURL: layout.rootURL, phase: .staging)
            let targetRelToRoot = relativePathInsideRoot(canonicalPath: entry.resolved.path, canonicalRootPath: stagingRootPath)
            if entry.classification.isUvAuthored {
                let finalTarget = finalURL.standardizedFileURL.appendingPathComponent(targetRelToRoot)
                let finalVenvPython = finalTarget.deletingLastPathComponent().appendingPathComponent("python").path
                try rewriteUvAuthoredEntryAsPolyglot(entry, to: finalVenvPython)
            }
            // Replace the absolute entrypoint symlink with a relative one.
            try fileManager.removeItem(at: entry.entry)
            try fileManager.createSymbolicLink(atPath: entry.entry.path, withDestinationPath: "../" + targetRelToRoot)
        }
    }

    private func rewriteUvAuthoredEntryAsPolyglot(_ entry: ExportedEntry, to interpreter: String) throws {
        let original = try Data(contentsOf: entry.resolved)
        let attrs = try fileManager.attributesOfItem(atPath: entry.resolved.path)
        let rewritten: Data
        switch entry.classification {
        case .uvPolyglot:
            guard let firstNewline = original.firstIndex(of: 0x0A) else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(entry.name) does not match uv polyglot trampoline"
                )
            }
            let line1Start = original.index(after: firstNewline)
            guard line1Start < original.endIndex,
                  let secondNewline = original[line1Start...].firstIndex(of: 0x0A) else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(entry.name) does not match uv polyglot trampoline"
                )
            }
            var data = Data()
            data.append(original[..<line1Start])
            data.append(Data(uvPolyglotExecLine(for: interpreter).utf8))
            data.append(original[secondNewline...])
            rewritten = data
        case .uvPlainShebang:
            let bodyStart: Data.Index
            if let firstNewline = original.firstIndex(of: 0x0A) {
                bodyStart = original.index(after: firstNewline)
            } else {
                bodyStart = original.endIndex
            }
            var data = Data()
            data.append(Data(uvPolyglotHeader(for: interpreter).utf8))
            data.append(original[bodyStart...])
            rewritten = data
        case .native:
            throw RuntimeMaterializerError.verificationFailed(
                "entrypoint \(entry.name) is not uv-authored"
            )
        }
        try rewritten.write(to: entry.resolved, options: .atomic)
        if let perms = attrs[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: perms], ofItemAtPath: entry.resolved.path)
        }
    }

    private func uvPolyglotHeader(for interpreter: String) -> String {
        "#!/bin/sh\n" + uvPolyglotExecLine(for: interpreter) + "\n' '''\n"
    }

    private func uvPolyglotExecLine(for interpreter: String) -> String {
        "'''exec' " + shellSingleQuoted(interpreter) + " \"$0\" \"$@\""
    }

    /// Fails loudly if any exported entry would dangle post-rename. Every entry gets universal
    /// relocation checks; uv-authored entries also get interpreter checks. `sol` and `journal` are
    /// required exported entries and get a `--version` liveness probe.
    private func assertRelocationSafe(layout: SolstoneRuntimeLayout) async throws {
        let entries = try discoverExportedEntries(in: layout)
        for entry in entries {
            try assertUniversalExportedEntryContract(entry, rootURL: layout.rootURL, phase: .postRename)
            if entry.classification.isUvAuthored {
                try assertUvAuthoredEntryContract(entry, rootURL: layout.rootURL, phase: .postRename)
            }
        }

        let entriesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        let probes: [(name: String, executable: URL)] = try Self.requiredPostRenameProbeEntryNames
            .sorted()
            .map { name in
                guard let entry = entriesByName[name] else {
                    throw RuntimeMaterializerError.verificationFailed(
                        "entrypoint \(name) missing from relocated runtime exports"
                    )
                }
                return (name: name, executable: entry.resolved)
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

    private func assertUniversalExportedEntryContract(
        _ entry: ExportedEntry,
        rootURL: URL,
        phase: ExportedEntryContainmentPhase
    ) throws {
        guard fileManager.isExecutableFile(atPath: entry.resolved.path) else {
            throw RuntimeMaterializerError.verificationFailed(
                "entrypoint \(entry.name) does not resolve to an executable: \(entry.resolved.path)"
            )
        }
        switch phase {
        case .staging:
            guard entry.rawDestination.hasPrefix("/") else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(entry.name) symlink target escapes staging root: \(entry.rawDestination)"
                )
            }
            _ = try assertContainedPath(
                entry.resolved.path,
                rootURL: rootURL,
                phase: phase,
                what: "entrypoint \(entry.name) target",
                missingMessage: { path in
                    "entrypoint \(entry.name) target missing or dangling: \(path)"
                },
                escapeMessage: { _ in
                    "entrypoint \(entry.name) symlink target escapes staging root: \(entry.rawDestination)"
                }
            )
        case .postRename:
            guard !entry.rawDestination.hasPrefix("/") else {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(entry.name) is not a relative symlink after relocation: \(entry.rawDestination)"
                )
            }
            _ = try assertContainedPath(
                entry.resolved.path,
                rootURL: rootURL,
                phase: phase,
                what: "entrypoint \(entry.name) target",
                missingMessage: { path in
                    "entrypoint \(entry.name) target missing or dangling: \(path)"
                },
                escapeMessage: { canonicalPath in
                    "entrypoint \(entry.name) target escapes final root: \(canonicalPath)"
                }
            )
            if let reference = relocatedStagingReference(in: entry.inspectedPrefix, rootURL: rootURL) {
                throw RuntimeMaterializerError.verificationFailed(
                    "entrypoint \(entry.name) references staging dir after relocation: \(reference)"
                )
            }
        }
    }

    private func assertUvAuthoredEntryContract(
        _ entry: ExportedEntry,
        rootURL: URL,
        phase: ExportedEntryContainmentPhase
    ) throws {
        let scriptText = try String(contentsOf: entry.resolved, encoding: .utf8)
        let lines = scriptText.components(separatedBy: "\n")
        let interpreterPath: String
        let what: String
        let missingTarget: (String) -> String
        let escapedTarget: (String) -> String
        switch entry.classification {
        case .uvPolyglot:
            guard lines.first == "#!/bin/sh" else {
                throw RuntimeMaterializerError.verificationFailed("entrypoint \(entry.name) lost its space-safe shebang")
            }
            guard lines.count >= 2,
                  let path = uvPolyglotInterpreterPath(from: lines[1]) else {
                throw RuntimeMaterializerError.verificationFailed("entrypoint \(entry.name) lost its uv python trampoline")
            }
            interpreterPath = path
            what = "entrypoint \(entry.name) trampoline"
            missingTarget = { path in
                "entrypoint \(entry.name) trampoline target missing or dangling: \(path)"
            }
            escapedTarget = { reportedPath in
                switch phase {
                case .staging:
                    return "entrypoint \(entry.name) trampoline escapes staging root: \(reportedPath)"
                case .postRename:
                    return "entrypoint \(entry.name) trampoline escapes final root: \(reportedPath)"
                }
            }
        case .uvPlainShebang:
            guard let line = lines.first,
                  let path = uvPlainShebangInterpreterPath(from: line) else {
                throw RuntimeMaterializerError.verificationFailed("entrypoint \(entry.name) lost its uv python shebang")
            }
            interpreterPath = path
            what = "entrypoint \(entry.name) shebang"
            missingTarget = { path in
                "entrypoint \(entry.name) shebang target missing or dangling: \(path)"
            }
            escapedTarget = { reportedPath in
                switch phase {
                case .staging:
                    return "entrypoint \(entry.name) shebang escapes staging root: \(reportedPath)"
                case .postRename:
                    return "entrypoint \(entry.name) shebang escapes final root: \(reportedPath)"
                }
            }
        case .native:
            return
        }
        if phase == .postRename, lines.contains(where: { containsStagingSegment(in: $0) }) {
            throw RuntimeMaterializerError.verificationFailed("entrypoint \(entry.name) references staging dir after relocation")
        }
        try assertContainedInterpreterPath(
            interpreterPath,
            rootURL: rootURL,
            phase: phase,
            what: what,
            missingMessage: missingTarget,
            escapeMessage: escapedTarget
        )
    }

    /// Containment for a uv polyglot trampoline's interpreter.
    ///
    /// The trampoline points at the runtime's own venv `python`, and that is a symlink chain which
    /// deliberately terminates at the app-bundled interpreter *outside* the runtime root — see
    /// `createBundledPythonLink`, which creates exactly such an outward link on purpose. So
    /// `realpath` on a perfectly healthy bundled runtime always lands outside the root.
    ///
    /// Containment is therefore asserted in two parts:
    ///
    /// 1. the **lexical** path must sit under the root. This is what rejects `..` traversal and a
    ///    trampoline rewritten to point somewhere else entirely.
    /// 2. the **resolved** path must either stay under the root, or be exactly the bundled
    ///    interpreter. This is what rejects an in-root symlink chain escaping to an arbitrary
    ///    target.
    ///
    /// Asserting only (1) — the pre-2026-07-25 behaviour — misses symlink-chain escapes. Asserting
    /// only (2) via `realpath`, which is what this check did between `8a4d769` and this commit,
    /// rejects *every* bundled runtime, because (2)'s legitimate case is the normal case: the
    /// materializer's own link is the one path that is supposed to leave the root. Keep both halves.
    private func assertContainedInterpreterPath(
        _ path: String,
        rootURL: URL,
        phase: ExportedEntryContainmentPhase,
        what: String,
        missingMessage: (String) -> String,
        escapeMessage: (String) -> String
    ) throws {
        let canonicalRoot: String
        do {
            canonicalRoot = try canonicalExistingPath(rootURL.path)
        } catch {
            throw RuntimeMaterializerError.verificationFailed(missingMessage(rootURL.path))
        }

        // (1) lexical containment — no `..` traversal, no unrelated absolute target.
        let lexicalPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard lexicalPath != canonicalRoot,
              ManagedWrapper.isUnderRoot(lexicalPath, root: canonicalRoot) else {
            throw RuntimeMaterializerError.verificationFailed(escapeMessage(lexicalPath))
        }

        // The interpreter must actually exist and be reachable.
        let resolvedPath: String
        do {
            resolvedPath = try canonicalExistingPath(path)
        } catch {
            throw RuntimeMaterializerError.verificationFailed(missingMessage(path))
        }

        // (2) resolved target — under the root, or exactly the bundled interpreter.
        if !ManagedWrapper.isUnderRoot(resolvedPath, root: canonicalRoot) {
            let canonicalBundledPython =
                (try? canonicalExistingPath(bundledPythonURL.path))
                ?? bundledPythonURL.standardizedFileURL.path
            guard resolvedPath == canonicalBundledPython else {
                throw RuntimeMaterializerError.verificationFailed(escapeMessage(resolvedPath))
            }
        }

        // Staging-dir scan runs on the written path, which is what a stale `.tmp-*` would appear in.
        let stagingScanPath: String
        switch phase {
        case .staging:
            stagingScanPath = relativePathInsideRoot(canonicalPath: lexicalPath, canonicalRootPath: canonicalRoot)
        case .postRename:
            stagingScanPath = lexicalPath
        }
        if containsStagingSegment(in: stagingScanPath) {
            throw RuntimeMaterializerError.verificationFailed("\(what) references staging dir: \(lexicalPath)")
        }
    }

    private func assertContainedPath(
        _ path: String,
        rootURL: URL,
        phase: ExportedEntryContainmentPhase,
        what: String,
        missingMessage: (String) -> String,
        escapeMessage: (String) -> String
    ) throws -> String {
        let canonicalPath: String
        let canonicalRoot: String
        do {
            canonicalPath = try canonicalExistingPath(path)
            canonicalRoot = try canonicalExistingPath(rootURL.path)
        } catch {
            throw RuntimeMaterializerError.verificationFailed(missingMessage(path))
        }
        guard canonicalPath != canonicalRoot,
              ManagedWrapper.isUnderRoot(canonicalPath, root: canonicalRoot) else {
            throw RuntimeMaterializerError.verificationFailed(escapeMessage(canonicalPath))
        }
        let stagingScanPath: String
        switch phase {
        case .staging:
            stagingScanPath = relativePathInsideRoot(canonicalPath: canonicalPath, canonicalRootPath: canonicalRoot)
        case .postRename:
            stagingScanPath = canonicalPath
        }
        if containsStagingSegment(in: stagingScanPath) {
            throw RuntimeMaterializerError.verificationFailed("\(what) references staging dir: \(canonicalPath)")
        }
        return canonicalPath
    }

    private func canonicalExistingPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func relativePathInsideRoot(canonicalPath: String, canonicalRootPath: String) -> String {
        let rootComponents = URL(fileURLWithPath: canonicalRootPath).pathComponents
        let pathComponents = URL(fileURLWithPath: canonicalPath).pathComponents
        return pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    private func containsStagingSegment(in text: String) -> Bool {
        text.split(separator: "/").contains { $0.hasPrefix(".tmp-") }
    }

    private func relocatedStagingReference(in data: Data, rootURL: URL) -> String? {
        let roots = uniquePathSpellings(pathSpellings(for: runtimeRootURL) + pathSpellings(for: rootURL))
        for root in roots {
            let rootData = Data(root.utf8)
            guard !rootData.isEmpty else { continue }
            var searchStart = data.startIndex
            while searchStart < data.endIndex,
                  let range = data.range(of: rootData, options: [], in: searchStart..<data.endIndex) {
                let reference = pathReference(in: data, startingAt: range.lowerBound)
                if containsStagingSegment(inPathData: reference) {
                    return printableReference(reference)
                }
                searchStart = range.upperBound
            }
        }
        if let segment = firstStagingSegment(in: data) {
            return printableReference(segment)
        }
        return nil
    }

    private func pathReference(in data: Data, startingAt start: Data.Index) -> Data {
        var end = start
        while end < data.endIndex, !isPathReferenceTerminator(data[end]) {
            end = data.index(after: end)
        }
        return Data(data[start..<end])
    }

    private func isPathReferenceTerminator(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x00, 0x0A, 0x22:
            return true
        default:
            return false
        }
    }

    private func firstStagingSegment(in data: Data) -> Data? {
        var segmentStart = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x2F {
                let segment = data[segmentStart..<index]
                if segmentHasStagingPrefix(segment) {
                    return Data(segment)
                }
                segmentStart = data.index(after: index)
            }
            index = data.index(after: index)
        }
        let segment = data[segmentStart..<data.endIndex]
        return segmentHasStagingPrefix(segment) ? Data(segment) : nil
    }

    private func containsStagingSegment(inPathData data: Data) -> Bool {
        firstStagingSegment(in: data) != nil
    }

    private func segmentHasStagingPrefix(_ segment: Data.SubSequence) -> Bool {
        let prefix: [UInt8] = [0x2E, 0x74, 0x6D, 0x70, 0x2D]
        guard segment.count >= prefix.count else { return false }
        for (offset, byte) in prefix.enumerated() {
            if segment[segment.index(segment.startIndex, offsetBy: offset)] != byte {
                return false
            }
        }
        return true
    }

    private func printableReference(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func isUvPolyglot(_ lines: [String]) -> Bool {
        lines.count >= 2 && lines[0] == "#!/bin/sh" && lines[1].hasPrefix("'''exec' '")
    }

    private func uvPlainShebangInterpreterPath(from line: String) -> String? {
        let prefix = "#!"
        guard line.hasPrefix(prefix) else { return nil }
        let path = String(line.dropFirst(prefix.count))
        guard path.hasPrefix("/") else { return nil }
        return path
    }

    private func pathIsLexicallyUnderRoot(_ path: String, rootURL: URL) -> Bool {
        pathSpellings(for: rootURL).contains { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return path != root && path.hasPrefix(prefix)
        }
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

    private struct AliasRewriteResult {
        var pinnedGenerationKeys: Set<String> = []
        var skipGenerationGC = false

        mutating func absorb(_ reference: ManagedWrapper.AliasReference) {
            switch reference {
            case .determinate(let keys):
                pinnedGenerationKeys.formUnion(keys)
            case .indeterminate:
                skipGenerationGC = true
            }
        }
    }

    private func rewriteAliases(layout: SolstoneRuntimeLayout) -> AliasRewriteResult {
        let runtimeRootPaths = runtimeRootPathSpellings()
        let aliases = [
            (name: "sol", target: layout.solBinary),
            (name: "journal", target: layout.journalBinary)
        ]

        let wrapperDir: URL
        do {
            wrapperDir = try resolvedWrapperDirectory()
        } catch {
            let result = AliasRewriteResult(skipGenerationGC: true)
            for alias in aliases {
                emitAlias(
                    alias: alias.name,
                    decision: .external,
                    outcome: .skipped,
                    reason: .wrapperDirectoryError,
                    detail: error.localizedDescription
                )
            }
            return result
        }

        var result = AliasRewriteResult()
        for alias in aliases {
            let aliasResult = rewriteAlias(
                named: alias.name,
                target: alias.target,
                wrapperDir: wrapperDir,
                runtimeRootPaths: runtimeRootPaths
            )
            result.pinnedGenerationKeys.formUnion(aliasResult.pinnedGenerationKeys)
            result.skipGenerationGC = result.skipGenerationGC || aliasResult.skipGenerationGC
        }
        return result
    }

    private func rewriteAlias(
        named name: String,
        target: URL,
        wrapperDir: URL,
        runtimeRootPaths: [String]
    ) -> AliasRewriteResult {
        let wrapper = wrapperDir.appendingPathComponent(name)
        // Classification-to-rename is not atomic; a leaf mutated externally inside this window can still be replaced.
        // This narrow race is accepted rather than overlooked.
        let decision = classifyAliasLeaf(at: wrapper, runtimeRootPaths: runtimeRootPaths)
        var result = AliasRewriteResult()

        switch decision {
        case .absent:
            if let failure = replaceAliasLeaf(at: wrapper, target: target) {
                emitAlias(alias: name, decision: .absent, outcome: .error, reason: failure.reason, detail: failure.detail)
            } else {
                emitAlias(alias: name, decision: .absent, outcome: .created, reason: nil, detail: "target=\(target.path)")
            }

        case .appOwned(let oldTarget, let mode):
            let isCurrent = oldTarget == target.path && mode == 0o755
            if isCurrent {
                emitAlias(alias: name, decision: .appOwned, outcome: .current, reason: nil, detail: "target=\(target.path)")
                return result
            }

            if let failure = replaceAliasLeaf(at: wrapper, target: target) {
                let pinned = referencedGenerationKeys(in: oldTarget, runtimeRootPaths: runtimeRootPaths)
                result.pinnedGenerationKeys.formUnion(pinned)
                emitAlias(alias: name, decision: .appOwned, outcome: .error, reason: failure.reason, detail: failure.detail)
            } else {
                let outcome: RuntimeAliasOutcome = oldTarget == target.path ? .repaired : .refreshed
                emitAlias(alias: name, decision: .appOwned, outcome: outcome, reason: nil, detail: "target=\(target.path)")
            }

        case .external(let reason, let reference):
            result.absorb(reference)
            emitAlias(alias: name, decision: .external, outcome: .skipped, reason: reason, detail: nil)
        }

        return result
    }

    private func classifyAliasLeaf(at url: URL, runtimeRootPaths: [String]) -> ManagedWrapper.AliasLeafDecision {
        var metadata = stat()
        if Darwin.lstat(url.path, &metadata) != 0 {
            if errno == ENOENT {
                return .absent
            }
            return .external(reason: .metadataError, reference: .indeterminate(reason: .metadataError))
        }

        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            let mode = Int(metadata.st_mode & 0o7777)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                return .external(reason: .readError, reference: .indeterminate(reason: .readError))
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .external(reason: .decodeError, reference: .indeterminate(reason: .decodeError))
            }

            if let target = ManagedWrapper.canonicalTarget(fromExactScriptData: data) {
                if runtimeRootPaths.contains(where: { ManagedWrapper.isUnderRoot(target, root: $0) }) {
                    return .appOwned(target: target, mode: mode)
                }
                return .external(
                    reason: .targetOutsideRoot,
                    reference: .determinate(pinnedGenerationKeys: referencedGenerationKeys(in: text, runtimeRootPaths: runtimeRootPaths))
                )
            }

            let lines = ManagedWrapper.scriptLines(text)
            let reason: ManagedWrapper.AliasReason = ManagedWrapper.containsAppOwnedChildMarker(in: lines)
                ? .noncanonicalBody
                : .unmarked
            return .external(
                reason: reason,
                reference: .determinate(pinnedGenerationKeys: referencedGenerationKeys(in: text, runtimeRootPaths: runtimeRootPaths))
            )

        case S_IFLNK:
            do {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                return .external(
                    reason: .symlink,
                    reference: .determinate(
                        pinnedGenerationKeys: referencedGenerationKeys(
                            inSymlinkDestination: destination,
                            leaf: url,
                            runtimeRootPaths: runtimeRootPaths
                        )
                    )
                )
            } catch {
                return .external(reason: .readlinkError, reference: .indeterminate(reason: .readlinkError))
            }

        default:
            return .external(reason: .notRegularFile, reference: .indeterminate(reason: .notRegularFile))
        }
    }

    private func resolvedWrapperDirectory() throws -> URL {
        var metadata = stat()
        if Darwin.lstat(wrapperDirURL.path, &metadata) != 0 {
            if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try fileManager.createDirectory(at: wrapperDirURL, withIntermediateDirectories: true)
            return wrapperDirURL.resolvingSymlinksInPath().standardizedFileURL
        }

        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
            return wrapperDirURL.standardizedFileURL
        case S_IFLNK:
            let resolved = wrapperDirURL.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw POSIXError(.ENOTDIR)
            }
            return resolved
        default:
            throw POSIXError(.ENOTDIR)
        }
    }

    private func replaceAliasLeaf(at url: URL, target: URL) -> (reason: ManagedWrapper.AliasReason, detail: String)? {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var didRename = false
        defer {
            if !didRename {
                try? fileManager.removeItem(at: temp)
            }
        }

        do {
            try ManagedWrapper.canonicalScriptData(forTarget: target.path).write(to: temp)
        } catch {
            return (.writeError, error.localizedDescription)
        }

        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        } catch {
            return (.modeError, error.localizedDescription)
        }

        if Darwin.rename(temp.path, url.path) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            return (.renameError, POSIXError(code).localizedDescription)
        }

        didRename = true
        return nil
    }

    private func runtimeRootPathSpellings() -> [String] {
        pathSpellings(for: runtimeRootURL)
    }

    private func pathSpellings(for url: URL) -> [String] {
        var paths: [String] = []
        for path in [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path
        ] where !paths.contains(path) {
            paths.append(path)
        }
        if let canonicalPath = try? canonicalExistingPath(url.path),
           !paths.contains(canonicalPath) {
            paths.append(canonicalPath)
        }
        return paths
    }

    private func uniquePathSpellings(_ spellings: [String]) -> [String] {
        var result: [String] = []
        for spelling in spellings where !result.contains(spelling) {
            result.append(spelling)
        }
        return result
    }

    private func referencedGenerationKeys(
        inSymlinkDestination destination: String,
        leaf: URL,
        runtimeRootPaths: [String]
    ) -> Set<String> {
        var keys = referencedGenerationKeys(in: destination, runtimeRootPaths: runtimeRootPaths)
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = URL(fileURLWithPath: destination, relativeTo: leaf.deletingLastPathComponent())
        }
        keys.formUnion(
            referencedGenerationKeys(
                in: destinationURL.resolvingSymlinksInPath().standardizedFileURL.path,
                runtimeRootPaths: runtimeRootPaths
            )
        )
        return keys
    }

    private func referencedGenerationKeys(in text: String, runtimeRootPaths: [String]) -> Set<String> {
        var keys: Set<String> = []
        for root in runtimeRootPaths {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: prefix, range: searchRange) {
                var index = range.upperBound
                var key = ""
                while index < text.endIndex {
                    let character = text[index]
                    guard Self.isRuntimeGenerationKeyCharacter(character) else { break }
                    key.append(character)
                    index = text.index(after: index)
                }
                if Self.isRuntimeGenerationDirectory(name: key) {
                    keys.insert(key)
                }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return keys
    }

    private func emitAlias(
        alias: String,
        decision: RuntimeAliasDecision,
        outcome: RuntimeAliasOutcome,
        reason: ManagedWrapper.AliasReason?,
        detail: String?
    ) {
        let event = RuntimeAliasLogEvent(
            alias: alias,
            decision: decision,
            outcome: outcome,
            reason: reason,
            detail: detail
        )
        var detailParts = ["alias=\(alias)", "decision=\(decision.rawValue)"]
        if let reason {
            detailParts.append("reason=\(reason.description)")
        }
        if let detail, !detail.isEmpty {
            detailParts.append(detail)
        }
        let detailText = detailParts.joined(separator: " ")
        switch outcome {
        case .error:
            Logger.setup.warning("runtime-alias step=alias outcome=\(outcome.rawValue, privacy: .public) detail=\(detailText, privacy: .public)")
        case .skipped:
            Logger.setup.notice("runtime-alias step=alias outcome=\(outcome.rawValue, privacy: .public) detail=\(detailText, privacy: .public)")
        case .created, .refreshed, .repaired, .current:
            Logger.setup.info("runtime-alias step=alias outcome=\(outcome.rawValue, privacy: .public) detail=\(detailText, privacy: .public)")
        }
        aliasLogSink?(event)
    }

    private func garbageCollect(keeping key: String, liveKey: String?, aliasRewrite: AliasRewriteResult) {
        var pinnedKeys = aliasRewrite.pinnedGenerationKeys
        if let liveKey {
            pinnedKeys.insert(liveKey)
        }
        Self.sweepRuntimeGenerations(
            in: runtimeRootURL,
            currentKey: key,
            pinnedKeys: pinnedKeys,
            skipGenerationGC: aliasRewrite.skipGenerationGC,
            fileManager: fileManager
        )
    }

    /// Remove every directory in `root` whose name is a valid runtime-generation key
    /// other than `currentKey` and `pinnedKeys`, regardless of version. Never throws:
    /// enumeration and per-entry delete failures are logged and skipped so a GC failure
    /// can never abort an otherwise-successful materialize.
    internal static func sweepRuntimeGenerations(
        in root: URL,
        currentKey: String,
        pinnedKeys: Set<String>,
        skipGenerationGC: Bool,
        fileManager: FileManager
    ) {
        guard !skipGenerationGC else {
            Logger.setup.notice("runtime GC: skipped because alias reference provenance was indeterminate")
            return
        }
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
            guard name != currentKey, !pinnedKeys.contains(name) else { continue }
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

    private static func isRuntimeGenerationKeyCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 48...57, 65...90, 97...122, 46, 43, 45, 95:
            return true
        default:
            return false
        }
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
