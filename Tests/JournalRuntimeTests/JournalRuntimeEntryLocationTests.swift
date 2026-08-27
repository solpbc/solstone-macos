// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalRuntime

@Suite("JournalRuntimeEntryLocation")
struct JournalRuntimeEntryLocationTests {
    @Test func classifiesAppTranslocationWithoutRetainingPath() {
        let dependencies = JournalRuntimeEntryLocationClassifier.Dependencies(
            cachesURL: URL(fileURLWithPath: "/cache", isDirectory: true),
            temporaryDirectoryURL: URL(fileURLWithPath: "/temporary", isDirectory: true),
            volumeFacts: { _ in .init(isInternal: true, isLocal: true) }
        )

        #expect(JournalRuntimeEntryLocationClassifier.classify(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/journal.app"),
            dependencies: dependencies
        ) == .translocated)
    }

    @Test func classifiesOnlyInternalLocalNonTemporaryLocationAsStandard() {
        let standard = JournalRuntimeEntryLocationClassifier.Dependencies(
            cachesURL: URL(fileURLWithPath: "/cache", isDirectory: true),
            temporaryDirectoryURL: URL(fileURLWithPath: "/temporary", isDirectory: true),
            volumeFacts: { _ in .init(isInternal: true, isLocal: true) }
        )
        let external = JournalRuntimeEntryLocationClassifier.Dependencies(
            cachesURL: URL(fileURLWithPath: "/cache", isDirectory: true),
            temporaryDirectoryURL: URL(fileURLWithPath: "/temporary", isDirectory: true),
            volumeFacts: { _ in .init(isInternal: false, isLocal: true) }
        )

        #expect(JournalRuntimeEntryLocationClassifier.classify(
            bundleURL: URL(fileURLWithPath: "/Applications/journal.app"),
            dependencies: standard
        ) == .standard)
        #expect(JournalRuntimeEntryLocationClassifier.classify(
            bundleURL: URL(fileURLWithPath: "/Applications/journal.app"),
            dependencies: external
        ) == .other)
        #expect(JournalRuntimeEntryLocationClassifier.classify(
            bundleURL: URL(fileURLWithPath: "/temporary/journal.app"),
            dependencies: standard
        ) == .other)
    }
}
