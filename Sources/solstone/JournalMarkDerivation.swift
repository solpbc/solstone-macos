// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import os
import SPLMark
import SPLTunnel

/// The mark this Mac derived, kept with the journal ID it belongs to so it's computed once.
struct DerivedJournalMarkStore: Sendable {
    private struct Derived: Codable {
        let journalID: String
        let mark: JournalMark
    }

    private static let key = "journalMarkDerived"
    /// A name, because `UserDefaults` isn't `Sendable`. `nil` means the standard defaults.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    func mark(forJournalID journalID: String) -> JournalMark? {
        guard let data = defaults.data(forKey: Self.key),
              let derived = try? JSONDecoder().decode(Derived.self, from: data),
              derived.journalID == journalID else { return nil }
        return JournalMark.validate(derived.mark)
    }

    func save(_ mark: JournalMark, journalID: String) {
        guard let data = try? JSONEncoder().encode(Derived(journalID: journalID, mark: mark)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The mark the owner is asked about and sees, computed here from the CA a pairing pinned. A pair
/// link pins whichever key it names, so anything the peer serves is a claim. This needs no network.
enum JournalMarkDerivation {
    private static let log = Logger(subsystem: "app.solstone.observer", category: "general")

    /// The mark for a stored CA chain: the one kept for that CA, or derived off the main thread and
    /// kept. `nil` when it can't be computed, which every surface draws as unavailable.
    static func mark(
        forCAChainPEM caChainPEM: String,
        store: DerivedJournalMarkStore = DerivedJournalMarkStore(),
        derive: @Sendable (String) async throws -> MarkRenderSpec = { try await deriveMark(fromJournalID: $0) }
    ) async -> JournalMark? {
        do {
            let journalID = try CertChain.journalID(ofCAChainPEM: caChainPEM)
            if let kept = store.mark(forJournalID: journalID) {
                return kept
            }
            guard let mark = JournalMark.validate(JournalMark(try await derive(journalID))) else {
                log.error("derived journal mark was invalid")
                return nil
            }
            store.save(mark, journalID: journalID)
            return mark
        } catch {
            log.error("journal mark derivation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The mark for a journal ID something else claims. Keeps nothing.
    static func mark(
        forJournalID journalID: String,
        derive: @Sendable (String) async throws -> MarkRenderSpec = { try await deriveMark(fromJournalID: $0) }
    ) async -> JournalMark? {
        do {
            return JournalMark.validate(JournalMark(try await derive(journalID)))
        } catch {
            log.error("journal mark derivation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The mark for a CA this Mac hasn't committed to. Keeps nothing, so a pairing the owner
    /// declines leaves no trace and the stored pairing's kept mark stays in place.
    static func markKeepingNothing(
        forCAChainPEM caChainPEM: String,
        derive: @Sendable (String) async throws -> MarkRenderSpec = { try await deriveMark(fromJournalID: $0) }
    ) async -> JournalMark? {
        do {
            let journalID = try CertChain.journalID(ofCAChainPEM: caChainPEM)
            guard let mark = JournalMark.validate(JournalMark(try await derive(journalID))) else {
                log.error("derived journal mark was invalid")
                return nil
            }
            return mark
        } catch {
            log.error("journal mark derivation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension JournalMark {
    init(_ spec: MarkRenderSpec) {
        func icon(_ spec: MarkIconSpec) -> Icon {
            Icon(
                name: spec.name,
                color: MarkColor(hex: spec.color.hex, name: spec.color.name),
                rot: spec.rot,
                svg: spec.svg
            )
        }
        self.init(icon1: icon(spec.icon1), icon2: icon(spec.icon2), words: spec.words)
    }
}
