// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@MainActor
protocol JournalMigrationBannerActioning {
    func acknowledge()
}

@MainActor
struct InertJournalMigrationBannerAction: JournalMigrationBannerActioning {
    func acknowledge() {}
}

@MainActor
func acknowledgeJournalMigrationBanner(action: any JournalMigrationBannerActioning) {
    action.acknowledge()
}
