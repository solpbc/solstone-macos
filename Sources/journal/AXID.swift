// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum AXID {
    enum Journal {
        enum Sidebar {
            static func tab(_ pane: JournalPane) -> String {
                "journal.sidebar.tab.\(pane.rawValue)"
            }

            static func tabState(_ pane: JournalPane) -> String {
                "journal.sidebar.tab.\(pane.rawValue).state"
            }
        }

        enum Home {
            static let markCard = "journal.home.mark.card"
            static let nameState = "journal.home.name.state"
            static let runDisplayGlanceState = "journal.home.runDisplay.glance.state"
            static let openJournal = "journal.home.open"
            static let unconfiguredMessageState = "journal.home.unconfigured.message.state"
        }

        enum Pane {
            static let nameField = "journal.journal.name.field"
            static let nameSave = "journal.journal.name.save"
            static let locationPathState = "journal.journal.location.path.state"
            static let diskUsageState = "journal.journal.diskUsage.state"
        }

        enum RunState {
            static let start = "journal.runState.start"
            static let stop = "journal.runState.stop"
            static let restart = "journal.runState.restart"
            static let displayState = "journal.runState.display.state"
            static let blockedReasonState = "journal.runState.blockedReason.state"
            static let healthState = "journal.runState.health.state"
            static let runtimeVersionState = "journal.runState.runtimeVersion.state"
            static let appVersionState = "journal.runState.appVersion.state"
        }

        enum Backup {
            static let openBackup = "journal.backup.open"
            static let messageState = "journal.backup.message.state"
        }

        enum Startup {
            static let launchAtLogin = "journal.startup.launchAtLogin"
            static let launchAtLoginState = "journal.startup.launchAtLogin.state"
        }
    }
}
