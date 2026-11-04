// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

/// Scripted traces against the connection presenter. Each step is applied at its
/// own time, and the presenter is also evaluated at every deadline it asks for,
/// the way the owner's timer drives it.
@Suite("Journal connection presenter")
struct JournalConnectionPresenterTests {
    private typealias P = JournalConnectionPresenter

    @Test func I1_aHardDropShowsWithinOneEvaluation() {
        var trace = Trace()
        trace.at(0, .up(heardAt: 0))
        #expect(trace.shown == .connected)
        trace.at(4, .down)
        #expect(trace.shown == .connecting)

        // Also during the hold after a wake: a closed link is never held.
        trace.at(5, .up(heardAt: 5))
        trace.at(6.5, .up(heardAt: 6.5))
        #expect(trace.shown == .connected)
        trace.resume(at: 7)
        trace.at(7.1, .down)
        #expect(trace.shown == .connecting)

        // And when the Mac stops trying (a revoked pairing, no route left).
        var stopped = Trace()
        stopped.at(0, .up(heardAt: 0))
        stopped.at(1, Evidence(trying: false, linkUp: false, heardAt: nil))
        #expect(stopped.shown == .offline)
    }

    @Test func I2_connectedIsNeverShownWithoutSomethingHeardWithinTheLease() {
        var trace = Trace()
        trace.at(0, .up(heardAt: nil))
        // Up but never heard: the handshake has not been credited.
        trace.run(until: 40)
        #expect(!trace.history.contains { $0.shown == .connected })

        var heard = Trace()
        heard.at(0, .up(heardAt: 0))
        heard.at(3, .up(heardAt: 2))
        heard.at(6, .up(heardAt: 5))
        heard.run(until: 30)
        for sample in heard.history where sample.shown == .connected {
            let lastHeard = heard.lastHeard(atOrBefore: sample.time)
            #expect(lastHeard != nil)
            #expect(sample.time - (lastHeard ?? -.infinity) < P.lease)
        }
        // The lease ran out at 15 with nothing new, and the drop showed then.
        #expect(heard.shown(at: 14.9) == .connected)
        #expect(heard.shown(at: 15) == .connecting)
    }

    @Test func I3_aDropFromConnectedLastsAtLeastOneSecond() {
        var trace = Trace()
        trace.at(0, .up(heardAt: 0))
        trace.at(2, .down)
        trace.at(2.2, .up(heardAt: 2.2))
        #expect(trace.shown == .connecting)
        trace.run(until: 5)
        #expect(trace.shown(at: 2.99) == .connecting)
        #expect(trace.shown(at: 3) == .connected)

        // A lease that lapses and is renewed at once is held the same way.
        var lapse = Trace()
        lapse.at(0, .up(heardAt: 0))
        lapse.run(until: 10.3)
        #expect(lapse.shown == .connecting)
        lapse.at(10.3, .up(heardAt: 10.3))
        #expect(lapse.shown == .connecting)
        lapse.run(until: 12)
        #expect(lapse.shown(at: 11) == .connected)

        for scripted in [trace, lapse] {
            for stretch in scripted.dropStretches() {
                #expect(stretch.duration >= P.minimumDropDwell)
            }
        }
    }

    @Test func I4_aSingleFailedProbeInsideTheLeaseChangesNothing() {
        // Heard at 0; the next check starts after 3 s of silence and fails at 9.
        // Nothing new is heard, but nothing is withdrawn until the lease ends,
        // and a later answer at 9.5 keeps the connection up without a blink.
        var trace = Trace()
        trace.at(0, .up(heardAt: 0))
        trace.at(3, .up(heardAt: 0))
        trace.at(9, .up(heardAt: 0))
        trace.at(9.5, .up(heardAt: 9.5))
        trace.run(until: 19)
        #expect(trace.history.filter { $0.time < 19.5 }.allSatisfy { $0.shown == .connected })
    }

