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
            "AXID.Menubar.pipelineState",
            "AXID.Menubar.localOnlyButton",
            "AXID.Menubar.offlineButton",
            "AXID.Menubar.pauseFifteenMinutes",
            "AXID.Menubar.pauseThirtyMinutes",
            "AXID.Menubar.pauseOneHour",
            "AXID.Menubar.pauseIndefinite",
            "AXID.Menubar.pauseMenu",
            "AXID.Menubar.resumeButton",
            "AXID.Menubar.startObservingButton",
            "AXID.Menubar.restartPipelineButton",
            "value: statusRowAXValue",
            "statusRowState.axToken",
            ".accessibilityValue(rowState.axToken)",
            "return .paused"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }

    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func statusIconReferencesExpectedAXIDsAndState() throws {
        let source = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let references = [
            "MenubarIconState",
            "iconState.iconName",
            "AXID.Menubar.statusIconState",
            "iconState.axToken"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }
}
