// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("Desktop shell routing")
struct DesktopShellRoutingTests {
    private func route(_ name: String, screenMissing: Bool = false, microphoneMissing: Bool = false) -> ShellRoute? {
        SettingsView.Tab(legacyRoute: name).map {
            ShellRoute(tab: $0, screenPermissionMissing: screenMissing, microphonePermissionMissing: microphoneMissing)
        }
    }

    @Test func everyLegacyRouteLandsOnItsNewHome() {
        #expect(route("home") == ShellRoute(shelf: .home, pane: nil))
        #expect(route("sources") == ShellRoute(shelf: .home, pane: nil))
        #expect(route("status") == ShellRoute(shelf: .home, pane: .status))
        #expect(route("microphones") == ShellRoute(shelf: .home, pane: .source(.audio)))
        #expect(route("privacy") == ShellRoute(shelf: .home, pane: .source(.screen)))
        #expect(route("journal") == ShellRoute(shelf: .service, pane: nil))
        #expect(route("service") == ShellRoute(shelf: .service, pane: nil))
        #expect(route("observer") == ShellRoute(shelf: .observer, pane: nil))
        #expect(route("general") == ShellRoute(shelf: .observer, pane: nil))
        #expect(route("updates") == ShellRoute(shelf: .updates, pane: nil))
        #expect(route("help") == ShellRoute(shelf: .help, pane: nil))
        #expect(route("nonsense") == nil)
    }

    @Test func permissionsOpensThePageWhosePermissionIsMissing() {
        #expect(route("permissions", screenMissing: true)?.pane == .source(.screen))
        #expect(route("permissions", microphoneMissing: true)?.pane == .source(.audio))
        #expect(route("permissions", screenMissing: true, microphoneMissing: true)?.pane == .source(.screen))
        #expect(route("permissions")?.pane == .source(.screen))
    }

    @Test func leftOutListsLiveOnScreenAndBrowsersOnly() {
        #expect(SettingsView.paneHoldsLeftOut(.source(.screen)))
        #expect(SettingsView.paneHoldsLeftOut(.source(.browsers)))
        #expect(!SettingsView.paneHoldsLeftOut(.source(.audio)))
        #expect(!SettingsView.paneHoldsLeftOut(.status))
        #expect(!SettingsView.paneHoldsLeftOut(nil))
    }

    /// Release automation clicks these by id, so they stay exactly as they were.
    @Test func idsAutomationDependsOnAreUnchanged() {
        #expect(AXID.Settings.Sidebar.row(.service) == "settings.sidebar.tab.service")
        #expect(AXID.Settings.Sidebar.row(.updates) == "settings.sidebar.tab.updates")
        #expect(AXID.Deck.pill == "settings.sidebar.tab.status")
        #expect(AXID.Settings.Status.observingState == "settings.status.observing.state")
        #expect(AXID.Settings.Status.nextSegmentSeconds == "settings.status.observing.nextSegment.state")
        #expect(AXID.Settings.Permissions.screenRecordingLiveState == "settings.permissions.screenRecording.live.state")
        #expect(AXID.Settings.Permissions.microphoneLiveState == "settings.permissions.microphone.live.state")
        #expect(SolstoneSceneID.settings.rawValue == "settings")
        let contract = Set(AXContract.enumerableIDs)
        #expect(contract.contains("settings.sidebar.tab.service"))
        #expect(contract.contains("settings.sidebar.tab.updates"))
        #expect(contract.contains("settings.sidebar.tab.status"))
    }

    @Test func visitedTabNamesKeepTheirPersistedStrings() {
        #expect(SettingsView.Tab.service.rawValue == "service")
        #expect(SettingsView.Tab.status.rawValue == "status")
        #expect(SettingsView.Tab.permissions.rawValue == "permissions")
    }
}
