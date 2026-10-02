// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
import UpdateKit
@testable import solstone

@Suite("Private-window Accessibility monitor")
@MainActor
struct PrivateWindowAccessibilityMonitorTests {
    @Test func disabledDoesNotScheduleOrRead() async {
        let polling = ManualAccessibilityPolling()
        let reader = AccessibilitySampleReader(false)
        let monitor = PrivateWindowAccessibilityMonitor(readWorks: { await reader.read() }, scheduler: polling.scheduler)
        monitor.setEnabled(false)
        #expect(polling.passes.isEmpty)
        #expect(await reader.count == 0)
        #expect(monitor.state == .off)
        #expect(!monitor.needsAttention)
    }

    @Test func savedOnStartsUnknownAndFailedReadRaisesAttention() async {
        let polling = ManualAccessibilityPolling()
        let reader = AccessibilitySampleReader(false)
        let monitor = PrivateWindowAccessibilityMonitor(readWorks: { await reader.read() }, scheduler: polling.scheduler)
        monitor.setEnabled(true)
        #expect(monitor.state == .checking)
        #expect(!monitor.needsAttention)
        #expect(!monitor.askedThisSession)
        await polling.passes[0]()
        #expect(monitor.state == .notWorking)
        #expect(monitor.needsAttention)
        await reader.set(true)
        await polling.passes[0]()
        #expect(monitor.state == .working)
        #expect(!monitor.needsAttention)
        monitor.stop()
    }

    @Test func firstAskKeepsWaitingButDoesNotConcealFailedReads() async {
        let polling = ManualAccessibilityPolling()
        let reader = AccessibilitySampleReader(false)
        let monitor = PrivateWindowAccessibilityMonitor(readWorks: { await reader.read() }, scheduler: polling.scheduler)
        monitor.prepareForOwnerEnable()
        monitor.setEnabled(true)
        #expect(monitor.state == .waiting)
        #expect(!monitor.needsAttention)
        await polling.passes[0]()
        await polling.passes[0]()
        #expect(monitor.state == .waiting)
        #expect(monitor.needsAttention)
        #expect(!monitor.hasWorkedSinceAsking)
        await reader.set(true)
        await polling.passes[0]()
        #expect(monitor.state == .working)
        #expect(monitor.hasWorkedSinceAsking)
        await reader.set(false)
        await polling.passes[0]()
        #expect(monitor.state == .notWorking)
        #expect(monitor.needsAttention)
        monitor.setEnabled(false)
        #expect(monitor.state == .off)
        #expect(!monitor.needsAttention)
        #expect(polling.cancelled == [0])
    }

    @Test(arguments: [false, true])
    func obsoleteReadDrainsThenActiveGenerationPublishes(obsoleteWorks: Bool) async {
        let polling = ManualAccessibilityPolling()
        let reader = GatedAccessibilityReader()
        let monitor = PrivateWindowAccessibilityMonitor(readWorks: { await reader.read() }, scheduler: polling.scheduler)
        monitor.setEnabled(true)
        let first = Task { await polling.passes[0]() }
        await reader.waitForCount(1)
        monitor.setEnabled(false)
        await polling.passes[0]() // A delivery queued before cancellation cannot read while off.
        monitor.prepareForOwnerEnable()
        monitor.setEnabled(true)
        await polling.passes[0]() // The old arm cannot masquerade as the new arm.
        await polling.passes[1]() // The new arm cannot overlap the draining read.
        #expect(await reader.count == 1)
        await reader.finish(obsoleteWorks)
        await reader.waitForCount(2)
        #expect(monitor.state == .waiting)
        #expect(monitor.lastReadWorks == nil)
        #expect(!monitor.hasWorkedSinceAsking)
        #expect(await reader.peak == 1)
        await reader.finish(!obsoleteWorks)
        await first.value
        #expect(monitor.lastReadWorks == !obsoleteWorks)
        #expect(monitor.hasWorkedSinceAsking == !obsoleteWorks)
        #expect(monitor.needsAttention == obsoleteWorks)
        monitor.stop()
    }

    @Test func stopDiscardsInflightResultAndQueuedCallbacks() async {
        let polling = ManualAccessibilityPolling()
        let reader = GatedAccessibilityReader()
        let monitor = PrivateWindowAccessibilityMonitor(readWorks: { await reader.read() }, scheduler: polling.scheduler)
        monitor.prepareForOwnerEnable()
        monitor.setEnabled(true)
        let pass = Task { await polling.passes[0]() }
        await reader.waitForCount(1)
        monitor.stop()
        await polling.passes[0]()
        monitor.setEnabled(true)
        #expect(polling.passes.count == 1)
        await reader.finish(true)
        await pass.value
        #expect(monitor.lastReadWorks == nil)
        #expect(!monitor.hasWorkedSinceAsking)
        #expect(monitor.state == .off)
        #expect(await reader.count == 1)
    }

    @Test func parentOffOnRetainsAskProgressWithoutAskingAgain() async {
        let polling = ManualAccessibilityPolling()
        let reader = AccessibilitySampleReader(true)
        let monitor = PrivateWindowAccessibilityMonitor(readWorks: { await reader.read() }, scheduler: polling.scheduler)
        monitor.prepareForOwnerEnable()
        monitor.setEnabled(true)
        await polling.passes[0]()
        monitor.setEnabled(false)
        #expect(monitor.state == .off)
        #expect(!monitor.needsAttention)
        #expect(monitor.askedThisSession)
        #expect(monitor.hasWorkedSinceAsking)
        await reader.set(false)
        monitor.setEnabled(true)
        #expect(monitor.state == .checking)
        await polling.passes[1]()
        #expect(monitor.state == .notWorking)
        #expect(monitor.needsAttention)
        #expect(monitor.askedThisSession)
        #expect(monitor.hasWorkedSinceAsking)
        monitor.stop()
    }