    @Test func I5_theQueueDrainingKeepsSyncingForOneAndAHalfSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var syncing = SyncingPresenter()
        syncing.update(.syncing(checked: 0, total: 2), at: start)
        syncing.update(.uploading(segment: "a"), at: start.addingTimeInterval(1))
        syncing.update(.synced, at: start.addingTimeInterval(2))
        #expect(syncing.shown == .uploading(segment: "a"))
        #expect(syncing.nextChange(after: start.addingTimeInterval(2)) == start.addingTimeInterval(3.5))
        syncing.update(.synced, at: start.addingTimeInterval(3.4))
        #expect(syncing.shown == .uploading(segment: "a"))
        syncing.update(.synced, at: start.addingTimeInterval(3.5))
        #expect(syncing.shown == .synced)
        #expect(syncing.nextChange(after: start.addingTimeInterval(3.5)) == nil)

        // The next item inside the linger carries straight on, with no caught-up in between.
        var consecutive = SyncingPresenter()
        consecutive.update(.uploading(segment: "a"), at: start)
        consecutive.update(.synced, at: start.addingTimeInterval(1))
        consecutive.update(.uploading(segment: "b"), at: start.addingTimeInterval(1.4))
        #expect(consecutive.shown == .uploading(segment: "b"))

        // A failure is shown at once; only caught up waits.
        var failed = SyncingPresenter()
        failed.update(.uploading(segment: "a"), at: start)
        failed.update(.offline("offline"), at: start.addingTimeInterval(0.1))
        #expect(failed.shown == .offline("offline"))
    }

    @Test func I6_aFreshLaunchNeverShowsConnectedBeforeEvidence() {
        var trace = Trace()
        #expect(trace.shown == .connecting)
        trace.at(0, .notUp)
        trace.at(2, .attempting)
        #expect(trace.shown == .connecting)
        trace.at(2.5, .up(heardAt: 2.5))
        #expect(trace.history.first { $0.shown == .connected }?.time == 2.5)
    }

    @Test func backoffBetweenAttemptsStaysConnectingThenGoesOfflineOnce() {
        var trace = Trace()
        trace.at(0, .up(heardAt: 0))
        trace.at(1, .down)
        // The tunnel retries with gaps between attempts; nothing alternates.
        for t in stride(from: 2.0, through: 60, by: 3) {
            trace.at(t, .attempting)
            trace.at(t + 1.5, .notUp)
        }
        let changes = trace.changes()
        #expect(changes.map(\.shown) == [.connected, .connecting, .offline])
        #expect(changes.last?.time == 31)
    }

    @Test func noNetworkAndNoLinkIsOfflineAtOnceAndTheNetworkReturningStartsAgain() {
        var trace = Trace()
        trace.at(0, .up(heardAt: 0))
        trace.at(1, Evidence(linkUp: true, heardAt: 0, network: false))
        // The path reading alone says nothing while the journal is being heard.
        #expect(trace.shown == .connected)
        trace.at(2, Evidence(linkUp: false, heardAt: nil, network: false))
        #expect(trace.shown == .offline)
        trace.at(50, Evidence(linkUp: false, heardAt: nil, network: true))
        #expect(trace.shown == .connecting)
        trace.run(until: 79.9)
        #expect(trace.shown == .connecting)
        trace.run(until: 80)
        #expect(trace.shown == .offline)
    }

    @Test func wakeHoldsTheLastStateBrieflyThenShowsTheTruth() {
        // Heard right after the wake: no blink.
        var quick = Trace()
        quick.at(0, .up(heardAt: 0))
        quick.suspend(until: 3_600)
        quick.resume(at: 3_600)
        quick.at(3_600, .up(heardAt: 0))
        #expect(quick.shown == .connected)
        quick.at(3_600.2, .up(heardAt: 3_600.2))
        quick.run(until: 3_605)
        #expect(quick.changes().map(\.shown) == [.connected])

        // Nothing heard: connected is held for the grace, then withdrawn.
        var slow = Trace()
        slow.at(0, .up(heardAt: 0))
        slow.suspend(until: 3_600)
        slow.resume(at: 3_600)
        slow.at(3_600, .up(heardAt: 0))
        slow.run(until: 3_602)
        #expect(slow.shown(at: 3_600.49) == .connected)
        #expect(slow.shown(at: 3_600.5) == .connecting)

        // An offline Mac waking starts a new attempt instead of staying offline.
        var asleep = Trace()
        asleep.at(0, .notUp)
        asleep.run(until: 40)
        #expect(asleep.shown == .offline)
        asleep.resume(at: 100)
        asleep.at(100, .notUp)
        asleep.run(until: 101)
        #expect(asleep.shown == .connecting)
    }

    @Test func aSuspendedProcessIsTreatedAsAWakeEvenBeforeTheWakeNotice() {
        var trace = Trace()
        trace.at(0, .up(heardAt: 0))
        trace.at(2, .up(heardAt: 2))
        // Asleep for an hour: no timer fires, and the wake notice has not arrived.
        trace.suspend(until: 3_600)
        trace.at(3_600, .up(heardAt: 2))
        #expect(trace.shown == .connected)
        trace.at(3_600.1, .up(heardAt: 3_600.1))
        trace.run(until: 3_610)
        #expect(trace.changes().map(\.shown) == [.connected])
    }
}

