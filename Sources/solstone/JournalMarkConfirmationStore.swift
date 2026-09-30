// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Remembers the one journal whose mark the owner confirmed.
///
/// A pairing is complete only once the owner confirms the journal's mark, or chooses to
/// continue when the check could not finish. Until then nothing this Mac captured is sent
/// to that journal. The answer is kept here, outside the credential, so that quitting or
/// closing settings while the question is open never counts as a yes.
internal protocol JournalMarkConfirmationStoring: AnyObject, Sendable {
    /// The confirmed journal, or nil when none is.
    var confirmedJournal: String? { get }
    /// Whether this Mac has decided what a pairing held from an earlier version counts as.
    var settled: Bool { get }
    func confirm(_ journal: String)
    func clear()
}

internal final class UserDefaultsJournalMarkConfirmationStore: JournalMarkConfirmationStoring, @unchecked Sendable {
    static let confirmedJournalKey = "journalMarkConfirmedJournal"
    static let settledKey = "journalMarkConfirmationSettled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var confirmedJournal: String? {
        defaults.string(forKey: Self.confirmedJournalKey)
    }

    var settled: Bool {
        defaults.bool(forKey: Self.settledKey)
    }

    func confirm(_ journal: String) {
        defaults.set(journal, forKey: Self.confirmedJournalKey)
        defaults.set(true, forKey: Self.settledKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.confirmedJournalKey)
        defaults.set(true, forKey: Self.settledKey)
    }
}

internal final class InMemoryJournalMarkConfirmationStore: JournalMarkConfirmationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var journal: String?
    private var isSettled: Bool

    init(confirmedJournal: String? = nil, settled: Bool = true) {
        self.journal = confirmedJournal
        self.isSettled = settled
    }

    var confirmedJournal: String? {
        lock.withLock { journal }
    }

    var settled: Bool {
        lock.withLock { isSettled }
    }

    func confirm(_ journal: String) {
        lock.withLock {
            self.journal = journal
            isSettled = true
        }
    }

    func clear() {
        lock.withLock {
            journal = nil
            isSettled = true
        }
    }
}

extension JournalMarkConfirmationStoring {
    /// Whether the owner has confirmed `journal`'s mark.
    ///
    /// A pairing this Mac already held before it kept these answers was made and used under
    /// the earlier rule, so the first read settles it as confirmed rather than taking sync
    /// away from an owner who only installed an update. Every pairing made afterwards clears
    /// the answer first, so it can never be settled this way.
    func isConfirmed(_ journal: String) -> Bool {
        if !settled {
            confirm(journal)
        }
        return confirmedJournal == journal
    }
}
