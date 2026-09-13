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
            return "the solstone app"
        case journal:
            return "your journal"
        case observerSPL:
            return "the private network"
        case watchdog, WatchdogProduct.observer.loggerSubsystem, WatchdogProduct.journal.loggerSubsystem:
            return "the helper that keeps them running"
        default:
            return "another part of solstone"
        }
    }

    public static var persistedHelpPredicate: String {
        allForPersistedHelp.map { "subsystem == \"\($0)\"" }.joined(separator: " OR ")
    }
}