// MARK: - Trace harness

private struct Evidence {
    var trying = true
    var linkUp: Bool
    var heardAt: TimeInterval?
    var network = true

    static func up(heardAt: TimeInterval?) -> Evidence { Evidence(linkUp: true, heardAt: heardAt) }
    static let down = Evidence(linkUp: false, heardAt: nil)
    static let notUp = Evidence(linkUp: false, heardAt: nil)
    static let attempting = Evidence(linkUp: false, heardAt: nil)
}

private struct Sample {
    let time: TimeInterval
    let shown: PresentedJournalConnection
}

private struct Trace {
    private static let epoch = Date(timeIntervalSince1970: 1_000_000)
    private var presenter = JournalConnectionPresenter(now: Trace.epoch)
    private var current: Evidence?
    private var heardTimes: [TimeInterval] = []
    private(set) var history: [Sample] = []
    private var clock: TimeInterval = 0

    var shown: PresentedJournalConnection { presenter.shown }

    /// Applies evidence at `time`, after first running every deadline before it.
    mutating func at(_ time: TimeInterval, _ evidence: Evidence) {
        run(until: time, inclusive: false)
        current = evidence
        if let heard = evidence.heardAt { heardTimes.append(heard) }
        evaluate(at: time)
    }

    /// The process does not run until `time`: nothing is evaluated in between.
    mutating func suspend(until time: TimeInterval) {
        clock = time
    }

    mutating func resume(at time: TimeInterval) {
        run(until: time, inclusive: false)
        presenter.resume(at: date(time))
        clock = time
    }

    /// Runs the deadlines the presenter asks for, as the owner's timer would.
    mutating func run(until end: TimeInterval, inclusive: Bool = true) {
        while current != nil, let next = presenter.nextChange(after: date(clock)) {
            let t = next.timeIntervalSince(Self.epoch)
            guard inclusive ? t <= end : t < end else { break }
            evaluate(at: t)
        }
    }

    func shown(at time: TimeInterval) -> PresentedJournalConnection? {
        history.last { $0.time <= time }?.shown
    }

    func lastHeard(atOrBefore time: TimeInterval) -> TimeInterval? {
        heardTimes.filter { $0 <= time }.max()
    }

    /// The shown state each time it changed.
    func changes() -> [Sample] {
        var out: [Sample] = []
        for sample in history where out.last?.shown != sample.shown {
            out.append(sample)
        }
        return out
    }

    /// Every not-connected stretch that began by dropping from connected and ended
    /// by connected returning.
    func dropStretches() -> [(start: TimeInterval, duration: TimeInterval)] {
        let changes = changes()
        var out: [(TimeInterval, TimeInterval)] = []
        var dropStart: TimeInterval?
        var previous: PresentedJournalConnection?
        for change in changes {
            if previous == .connected, change.shown != .connected { dropStart = change.time }
            if change.shown == .connected, let start = dropStart {
                out.append((start, change.time - start))
                dropStart = nil
            }
            previous = change.shown
        }
        return out
    }

    private mutating func evaluate(at time: TimeInterval) {
        guard let current else { return }
        clock = time
        let evidence = JournalConnectionEvidence(
            trying: current.trying,
            linkUp: current.linkUp,
            lastHeardAt: current.heardAt.map(date),
            networkAvailable: current.network
        )
        history.append(Sample(time: time, shown: presenter.update(evidence, at: date(time))))
    }

    private func date(_ time: TimeInterval) -> Date {
        Self.epoch.addingTimeInterval(time)
    }
}
