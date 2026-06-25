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

    @Test func doctorProgressStateCompanionIsUnconditional() throws {
        let source = try readWireUpSource("Sources/solstone/BundledServiceCard.swift")
        let nilBranchRange = try #require(source.range(of: "if doctorResult == nil {"))
        let nilBranchEnd = try #require(
            matchingClosingBrace(in: source, openingBrace: source.index(before: nilBranchRange.upperBound))
        )
        let nilBranch = String(source[nilBranchRange.lowerBound...nilBranchEnd])
        let companionRange = try #require(source.range(of: "id: AXID.Installer.doctorProgressState"))

        #expect(wireUpContains(source, """
            }
            AXStateCompanion(
                id: AXID.Installer.doctorProgressState,
                value: doctorProgressAXToken(for: doctorResult)
            )
            """))
        #expect(!nilBranch.contains("AXID.Installer.doctorProgressState"))
        #expect(companionRange.lowerBound > nilBranchEnd)
        #expect(!wireUpContains(source, ".accessibilityValue(String(doctorResult == nil))"))
    }

    @Test func doctorRowsUseSelectableUntruncatedText() throws {
        let source = try readWireUpSource("Sources/solstone/BundledServiceCard.swift")
        let checkRow = try functionSource(named: "doctorCheckRow", in: source)
        let errorRow = try functionSource(named: "doctorErrorRow", in: source)

        #expect(checkRow.components(separatedBy: ".textSelection(.enabled)").count >= 3)
        #expect(!checkRow.contains(".lineLimit(1)"))
        #expect(!checkRow.contains(".truncationMode(.tail)"))
        #expect(errorRow.contains(".textSelection(.enabled)"))
        #expect(!errorRow.contains(".lineLimit(3)"))
    }

    @Test func restartDoctorUsesAuthoritativeJournalBinary() throws {
        let source = try readWireUpSource("Sources/solstone/BundledServiceCard.swift")
        let body = try functionSource(named: "restartDoctor", in: source)
        #expect(wireUpContains(body, "guard let binary = appState.journalBinaryProvider() else { return }"))
        #expect(wireUpContains(body, "JournalHealthCheck.doctor(journalBinary: binary, runner: runner)"))
        #expect(!body.contains("JournalHealthCheck.doctor(runner: runner)"))
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

    private func functionSource(named name: String, in source: String) throws -> String {
        let range = try #require(source.range(of: "private func \(name)"))
        let openingBrace = try #require(source[range.upperBound...].firstIndex(of: "{"))
        let closingBrace = try #require(matchingClosingBrace(in: source, openingBrace: openingBrace))
        return String(source[range.lowerBound...closingBrace])
    }

    private func matchingClosingBrace(in source: String, openingBrace: String.Index) -> String.Index? {
        guard source[openingBrace] == "{" else { return nil }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return index
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
