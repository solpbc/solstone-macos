// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Testing
@testable import solstone

@Suite("BrowserRetiredCustodyInteraction")
struct BrowserRetiredCustodyInteractionTests {
    private func opened(_ inventory: BrowserRetiredMaterial<String>) -> BrowserRetiredCustodyInteraction<String> {
        var interaction = BrowserRetiredCustodyInteraction<String>()
        interaction.openSettings()
        interaction.observe(inventory)
        return interaction
    }

    @Test func cancelKeepsMaterialAndStartsNoDiscard() {
        var interaction = opened(.present("earlier pairing"))
        interaction.requestDiscard()
        #expect(interaction.confirmation == "earlier pairing")
        interaction.cancelDiscard()
        #expect(interaction.confirmation == nil)
        let unstarted = interaction.beginDiscard()
        #expect(unstarted == nil)
        #expect(interaction.inventory == .present("earlier pairing"))
        #expect(interaction.showsNotice)
        #expect(!interaction.showsDiscarded)
    }

    @Test(arguments: [BrowserRetiredMaterial<String>.unknown, .present("another pairing")])
    func changedOrUnknownScopeCannotStartAnOldConfirmation(_ newInventory: BrowserRetiredMaterial<String>) {
        var interaction = opened(.present("earlier pairing"))
        interaction.requestDiscard()
        interaction.observe(newInventory)
        let unstarted = interaction.beginDiscard()
        #expect(unstarted == nil)
        #expect(interaction.showsFailure)
        #expect(interaction.showsNotice)
        #expect(!interaction.isDiscarding)
    }

    @Test func measuredEmptyWithoutAnOperationNeverClaimsDiscarded() {
        var interaction = opened(.unknown)
        #expect(!interaction.showsNotice)
        #expect(!interaction.canRequestDiscard)
        interaction.observe(.empty)
        #expect(!interaction.showsDiscarded)
        #expect(!interaction.canRequestDiscard)
    }

    @Test func durableCompletionRequiresMeasuredEmptyAndEndsWhenSettingsCloses() throws {
        var interaction = opened(.present("earlier pairing"))
        interaction.requestDiscard()
        let started = interaction.beginDiscard()
        let request = try #require(started)
        #expect(request.scope == "earlier pairing")
        #expect(interaction.isDiscarding)
        #expect(!interaction.canRequestDiscard)
        interaction.cancelDiscard()
        #expect(interaction.isDiscarding)
        let unstarted = interaction.beginDiscard()
        #expect(unstarted == nil)
        interaction.finishDiscard(request, durablyCompleted: true, inventory: .empty)
        #expect(interaction.showsDiscarded)
        #expect(!interaction.showsNotice)
        #expect(!interaction.showsFailure)
        interaction.observe(.empty)
        #expect(interaction.showsDiscarded)
        interaction.closeSettings()
        interaction.openSettings()
        #expect(!interaction.showsDiscarded)
    }

    @Test(arguments: [BrowserRetiredMaterial<String>.empty, .unknown, .present("remaining material")])
    func incompleteOrUnprovenCleanupCannotClaimDiscarded(_ measured: BrowserRetiredMaterial<String>) throws {
        var interaction = opened(.present("earlier pairing"))
        interaction.requestDiscard()
        let started = interaction.beginDiscard()
        let request = try #require(started)
        interaction.finishDiscard(request, durablyCompleted: false, inventory: measured)
        #expect(!interaction.showsDiscarded)
        #expect(interaction.showsFailure)
        #expect(!interaction.isDiscarding)
        if measured == .unknown {
            #expect(interaction.showsNotice)
            #expect(!interaction.canRequestDiscard)
        }
    }

    @Test func newlyRetiredMaterialCannotBeHiddenByACompletedOlderDiscard() throws {
        var interaction = opened(.present("earlier pairing"))
        interaction.requestDiscard()
        let started = interaction.beginDiscard()
        let request = try #require(started)
        interaction.finishDiscard(request, durablyCompleted: true, inventory: .present("newly retired pairing"))
        #expect(!interaction.showsDiscarded)
        #expect(interaction.showsNotice)
        #expect(interaction.showsFailure)
        interaction.requestDiscard()
        #expect(interaction.confirmation == "newly retired pairing")
    }

    @Test func aClosedSettingsWindowCannotLeaveAResultInItsSuccessor() throws {
        var interaction = opened(.present("earlier pairing"))
        interaction.requestDiscard()
        let started = interaction.beginDiscard()
        let request = try #require(started)
        interaction.closeSettings()
        interaction.openSettings()
        interaction.observe(.present("newer pairing"))
        #expect(interaction.isDiscarding)
        #expect(!interaction.canRequestDiscard)
        interaction.finishDiscard(request, durablyCompleted: true, inventory: .empty)
        #expect(!interaction.isDiscarding)
        #expect(!interaction.showsDiscarded)
        #expect(!interaction.showsFailure)
        #expect(interaction.showsNotice)
        #expect(interaction.inventory == .present("newer pairing"))
    }
}

#endif
