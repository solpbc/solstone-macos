// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import os
import SPLMark
import SPLTunnel
import Testing
@testable import solstone

@Suite("journal mark derivation", .serialized)
@MainActor
struct JournalMarkDerivationTests {
    private func makeStore() -> DerivedJournalMarkStore {
        DerivedJournalMarkStore(suiteName: "journal-mark-derivation-tests-\(UUID().uuidString)")
    }

    @Test func theMarkIsTheOneFromThePinnedCAAndCarriesItsSpokenColourNames() async throws {
        let expected = try markFromJournalID(CertChain.journalID(ofCAChainPEM: testCACertPEM))

        let derived = try #require(await JournalMarkDerivation.mark(forCAChainPEM: testCACertPEM, store: makeStore()))

        #expect(derived.words == expected.words)
        #expect(derived.icon1.svg == expected.icon1.svg)
        #expect(derived.icon1.color.name == expected.icon1.color.name)
        #expect(derived.icon2.rot == expected.icon2.rot)
        #expect(derived.icon2.color.name == expected.icon2.color.name)
    }

    @Test func itDerivesOnceAndKeepsIt() async throws {
        let store = makeStore()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let derive: @Sendable (String) async throws -> MarkRenderSpec = { journalID in
            calls.withLock { $0 += 1 }
            return try markFromJournalID(journalID)
        }

        let first = await JournalMarkDerivation.mark(forCAChainPEM: testCACertPEM, store: store, derive: derive)
        let second = await JournalMarkDerivation.mark(forCAChainPEM: testCACertPEM, store: store, derive: derive)

        #expect(first != nil)
        #expect(first == second)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func aFailureIsNoMarkAndNothingIsKept() async throws {
        let store = makeStore()
        let failed = await JournalMarkDerivation.mark(
            forCAChainPEM: testCACertPEM,
            store: store,
            derive: { _ in throw MarkError.hashFailed(code: -1) }
        )
        #expect(failed == nil)
        #expect(store.mark(forJournalID: try CertChain.journalID(ofCAChainPEM: testCACertPEM)) == nil)

        #expect(await JournalMarkDerivation.mark(forCAChainPEM: "not a certificate", store: store) == nil)
    }
}