    @Test func schedulerDoesNotRetainMonitorAndDeinitCancels() {
        let polling = ManualAccessibilityPolling()
        var monitor: PrivateWindowAccessibilityMonitor? = .init(readWorks: { false }, scheduler: polling.scheduler)
        weak var weakMonitor = monitor
        monitor?.setEnabled(true)
        monitor = nil
        #expect(weakMonitor == nil)
        #expect(polling.cancelled == [0])
    }

    @Test func snapshotNeverStartsMonitorEvenWithSavedOptionOn() {
        var config = AppConfig()
        config.excludePrivateBrowsingAccessibility = true
        let state = AppState.forSnapshot(config: config)
        #expect(!state.privateWindowAccessibilityMonitor.isEnabled)
        #expect(state.privateWindowAccessibilityMonitor.lastReadWorks == nil)
        config.excludePrivateBrowsing = false
        state.updateConfig(config)
        config.excludePrivateBrowsing = true
        state.updateConfig(config)
        #expect(!state.privateWindowAccessibilityMonitor.isEnabled)
    }

    @Test func sharedFaultSurvivesPauseAndStopsWhenEitherPreferenceIsOff() async {
        let polling = ManualAccessibilityPolling()
        let monitor = PrivateWindowAccessibilityMonitor(readWorks: { false }, scheduler: polling.scheduler)
        var config = AppConfig()
        config.excludePrivateBrowsingAccessibility = true
        let state = AppState.forSnapshot(config: config)
        state.privateWindowAccessibilityMonitor = monitor
        monitor.setEnabled(true)
        await polling.passes[0]()
        for paused in [false, true] {
            state.isPaused = paused
            #expect(state.menubarPresentation(durableUpdateStatus: .idle).attention == .privateWindows)
        }
        config.excludePrivateBrowsing = false
        state.updateConfig(config)
        #expect(state.menubarPresentation(durableUpdateStatus: .idle).attention != .privateWindows)
        config.excludePrivateBrowsing = true
        config.excludePrivateBrowsingAccessibility = false
        state.updateConfig(config)
        #expect(state.menubarPresentation(durableUpdateStatus: .idle).attention != .privateWindows)
        monitor.stop()
    }

    @Test func attentionPriorityIncludesMaskedReasonRecovery() {
        for permissions in [false, true] {
            for privateFault in [false, true] {
                for journal in [false, true] {
                    let presentation = classifyMenubarPresentation(
                        observation: .paused,
                        permissionsNeedAttention: permissions,
                        journalNeedsAttention: journal,
                        durableUpdateStatus: .failed,
                        privateWindowsNeedAttention: privateFault
                    )
                    let expected: AttentionReason = permissions ? .permissions
                        : privateFault ? .privateWindows : journal ? .journal : .updateCheckFailed
                    #expect(presentation.attention == expected)
                    #expect(presentation.icon == MenubarStatusRowState.paused.iconState)
                    #expect(presentation.overlayState == .attention)
                }
            }
        }
    }

    @Test func recoveryHasFreshIdentityAndDoesNotAlterHealthOrAskProgress() {
        let state = AppState.forSnapshot()
        state.requestPrivateWindowSettingsRecovery()
        let first = state.pendingPrivateWindowSettingsTarget
        #expect(state.pendingSettingsTab == "privacy")
        #expect(first != nil)
        state.requestPrivateWindowSettingsRecovery()
        #expect(state.pendingPrivateWindowSettingsTarget != first)
        #expect(!state.privateWindowAccessibilityMonitor.askedThisSession)
        #expect(!state.privateWindowAccessibilityMonitor.isEnabled)
    }

    @Test func announcementsHaveVisiblePositiveAndHiddenBaselinePaths() {
        var policy = PrivateWindowAccessibilityAnnouncementPolicy()
        #expect(policy.observe(.working, isVisible: true) == nil)
        #expect(policy.observe(.notWorking, isVisible: true) != nil)
        #expect(policy.observe(.notWorking, isVisible: true) == nil)
        #expect(policy.observe(.working, isVisible: false) == nil)
        policy.reset(to: .working) // Reopen/unhide/deminiaturize does not replay a change.
        #expect(policy.observe(.working, isVisible: true) == nil)
        #expect(policy.observe(.notWorking, isVisible: true) != nil)
        #expect(policy.observe(.working, isVisible: true) != nil)
    }
}

@MainActor
private final class ManualAccessibilityPolling {
    var passes: [PermissionPollScheduler.Pass] = []
    var cancelled: [Int] = []
    var scheduler: PermissionPollScheduler {
        PermissionPollScheduler { [self] pass in
            let index = passes.count
            passes.append(pass)
            return { [weak self] in self?.cancelled.append(index) }
        }
    }
}

private actor AccessibilitySampleReader {
    var works: Bool
    var count = 0
    init(_ works: Bool) { self.works = works }
    func set(_ works: Bool) { self.works = works }
    func read() -> Bool { count += 1; return works }
}

private actor GatedAccessibilityReader {
    var count = 0
    var peak = 0
    private var active = 0
    private var replies: [CheckedContinuation<Bool, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func read() async -> Bool {
        active += 1
        peak = max(peak, active)
        count += 1
        let works = await withCheckedContinuation { continuation in
            replies.append(continuation)
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for waiter in ready { waiter.1.resume() }
        }
        active -= 1
        return works
    }

    func waitForCount(_ target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func finish(_ works: Bool) { replies.removeFirst().resume(returning: works) }
}
