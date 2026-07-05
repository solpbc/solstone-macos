// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing

@Suite("Updates WireUp")
struct UpdatesWireUpTests {
    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func updatesTabReferencesExpectedAXIDs() throws {
        let source = try readWireUpSource("Sources/UpdateKit/UpdatesTabView.swift")
        let references = [
            "UpdatesAXID.statusState",
            "UpdatesAXID.unavailable",
            "UpdatesAXID.debugStatePicker",
            "UpdatesAXID.cancel",
            "UpdatesAXID.check",
            "UpdatesAXID.download",
            "UpdatesAXID.dismiss",
            "UpdatesAXID.dismissStaged",
            "UpdatesAXID.extractProgress",
            "UpdatesAXID.install",
            "UpdatesAXID.retry",
            "UpdatesAXID.automaticChecks",
            "UpdatesAXID.frequencyPicker",
            "UpdatesAXID.frequencyState",
            "UpdatesAXID.automaticDownloads",
            "UpdatesAXID.releaseNotesOnline",
            "UpdatesAXID.releaseNotes",
            "UpdatesAXID.downloadProgress",
            "UpdatesAXID.deferredInstallState"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }

    @Test func stagedInstallButtonRoutesThroughUpdateController() throws {
        let source = try readWireUpSource("Sources/UpdateKit/UpdatesTabView.swift")
        let functionStart = try #require(source.range(of: "private func relaunchToInstallStagedUpdate()"))
        let functionEnd = try #require(source[functionStart.upperBound...].range(of: "private func titleBlock"))
        let body = String(source[functionStart.lowerBound..<functionEnd.lowerBound])

        #expect(wireUpContains(body, "controller.installStagedUpdate()"))
        #expect(!wireUpContains(body, "NSApplication.shared.terminate(nil)"))
    }
}

private func readWireUpSource(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

private func wireUpContains(_ source: String, _ reference: String) -> Bool {
    source.filter { !$0.isWhitespace }.contains(reference.filter { !$0.isWhitespace })
}
