// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

@MainActor
enum AboutPresentation {
    static func captureBlock(journal: JournalVersionMetadata, now: Date = Date()) -> String {
        let observed = journal.versionObservedAt
        let hasObservation = observed != nil
        let age: String? = {
            guard !journal.isCurrent, let observed, observed <= now else { return nil }
            return coarseRelativeTime(observed, now: now)
        }()
        return SolstoneCoreAbout.captureBlock(
            appVersion: AppVersion.short,
            appBuild: AppVersion.build,
            osVersion: SolstoneCoreAbout.numericOSVersion(ProcessInfo.processInfo.operatingSystemVersion),
            arch: SolstoneCoreAbout.nativeMacOSArch(),
            journalVersion: journal.version,
            journalBuild: hasObservation ? journal.hostBuild : nil,
            journalOS: hasObservation ? journal.hostOS : nil,
            journalOSVersion: hasObservation ? journal.hostOSVersion : nil,
            journalArch: hasObservation ? journal.hostArch : nil,
            journalAge: age
        )
    }

    static func nativeSnapshot(journal: JournalVersionMetadata) -> SolstoneCoreAbout.NativeSnapshot {
        journal.nativeAboutSnapshot(
            os: "macos",
            osVersion: SolstoneCoreAbout.numericOSVersion(ProcessInfo.processInfo.operatingSystemVersion),
            arch: SolstoneCoreAbout.nativeMacOSArch()
        )
    }
}
