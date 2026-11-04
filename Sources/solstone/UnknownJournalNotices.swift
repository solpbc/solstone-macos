// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import Observation
import SPLTunnel

/// Where something other than the paired journal answered: one notice per place.
enum UnknownJournalSite: Hashable, Sendable {
    case address(String)
    case relay

    init(_ via: ConnectedVia) {
        switch via {
        case .lanDirect(let host, let port):
            self = .address(JournalAddressText.format(host: host, port: port))
        case .relay:
            self = .relay
        }
    }

    var axKey: String {
        switch self {
        case .address(let address): address
        case .relay: "relay"
        }
    }
}

/// What the "what answered" slot draws. A jid is only ever a claim.
enum UnknownJournalWhatAnswered: Equatable, Sendable {
    /// It presented no identity.
    case notPresented
    case deriving
    case claimed(JournalMark)
    /// It presented an identity and its mark couldn't be worked out here.
    case claimedUnavailable
}

/// What the "your journal" slot draws.
enum UnknownJournalYourMark: Equatable, Sendable {
    case deriving
    case mark(JournalMark)
    case unavailable
}

struct UnknownJournalNotice: Equatable, Identifiable, Sendable {
    let site: UnknownJournalSite
    var claimedJournalID: String?
    var whatAnswered: UnknownJournalWhatAnswered

    var id: UnknownJournalSite { site }
}

/// The notices the Settings service view shows. A notice is additive to the connection's own state
/// and never changes it. There is no dismiss state: a notice ends when a later dial to that place
/// reaches the paired journal, when the paired journal changes, or when the app restarts, and none
/// of this is written anywhere.
@MainActor
@Observable
final class UnknownJournalNotices {
    typealias DeriveClaimedMark = @Sendable (String) async -> JournalMark?
    typealias DerivePairedMark = @Sendable (StoredPairing) async -> JournalMark?

    private(set) var notices: [UnknownJournalNotice] = []
    private(set) var yourJournal: UnknownJournalYourMark = .deriving

    @ObservationIgnored
    private let deriveClaimedMark: DeriveClaimedMark
    @ObservationIgnored
    private let derivePairedMark: DerivePairedMark
    /// The journal these notices are "instead of".
    @ObservationIgnored
    private var pairedJournal: String?
    @ObservationIgnored
    private var yourJournalStarted = false

    init(
        deriveClaimedMark: @escaping DeriveClaimedMark = { await JournalMarkDerivation.mark(forJournalID: $0) },
        derivePairedMark: @escaping DerivePairedMark = { await JournalMarkDerivation.mark(forCAChainPEM: $0.caChainPEM) }
    ) {
        self.deriveClaimedMark = deriveClaimedMark
        self.derivePairedMark = derivePairedMark
    }

    /// One notice per place, shown as soon as this runs. The marks' cost is once per sighting: the
    /// claimed mark is worked out again only when the claimed jid at that place changes.
    func record(_ sighting: UnknownJournalSighting, pairing: StoredPairing?) {
        guard let pairing else { return }
        pairingChanged(to: pairing)
        startYourJournalMark(pairing)

        let site = UnknownJournalSite(sighting.dialled)
        let journalID = sighting.claimedJournalID
        if let existing = notices.firstIndex(where: { $0.site == site }) {
            guard notices[existing].claimedJournalID != journalID else { return }
            notices[existing].claimedJournalID = journalID
            notices[existing].whatAnswered = journalID == nil ? .notPresented : .deriving
        } else {
            notices.append(UnknownJournalNotice(
                site: site,
                claimedJournalID: journalID,
                whatAnswered: journalID == nil ? .notPresented : .deriving
            ))
        }
        guard let journalID else { return }
        Task { @MainActor [weak self, deriveClaimedMark] in
            let mark = await deriveClaimedMark(journalID)
            self?.finishClaimedMark(mark, site: site, journalID: journalID)
        }
    }

    /// The transport reached the paired journal at this place.
    func clear(at via: ConnectedVia) {
        let site = UnknownJournalSite(via)
        notices.removeAll { $0.site == site }
    }

    /// Notices say something isn't the paired journal, so they end when that journal changes. A new
    /// certificate for the same journal leaves them standing.
    func pairingChanged(to pairing: StoredPairing?) {
        let journal = pairing.map(journalMarkConfirmationIdentity(for:))
        guard journal != pairedJournal else { return }
        pairedJournal = journal
        notices = []
        yourJournal = .deriving
        yourJournalStarted = false
    }

    func clearAll() {
        pairedJournal = nil
        notices = []
        yourJournal = .deriving
        yourJournalStarted = false
    }

    private func startYourJournalMark(_ pairing: StoredPairing) {
        guard !yourJournalStarted else { return }
        yourJournalStarted = true
        let journal = journalMarkConfirmationIdentity(for: pairing)
        Task { @MainActor [weak self, derivePairedMark] in
            let mark = await derivePairedMark(pairing)
            guard let self, self.pairedJournal == journal else { return }
            self.yourJournal = mark.map(UnknownJournalYourMark.mark) ?? .unavailable
        }
    }

    private func finishClaimedMark(_ mark: JournalMark?, site: UnknownJournalSite, journalID: String) {
        guard let index = notices.firstIndex(where: { $0.site == site }),
              notices[index].claimedJournalID == journalID,
              notices[index].whatAnswered == .deriving else { return }
        notices[index].whatAnswered = mark.map(UnknownJournalWhatAnswered.claimed) ?? .claimedUnavailable
    }
}
