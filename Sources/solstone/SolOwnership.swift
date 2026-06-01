// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal enum SolOwnership: Equatable {
    case absent
    case appManaged(solPath: String)
    case externallyManaged(solPath: String)

    static func classify(
        candidates: [(path: String, resolved: String)],
        runtimeRoot: String,
        hasLocalJournalCreds: Bool
    ) -> SolOwnership {
        guard !candidates.isEmpty else { return .absent }

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

    static func isUnderRoot(_ resolved: String, root: String) -> Bool {
        let normalizedRoot = normalizeRoot(root)
        return resolved == normalizedRoot || resolved.hasPrefix(normalizedRoot + "/")
    }

    static func defaultResolver(
        runner: SubprocessRunning = SubprocessRunner(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> @Sendable (Bool) async -> SolOwnership {
        { hasLocalJournalCreds in
            await resolve(
                hasLocalJournalCreds: hasLocalJournalCreds,
                runner: runner,
                fileExists: fileExists,
                homeDirectory: homeDirectory
            )
        }
    }

    private static func resolve(
        hasLocalJournalCreds: Bool,
        runner: SubprocessRunning,
        fileExists: @Sendable (String) -> Bool,
        homeDirectory: URL
    ) async -> SolOwnership {
        let runtimeLayout = SolstoneRuntimeLayout()
        var paths: [String] = []

        let runtimeSol = runtimeLayout.solBinary.path
        if fileExists(runtimeSol) {
            paths.append(runtimeSol)
        }

        let preferred = homeDirectory.appendingPathComponent(".local/bin/sol").path
        if fileExists(preferred) {
            paths.append(preferred)
        }

        if let whichPath = await whichSol(runner: runner) {
            paths.append(whichPath)
        }

        let candidates = paths.map { path in
            (path: path, resolved: canonicalPath(path))
        }
        return classify(
            candidates: candidates,
            runtimeRoot: canonicalPath(runtimeLayout.rootURL.path),
            hasLocalJournalCreds: hasLocalJournalCreds
        )
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

    private static func canonicalPath(_ path: String) -> String {
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
