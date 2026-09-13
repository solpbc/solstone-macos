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

    public static var persistedHelpPredicate: String {
        allForPersistedHelp.map { "subsystem == \"\($0)\"" }.joined(separator: " OR ")
    }
}
