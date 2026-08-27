// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalRuntime

@Suite("JournalRuntimeEntryCandidateProvenance")
struct JournalRuntimeEntryCandidateProvenanceTests {
    private let identity = JournalRuntimeEntryReceiptAppIdentity(
        appPID: 42,
        bundleIdentifier: "app.solstone.journal",
        bundleShortVersion: "2.0.0",
        bundleVersion: "25",
        locationClass: .standard,
        appKernelStartTimeMicroseconds: 1_000_000
    )

    @Test func readsOneSchemaValidTargetMatchingReferenceFromBundle() throws {
        let resolver = BundledJournalRuntimeEntryCandidateProvenanceResolver(
            bundle: try fixtureBundle(named: "CandidateProvenanceValid")
        )

        let provenance = resolver.resolve(for: identity)

        #expect(provenance?.source == "J")
        #expect(provenance?.target.bundleIdentifier == identity.bundleIdentifier)
        #expect(provenance?.runtimeArchiveSHA256 == String(repeating: "a", count: 64))
    }

    @Test(arguments: [
        "CandidateProvenanceMalformed",
        "CandidateProvenanceDuplicate",
        "CandidateProvenanceTargetMismatch"
    ])
    func rejectsMalformedDuplicateOrTargetMismatchedReference(named name: String) throws {
        let resolver = BundledJournalRuntimeEntryCandidateProvenanceResolver(
            bundle: try fixtureBundle(named: name)
        )

        #expect(resolver.resolve(for: identity) == nil)
    }

    private func fixtureBundle(named name: String) throws -> Bundle {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "bundle",
            subdirectory: "Fixtures"
        ))
        return try #require(Bundle(url: url))
    }
}
