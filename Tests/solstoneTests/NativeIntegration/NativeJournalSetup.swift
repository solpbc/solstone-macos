// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import JournalMarkKit

enum NativeJournalSetupError: Error, Equatable {
    case markNotLocked
    case markChanged
}

func establishNativeJournalSession(client: JournalInitClient) async throws -> JournalInitFinalizeResponse {
    let selected = try await client.getMark()
    let locked: JournalInitMarkResponse
    if let proposalID = selected.proposalID {
        locked = try await client.lockMark(proposalID: proposalID)
    } else {
        locked = try await client.lockMark()
    }
    guard locked.locked else { throw NativeJournalSetupError.markNotLocked }
    guard locked.mark == selected.mark else { throw NativeJournalSetupError.markChanged }
    return try await client.finalize()
}
