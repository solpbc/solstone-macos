// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

public enum SolOwnership: Equatable {
    case absent
    case appManaged(solPath: String)
    case externallyManaged(solPath: String)

    public enum Provenance: Equatable, CustomStringConvertible {
        case bare
        case appOwnedChild

        public var description: String {
            switch self {
            case .bare:
                return "bare"
            case .appOwnedChild:
                return "appOwnedChild"
            }
        }
    }

    public static func classify(
        candidates: [(path: String, resolved: String, provenance: Provenance)],
        runtimeRoot: String,
        hasLocalJournalCreds: Bool
    ) -> SolOwnership {
        guard !candidates.isEmpty else { return .absent }

        // The app-owned-child wrapper is the authoritative pointer to the active content-addressed runtime.
        if let appOwned = candidates.first(where: {
            $0.provenance == .appOwnedChild && isUnderRoot($0.resolved, root: runtimeRoot)
        }) {
            return .appManaged(solPath: appOwned.path)
        }

        let runtime = candidates.first { isUnderRoot($0.resolved, root: runtimeRoot) }
        let external = candidates.first { !isUnderRoot($0.resolved, root: runtimeRoot) }

        if let external, (runtime == nil || hasLocalJournalCreds) {
            return .externallyManaged(solPath: external.path)
        }
        if let runtime {
            return .appManaged(solPath: runtime.path)
        }
        if let external {
            return .externallyManaged(solPath: external.path)
        }
        return .absent
    }

    public static func isUnderRoot(_ resolved: String, root: String) -> Bool {
        let normalizedRoot = normalizeRoot(root)
        return resolved == normalizedRoot || resolved.hasPrefix(normalizedRoot + "/")
    }

    public static func defaultResolver(
        runner: SubprocessRunning = SubprocessRunner(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        rootURL: URL = SolstoneRuntimeLayout.defaultRootURL
    ) -> @Sendable (Bool) async -> SolOwnership {
        { hasLocalJournalCreds in
            await resolve(
                hasLocalJournalCreds: hasLocalJournalCreds,
                runner: runner,
                fileExists: fileExists,
                homeDirectory: homeDirectory,
                rootURL: rootURL
            )
        }
    }

    private static func resolve(
        hasLocalJournalCreds: Bool,
        runner: SubprocessRunning,
        fileExists: @Sendable (String) -> Bool,
        homeDirectory: URL,
        rootURL: URL
    ) async -> SolOwnership {
        var paths: [String] = []

        let preferred = homeDirectory.appendingPathComponent(".local/bin/sol").path
        if fileExists(preferred) {
            paths.append(preferred)
        }

        if let whichPath = await whichSol(runner: runner) {
            paths.append(whichPath)
        }

        let candidates = paths.map { path -> (path: String, resolved: String, provenance: Provenance) in
            let parsed = parseManagedWrapper(forFileAt: path)
            let resolved = parsed.target.map(canonicalPath) ?? canonicalPath(path)
            return (path: path, resolved: resolved, provenance: parsed.provenance)
        }
        let verdict = classify(
            candidates: candidates,
            runtimeRoot: canonicalPath(rootURL.path),
            hasLocalJournalCreds: hasLocalJournalCreds
        )
        let verdictName: String = {
            switch verdict {
            case .absent:
                return "absent"
            case .appManaged:
                return "appManaged"
            case .externallyManaged:
                return "externallyManaged"
            }
        }()
        let chosenSolPath: String = {
            switch verdict {
            case .absent:
                return ""
            case .appManaged(let p), .externallyManaged(let p):
                return p
            }
        }()
        let candidateTrace = candidates.map { "\($0.path) -> \($0.resolved) [\($0.provenance)]" }.joined(separator: "; ")
        Logger.setup.notice("sol ownership resolved: verdict=\(verdictName, privacy: .public) chosen=\(chosenSolPath, privacy: .public) hasLocalJournalCreds=\(hasLocalJournalCreds, privacy: .public) candidates=\(candidateTrace, privacy: .public)")
        return verdict
    }

    private static func whichSol(runner: SubprocessRunning) async -> String? {
        let output = LockedSolOwnershipOutput()
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/which"),
                arguments: ["sol"],
                environment: nil,
                stdoutHandler: { data in output.append(data) },
                stderrHandler: { _ in }
            )
            guard result.exitCode == 0 else { return nil }
            let path = output.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private static func parseManagedWrapper(forFileAt path: String) -> (provenance: Provenance, target: String?) {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return (.bare, nil) }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)

        let provenance: Provenance
        if lines.contains(where: { line in
            let trimmedLeading = line.drop(while: { $0.isWhitespace })
            return trimmedLeading == ManagedWrapper.appOwnedChildMarker
        }) {
            provenance = .appOwnedChild
        } else {
            provenance = .bare
        }

        // Precedence: a literal `exec '...' "$@"` target is authoritative.
        if let literalTarget = lines.lazy.compactMap({ ManagedWrapper.execTarget(fromLine: String($0)) }).first {
            return (provenance, literalTarget)
        }

        // Otherwise, if the exec line dereferences $SOL_BIN, honor the last
        // uncommented single-quoted SOL_BIN assignment (shell last-assignment wins).
        if lines.contains(where: { ManagedWrapper.execDereferencesSolBin(String($0)) }) {
            let target = lines.reversed().lazy
                .compactMap { ManagedWrapper.solBinAssignment(fromLine: String($0)) }
                .first
            return (provenance, target)
        }

        return (provenance, nil)
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func normalizeRoot(_ root: String) -> String {
        guard root != "/" else { return root }
        var normalized = root
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

private final class LockedSolOwnershipOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var string: String {
        lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }
}
