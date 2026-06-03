// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("Installer WireUp")
struct InstallerWireUpTests {
    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func bundledServiceCardReferencesExpectedAXIDs() throws {
        let source = try readWireUpSource("Sources/solstone/BundledServiceCard.swift")
        let references = [
            "AXID.Installer.terminalState",
            "InstallerProgressRowView(row: .checkingSystem",
            "AXID.Installer.installedMessageState",
            "AXID.Installer.install",
            "AXID.Installer.openDashboard",
            "AXID.Installer.externalManagedState",
            "AXID.Installer.externalManagedPathState",
            "AXID.Installer.doctorDisclosure",
            "AXID.Installer.doctorRefresh",
            "AXID.Installer.doctorProgressState",
            "AXID.Installer.doctorChecklist",
            "AXID.Installer.doctorCheck(check.name)",
            "AXID.Installer.doctorErrorState",
            "AXID.Installer.doctorRetry",
            "AXID.Installer.autoTestState",
            "AXID.Installer.autoTestRetry",
            "AXID.Installer.cleanupStep(step)",
            "AXID.Installer.failureSummaryState",
            "AXID.Installer.failureRetry",
            "AXID.Installer.failureLog",
            "AXID.Installer.failureDetails",
            "AXID.Installer.modelDownloadProgress",
            "InstallerProgressRowView(row: row",
            "AXID.Installer.journalPathState",
            "AXID.Installer.journalTCCRestrictedState",
            "AXID.Installer.journalChange",
            "AXID.Installer.diagnosticCopy",
            "AXID.Installer.diagnosticCopiedState",
            "AXID.Installer.diagnosticHelp"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }

    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func installerProgressRowReferencesExpectedAXIDs() throws {
        let source = try readWireUpSource("Sources/solstone/InstallerProgressRowView.swift")
        let references = [
            "AXID.Installer.stepState(row)",
            "AXID.Installer.stepCurrentStep(row)",
            "AXID.Installer.stepDetails(row)",
            "AXID.Installer.stepLog(row)",
            "AXID.Installer.step(row)",
            ".accessibilityLabel(\"failed\")"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }
}
