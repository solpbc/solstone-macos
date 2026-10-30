// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
import Foundation
import Testing
import UpdateKit
import os
@testable import solstone

@Suite("Safari extension health")
@MainActor
struct SafariExtensionHealthTests {
    @MainActor final class Store { var enabled = false }

    @MainActor final class Schedule {
        var pass: PermissionPollScheduler.Pass?
        var cancelled = false
        var scheduler: PermissionPollScheduler {
            PermissionPollScheduler { [self] pass in
                self.pass = pass
                return { self.cancelled = true }
            }
        }
    }

    final class Read: @unchecked Sendable {
        private let lock = NSLock()
        private var next: SafariExtensionAXState = .unknown
        private var pending: (@Sendable (SafariExtensionAXState) -> Void)?
        let started = AsyncStream<Void>.makeStream()
        var hold = false
        private(set) var count = 0

        var control: SafariExtensionControl {
            SafariExtensionControl(readState: { [self] done in
                let result: SafariExtensionAXState? = lock.withLock {
                    count += 1
                    if hold { pending = done; return nil }
                    return next
                }
                started.continuation.yield(())
                if let result { done(result) }
            }, showSettings: { $0(true) })
        }

        func set(_ value: SafariExtensionAXState) { lock.withLock { next = value } }
        func finish(_ value: SafariExtensionAXState) {
            let done = lock.withLock { let done = pending; pending = nil; return done }
            done?(value)
        }
    }

    func model(_ read: Read, _ store: Store, _ schedule: Schedule) -> SafariExtensionHealth {
        SafariExtensionHealth(control: read.control, scheduler: schedule.scheduler, loadExpected: { store.enabled }, saveExpected: { store.enabled = $0 })
    }

    @Test func enabledChoiceSurvivesFailureAndRelaunchButOffClearsIt() async {
        let read = Read(), store = Store(), schedule = Schedule()
        var health = model(read, store, schedule)
        health.start()
        await schedule.pass?()
        #expect(!health.needsAttention)
        read.set(.on)
        await schedule.pass?()
        #expect(store.enabled)
        read.set(.unknown)
        await schedule.pass?()
        #expect(health.needsAttention)
        health.stop()
        #expect(schedule.cancelled)

        health = model(read, store, schedule)
        health.start()
        #expect(!health.needsAttention)
        await schedule.pass?()
        #expect(health.needsAttention)
        read.set(.on)
        await schedule.pass?()
        #expect(!health.needsAttention)
        read.set(.off)
        await schedule.pass?()
        #expect(!store.enabled)
        health.stop()

        health = model(read, store, schedule)
        health.start()
        read.set(.unknown)
        await schedule.pass?()
        #expect(!health.needsAttention)
        health.stop()
    }

    @Test func pendingReadsCoalesceAndStoppedResultsCannotPublish() async {
        let read = Read(), store = Store(), schedule = Schedule()
        store.enabled = true
        read.hold = true
        let health = model(read, store, schedule)
        health.start()
        let pending = Task { await health.refresh() }
        var iterator = read.started.stream.makeAsyncIterator()
        await iterator.next()
        await health.refresh()
        #expect(read.count == 1)
        health.stop()
        read.finish(.off)
        await pending.value
        await schedule.pass?()
        #expect(read.count == 1)
        #expect(store.enabled)
        #expect(!health.hasChecked)
    }

    @Test func appPresentationShowsLossWithoutOpeningSettingsAndRespectsBrowserOff() async throws {
        let read = Read(), store = Store(), schedule = Schedule()
        let harness = DiagnosticEvidenceHarness()
        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: false,
            loadConfiguration: { _ in AppConfig(isBrowserIntakeEnabled: true) },
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _, config, _ in
                let state = AppState.forSnapshot(config: config, recorder: recorder)
                state.safariExtensionHealth = model(read, store, schedule)
                return state
            },
            registerSharedState: { _ in },
            makeUpdateController: { _ in
                UpdateController(log: Logger(subsystem: "tests", category: "safari"), errorDomain: "tests.safari",
                    defaults: UserDefaults(suiteName: "SafariHealth.\(UUID().uuidString)")!) { _, _ in nil }
            },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        let state = try #require(startup)
        #expect(schedule.pass != nil)
        read.set(.on)
        await schedule.pass?()
        read.set(.unknown)
        await schedule.pass?()
        let presentation = state.menubarPresentation(durableUpdateStatus: .idle)
        #expect(presentation.attention == .safariExtension)
        #expect(presentation.showsAttentionBadge)
        state.configSaver = { _ in }
        state.setBrowserIntakeEnabled(false)
        #expect(!state.safariExtensionNeedsAttention)
        state.safariExtensionHealth.stop()
    }
}
#endif
