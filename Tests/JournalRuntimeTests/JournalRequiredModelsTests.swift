// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import JournalRuntime

@Suite("Journal required model reconciliation")
struct JournalRequiredModelsTests {
    @Test func repairsPreviousRuntimeCacheInSelectedJournalWithBundledCommand() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let journal = runtime.layout.rootURL.appendingPathComponent("selected journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let sidecar = journal.appendingPathComponent("engine-sha")
        try "previous-signed-archive\n".write(to: sidecar, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        set -eu
        [ "$#" = 2 ] && [ "$1" = install-models ] && [ "$2" = --required-only ] || exit 41
        [ -z "${SOLSTONE_JOURNAL+x}" ] || exit 42
        [ "$(command -v journal)" = "$0" ] || exit 43
        [ "$(cat engine-sha)" = previous-signed-archive ] || exit 44
        printf 'current-signed-archive\\n' > engine-sha
        """
        try script.write(to: runtime.layout.journalBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.layout.journalBinary.path)
        let scoped = MaterializedRuntime(key: runtime.key, layout: runtime.layout,
            environment: ["PATH": "/usr/bin:/bin", "SOLSTONE_JOURNAL": "/wrong/inherited/journal"])
        try await JournalRequiredModelsReconciler().reconcile(runtime: scoped, journalRoot: journal)
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "current-signed-archive\n")
    }

    @Test func nativeNonzeroExitPropagates() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let subprocess = FakeSubprocessRunner()
        subprocess.enqueue("install-models", .success(exitCode: 65))
        let reconciler = JournalRequiredModelsReconciler(makeRunner: { _ in subprocess })
        await #expect(throws: SupervisedJournalRunnerError.self) {
            try await reconciler.reconcile(runtime: runtime, journalRoot: runtime.layout.rootURL)
        }
        #expect(subprocess.invocations.count == 1)
        #expect(subprocess.invocations.first?.arguments == ["install-models", "--required-only"])
        #expect(subprocess.invocations.first?.timeout == .seconds(120))
    }

    @Test func timeoutCannotBecomeSuccessfulReconciliation() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let subprocess = FakeSubprocessRunner()
        subprocess.enqueue("install-models", .success(delay: .seconds(1)))
        let reconciler = JournalRequiredModelsReconciler(timeout: .milliseconds(1), makeRunner: { _ in subprocess })
        await #expect(throws: SupervisedJournalRunnerError.self) {
            try await reconciler.reconcile(runtime: runtime, journalRoot: runtime.layout.rootURL)
        }
    }
}
