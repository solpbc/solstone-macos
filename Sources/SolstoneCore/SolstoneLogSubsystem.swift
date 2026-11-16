// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

public enum SolstoneLogSubsystem {
    public static let observer = "app.solstone.observer"
    public static let journal = "app.solstone.journal"
    public static let observerSPL = "app.solstone.observer.spl"
    public static let watchdog = "app.solstone.watchdog"

    public static var allForPersistedHelp: [String] {
        [
            observer,
            journal,
            observerSPL,
            watchdog,
            WatchdogProduct.observer.loggerSubsystem,
            WatchdogProduct.journal.loggerSubsystem,
        ]
    }

    /// What an owner is shown when a subsystem has to be named on screen.
    /// The identifiers themselves are symbols and are never renamed, but they carry
    /// retired customer-facing vocabulary, so they never reach an owner-visible surface.
    public static func displayName(for subsystem: String) -> String {
        switch subsystem {
        case observer:
            return MacStrings.macos_desktop_shared_copy_setupapplabel()
        case journal:
            return MacStrings.macos_desktop_shared_copy_setupjournalcardheading()
        case observerSPL:
            return MacStrings.macos_solstonelogsubsystem_theprivatenetwork()
        case watchdog, WatchdogProduct.observer.loggerSubsystem, WatchdogProduct.journal.loggerSubsystem:
            return MacStrings.macos_solstonelogsubsystem_thehelperthatkeepsthemrunning()
        default:
            return MacStrings.macos_solstonelogsubsystem_anotherpartofsolstone()
        }
    }

    public static var persistedHelpPredicate: String {
        allForPersistedHelp.map { "subsystem == \"\($0)\"" }.joined(separator: " OR ")
    }
}
