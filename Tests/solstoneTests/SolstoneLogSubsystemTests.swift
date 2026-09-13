// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore
import Testing

@Suite("SolstoneLogSubsystem")
struct SolstoneLogSubsystemTests {
    @Test func persistedHelpPredicateContainsAllSubsystems() {
        let predicate = SolstoneLogSubsystem.persistedHelpPredicate
        for subsystem in [
            SolstoneLogSubsystem.observer,
            SolstoneLogSubsystem.journal,
            SolstoneLogSubsystem.observerSPL,
            SolstoneLogSubsystem.watchdog,
            WatchdogProduct.observer.loggerSubsystem,
            WatchdogProduct.journal.loggerSubsystem,
        ] {
            #expect(predicate.contains("subsystem == \"\(subsystem)\""))
        }
        #expect(!predicate.contains("--level debug"))
        #expect(!predicate.contains("log stream"))
    }
}
