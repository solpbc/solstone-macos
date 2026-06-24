// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("Menubar WireUp")
struct MenubarWireUpTests {
    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func menuContentReferencesExpectedAXIDs() throws {
        let source = try readWireUpSource("Sources/solstone/MenuContent.swift")
        let references = [
            "AXID.Menubar.pendingChatButton",
            "AXID.Menubar.statusRowState",
            "AXID.Menubar.openJournalButton",
            "AXID.Menubar.settingsButton",
            "AXID.Menubar.aboutButton",
            "AXID.Menubar.quitButton",
            "AXID.Menubar.permissionsButton",
            "AXID.Menubar.errorButton",
            "AXID.Menubar.journalState",
            "AXID.Menubar.localOnlyButton",
            "AXID.Menubar.offlineButton",
            "AXID.Menubar.pauseFifteenMinutes",
            "AXID.Menubar.pauseThirtyMinutes",
            "AXID.Menubar.pauseOneHour",
            "AXID.Menubar.pauseIndefinite",
            "AXID.Menubar.pauseMenu",
            "AXID.Menubar.resumeButton",
            ".accessibilityValue(statusRowAXValue)",
            "statusRowState.axToken",
            ".accessibilityValue(rowState.axToken)",
            "appState.observationRowState",
            "UICopy.MENUBAR_OBSERVATION_WEDGE_OPEN_SETTINGS",
            "UICopy.MENUBAR_LOCAL_ONLY_SETUP_JOURNAL",
            "UICopy.MENUBAR_SYNC_PAUSED",
            "UICopy.MENUBAR_JOURNAL_WAITING",
            "UICopy.MENUBAR_OBSERVING_OFFLINE_SAVED_LOCALLY"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }

    @Test func pauseResumeSectionDividerIsConditional() throws {
        let source = try readWireUpSource("Sources/solstone/MenuContent.swift")

        #expect(wireUpContains(source, """
            Section {
                statusRow
                    .accessibilityValue(statusRowAXValue)
                if hasPauseResumeControl {
                    pauseResumeSection
                }
            }
            Divider()
            """))
    }

    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func statusIconReferencesExpectedAXIDsAndState() throws {
        let source = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let references = [
            "MenubarIconState",
            "iconState.iconName",
            "AXID.Menubar.statusIconState",
            "iconState.axToken",
            "appState.observationRowState.iconState"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }

    @Test func observationSurfacesDoNotUseStoppedLiteral() throws {
        let paths = [
            "Sources/solstone/MenuContent.swift",
            "Sources/solstone/SettingsView.swift",
            "Sources/solstone/SolstoneCaptureApp.swift"
        ]

        for path in paths {
            let source = try readWireUpSource(path)
            #expect(!source.contains("\"stopped\""))
        }

        let axTokenSource = try readWireUpSource("Sources/solstone/AXToken.swift")
        #expect(!axTokenSource.contains("return \"stopped\""))
    }
}
