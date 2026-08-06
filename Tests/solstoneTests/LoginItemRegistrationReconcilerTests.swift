// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ServiceManagement
import Testing
@testable import solstone

@MainActor
@Suite("Login item registration reconciliation")
struct LoginItemRegistrationReconcilerTests {
    @Test func canonicalDifferingReceiptReregistersWatchdog() async {
        let harness = makeHarness(receipt: .found(receipt(path: "/Applications/old.app", build: 1)))

        await harness.reconciler.reconcileIfNeeded()

        #expect(harness.fake.events == [
            .watchdogStatusRead,
            .unregisterWatchdogAwaitingCompletion,
            .registerWatchdog,
            .watchdogStatusRead
        ])
        #expect(state(in: harness.stateStore).cause == .reconciled)
    }

    @Test(arguments: ["build", "url", "absent"])
    func developerBypassNeverRepairsAnyOtherwiseEligibleReceipt(_ kind: String) async {
        let running = runningReceipt()
        let read: LoginItemRegistrationReceiptRead
        switch kind {
        case "build":
            read = .found(receipt(path: running.bundlePath, build: running.build - 1))
        case "url":
            read = .found(receipt(path: "/Applications/other.app", build: running.build))
        default:
            read = .absent
        }
        let harness = makeHarness(
            receipt: read,
            placement: .allowed(.developerBypass)
        )

        await harness.reconciler.reconcileIfNeeded()

        #expect(!harness.fake.events.contains(.registerWatchdog))
        #expect(!harness.fake.events.contains(.unregisterWatchdogAwaitingCompletion))
        #expect(harness.receiptStore.read() == read)
        #expect(state(in: harness.stateStore).cause == .skippedDeveloperBypass)
    }

    @Test func requiresApprovalSkipsWithDistinctCause() async {
        let harness = makeHarness(receipt: .found(runningReceipt()), status: .requiresApproval)

        await harness.reconciler.reconcileIfNeeded()

        assertNoRepair(harness)
        #expect(state(in: harness.stateStore).cause == .skippedRequiresApproval)
    }

    @Test func notRegisteredSkipsWithDistinctCause() async {
        let harness = makeHarness(receipt: .found(runningReceipt()), status: .notRegistered)

        await harness.reconciler.reconcileIfNeeded()

        assertNoRepair(harness)
        #expect(state(in: harness.stateStore).cause == .skippedNotRegistered)
    }

    @Test func notFoundSkipsWithDistinctCause() async {
        let harness = makeHarness(receipt: .found(runningReceipt()), status: .notFound)

        await harness.reconciler.reconcileIfNeeded()

        assertNoRepair(harness)
        #expect(state(in: harness.stateStore).cause == .skippedNotFound)
    }

    @Test func reconciliationStartsOnlyAfterMigrationReturns() async {
        let fake = FakeLoginItemService(watchdogStatus: .enabled, mainAppStatus: .enabled)
        let appState = AppState.forLoginItemTest(loginService: fake, placementDecision: .allowed(.canonical))
        let harness = makeHarness(fake: fake, receipt: .found(receipt(path: "/Applications/old.app", build: 1)))

        appState.migrateLoginItemToWatchdogIfNeeded()
        #expect(fake.reconciliationUnregisterCountAtMainAppUnregister == [0])

        await harness.reconciler.reconcileIfNeeded()
        #expect(fake.events.contains(.unregisterWatchdogAwaitingCompletion))
    }

    @Test func oneReconcilerInstanceRunsOnlyOnce() async {
        let harness = makeHarness(receipt: .found(receipt(path: "/Applications/old.app", build: 1)))

        await harness.reconciler.reconcileIfNeeded()
        await harness.reconciler.reconcileIfNeeded()

        #expect(harness.fake.events.filter { $0 == .unregisterWatchdogAwaitingCompletion }.count == 1)
        #expect(harness.fake.events.filter { $0 == .registerWatchdog }.count == 1)
    }

    @Test func matchingReceiptDoesNotReregister() async {
        let current = runningReceipt()
        let harness = makeHarness(receipt: .found(current))

        await harness.reconciler.reconcileIfNeeded()

        assertNoRepair(harness)
        #expect(state(in: harness.stateStore).cause == .receiptMatches)
    }

    @Test func absentReceiptAdoptsEnabledRegistrationWithoutReregistering() async {
        let harness = makeHarness(receipt: .absent)

        await harness.reconciler.reconcileIfNeeded()

        assertNoRepair(harness)
        #expect(harness.receiptStore.read() == .found(runningReceipt()))
        #expect(state(in: harness.stateStore).cause == .adoptedExistingReceiptAbsent)
    }

    @Test func differingBuildAtSameBundlePathReregistersInPlaceSparkleUpdate() async {
        let current = runningReceipt()
        let harness = makeHarness(receipt: .found(receipt(path: current.bundlePath, build: current.build - 1)))

        await harness.reconciler.reconcileIfNeeded()

        #expect(harness.fake.events == [
            .watchdogStatusRead,
            .unregisterWatchdogAwaitingCompletion,
            .registerWatchdog,
            .watchdogStatusRead
        ])
        #expect(harness.receiptStore.read() == .found(current))
    }

    @Test func differingBundlePathReregistersWatchdog() async {
        let current = runningReceipt()
        let harness = makeHarness(receipt: .found(receipt(path: "/Applications/previous.app", build: current.build)))

        await harness.reconciler.reconcileIfNeeded()

        #expect(harness.fake.events.contains(.unregisterWatchdogAwaitingCompletion))
        #expect(harness.fake.events.contains(.registerWatchdog))
        #expect(harness.receiptStore.read() == .found(current))
    }

    @Test func registerWaitsForUnregisterCompletionAndRecordsAllOrderingEvents() async {
        let harness = makeHarness(receipt: .found(receipt(path: "/Applications/old.app", build: 1)))
        harness.fake.holdAwaitableUnregister = true

        let task = Task { @MainActor in
            await harness.reconciler.reconcileIfNeeded()
        }
        await harness.fake.waitForAwaitableUnregisterEntered()

        #expect(!harness.fake.events.contains(.registerWatchdog))
        harness.fake.releaseAwaitableUnregister()
        await task.value

        #expect(harness.fake.events == [
            .watchdogStatusRead,
            .unregisterWatchdogAwaitingCompletion,
            .unregisterCompletionReleased,
            .registerWatchdog,
            .watchdogStatusRead
        ])
    }

    @Test func unregisterFailureRecordsPresentRegistration() async {
        let oldReceipt = receipt(path: "/Applications/old.app", build: 1)
        let harness = makeHarness(receipt: .found(oldReceipt))
        harness.fake.unregisterWatchdogAwaitingCompletionError = ReconciliationTestError.requested

        await harness.reconciler.reconcileIfNeeded()

        #expect(state(in: harness.stateStore).cause == .unregisterFailed)
        #expect(state(in: harness.stateStore).registrationPresence == .present)
        #expect(!harness.fake.events.contains(.registerWatchdog))
    }

    @Test func productionTimeoutIsTenSecondsAndInjectedTimeoutIsDistinct() async {
        #expect(LoginItemRegistrationReconciler.unregisterTimeoutSeconds == 10)
        let harness = makeHarness(
            receipt: .found(receipt(path: "/Applications/old.app", build: 1)),
            timeout: 0.001
        )
        harness.fake.holdAwaitableUnregister = true

        await harness.reconciler.reconcileIfNeeded()

        #expect(state(in: harness.stateStore).cause == .unregisterTimedOut)
        #expect(state(in: harness.stateStore).registrationPresence == .unknown)
        #expect(!harness.fake.events.contains(.registerWatchdog))
    }

    @Test func registerFailureDoesNotWriteReceiptAndRecordsAbsentRegistration() async {
        let oldReceipt = receipt(path: "/Applications/old.app", build: 1)
        let harness = makeHarness(receipt: .found(oldReceipt))
        harness.fake.registerWatchdogError = ReconciliationTestError.requested

        await harness.reconciler.reconcileIfNeeded()

        #expect(state(in: harness.stateStore).cause == .registerFailed)
        #expect(state(in: harness.stateStore).registrationPresence == .absent)
        #expect(harness.receiptStore.read() == .found(oldReceipt))

        let existingRegistration = makeHarness(receipt: .found(runningReceipt()))
        await existingRegistration.reconciler.reconcileIfNeeded()
        #expect(
            state(in: harness.stateStore).registrationPresence
                != state(in: existingRegistration.stateStore).registrationPresence
        )
    }

    @Test func registerWithoutEnabledReadBackDoesNotWriteReceipt() async {
        let oldReceipt = receipt(path: "/Applications/old.app", build: 1)
        let harness = makeHarness(receipt: .found(oldReceipt))
        harness.fake.watchdogStatusAfterRegister = .requiresApproval

        await harness.reconciler.reconcileIfNeeded()

        #expect(state(in: harness.stateStore).cause == .registerDidNotBecomeEnabled)
        #expect(state(in: harness.stateStore).registrationPresence == .unknown)
        #expect(harness.receiptStore.read() == .found(oldReceipt))
    }

    @Test func terminalCausesArePairwiseDistinctWhenDriven() async {
        let causes = await [
            causeFor(placement: .allowed(.developerBypass)),
            causeFor(status: .requiresApproval),
            causeFor(status: .notRegistered),
            causeFor(status: .notFound),
            causeFor(unregisterError: ReconciliationTestError.requested),
            causeFor(timeout: 0.001, holdUnregister: true),
            causeFor(registerError: ReconciliationTestError.requested),
            causeFor(statusAfterRegister: .requiresApproval),
            causeFor(receipt: .absent),
            causeFor(receipt: .found(runningReceipt()))
        ]

        #expect(Set(causes).count == causes.count)
    }

    @Test func representativeStatesCarryAllIdentityFields() async {
        let oldReceipt = receipt(path: "/Applications/old.app", build: 1)
        let reconciled = makeHarness(receipt: .found(oldReceipt))
        await reconciled.reconciler.reconcileIfNeeded()

        let matched = makeHarness(receipt: .found(runningReceipt()))
        await matched.reconciler.reconcileIfNeeded()

        let unreadable = makeHarness(receipt: .failed)
        await unreadable.reconciler.reconcileIfNeeded()

        let unversionable = makeHarness(receipt: .found(oldReceipt), versionError: ReconciliationTestError.requested)
        await unversionable.reconciler.reconcileIfNeeded()

        let reconciledState = state(in: reconciled.stateStore)
        #expect(reconciledState.receiptBundlePath == runningBundleURL.path)
        #expect(reconciledState.receiptBuild == runningVersion.build)
        #expect(reconciledState.runningBundlePath == runningBundleURL.path)
        #expect(reconciledState.runningBuild == runningVersion.build)

        let matchedState = state(in: matched.stateStore)
        #expect(matchedState.receiptBundlePath == runningBundleURL.path)
        #expect(matchedState.receiptBuild == runningVersion.build)
        #expect(matchedState.runningBundlePath == runningBundleURL.path)
        #expect(matchedState.runningBuild == runningVersion.build)

        let unreadableState = state(in: unreadable.stateStore)
        #expect(unreadableState.receiptBundlePath == nil)
        #expect(unreadableState.receiptBuild == nil)
        #expect(unreadableState.runningBundlePath == runningBundleURL.path)
        #expect(unreadableState.runningBuild == runningVersion.build)

        let unversionableState = state(in: unversionable.stateStore)
        #expect(unversionableState.receiptBundlePath == nil)
        #expect(unversionableState.receiptBuild == nil)
        #expect(unversionableState.runningBundlePath == runningBundleURL.path)
        #expect(unversionableState.runningBuild == nil)
    }

    @Test func receiptAndStateStoresPersistAcrossFreshInstances() {
        let isolated = IsolatedUserDefaults()
        defer { isolated.clear() }
        let receipt = runningReceipt()
        let state = LoginItemRegistrationReconciliationState(
            cause: .reconciled,
            receiptBundlePath: receipt.bundlePath,
            receiptBuild: receipt.build,
            runningBundlePath: receipt.bundlePath,
            runningBuild: receipt.build,
            registrationPresence: .present
        )

        UserDefaultsLoginItemRegistrationReceiptStore(defaults: isolated.defaults).write(receipt)
        UserDefaultsLoginItemRegistrationReconciliationStateStore(defaults: isolated.defaults).write(state)

        #expect(UserDefaultsLoginItemRegistrationReceiptStore(defaults: isolated.defaults).read() == .found(receipt))
        #expect(UserDefaultsLoginItemRegistrationReconciliationStateStore(defaults: isolated.defaults).read() == .found(state))
    }

    @Test func receiptUnreadableAndRunningBundleUnversionableAndPlacementRepairAreDriven() async {
        let unreadable = makeHarness(receipt: .failed)
        await unreadable.reconciler.reconcileIfNeeded()

        let unversionable = makeHarness(versionError: ReconciliationTestError.requested)
        await unversionable.reconciler.reconcileIfNeeded()

        let repair = makeHarness(placement: .repair(placementContext()))
        await repair.reconciler.reconcileIfNeeded()

        #expect(state(in: unreadable.stateStore).cause == .skippedReceiptUnreadable)
        #expect(state(in: unversionable.stateStore).cause == .skippedRunningBundleUnversionable)
        #expect(state(in: repair.stateStore).cause == .skippedPlacementRepair)
    }

    private func causeFor(
        receipt: LoginItemRegistrationReceiptRead = .found(receipt(path: "/Applications/old.app", build: 1)),
        status: SMAppService.Status = .enabled,
        placement: AppPlacementDecision = .allowed(.canonical),
        unregisterError: Error? = nil,
        registerError: Error? = nil,
        statusAfterRegister: SMAppService.Status = .enabled,
        timeout: TimeInterval = LoginItemRegistrationReconciler.unregisterTimeoutSeconds,
        holdUnregister: Bool = false
    ) async -> LoginItemRegistrationReconciliationCause {
        let harness = makeHarness(receipt: receipt, status: status, placement: placement, timeout: timeout)
        harness.fake.unregisterWatchdogAwaitingCompletionError = unregisterError
        harness.fake.registerWatchdogError = registerError
        harness.fake.watchdogStatusAfterRegister = statusAfterRegister
        harness.fake.holdAwaitableUnregister = holdUnregister
        await harness.reconciler.reconcileIfNeeded()
        return state(in: harness.stateStore).cause
    }
}

@MainActor
private struct ReconciliationHarness {
    let reconciler: LoginItemRegistrationReconciler
    let fake: FakeLoginItemService
    let receiptStore: InMemoryLoginItemRegistrationReceiptStore
    let stateStore: InMemoryLoginItemRegistrationReconciliationStateStore
}

@MainActor
private func makeHarness(
    fake: FakeLoginItemService? = nil,
    receipt: LoginItemRegistrationReceiptRead = .found(receipt(path: "/Applications/old.app", build: 1)),
    status: SMAppService.Status = .enabled,
    placement: AppPlacementDecision = .allowed(.canonical),
    timeout: TimeInterval = LoginItemRegistrationReconciler.unregisterTimeoutSeconds,
    versionError: Error? = nil
) -> ReconciliationHarness {
    let fake = fake ?? FakeLoginItemService(watchdogStatus: status, mainAppStatus: .notRegistered)
    let receiptStore = InMemoryLoginItemRegistrationReceiptStore(readResult: receipt)
    let stateStore = InMemoryLoginItemRegistrationReconciliationStateStore()
    let reconciler = LoginItemRegistrationReconciler(
        loginService: fake,
        receiptStore: receiptStore,
        stateStore: stateStore,
        placementDecision: placement,
        runningBundleURL: runningBundleURL,
        versionReader: { _ in
            if let versionError {
                throw versionError
            }
            return runningVersion
        },
        unregisterTimeoutSeconds: timeout
    )
    return ReconciliationHarness(
        reconciler: reconciler,
        fake: fake,
        receiptStore: receiptStore,
        stateStore: stateStore
    )
}

@MainActor
private func assertNoRepair(_ harness: ReconciliationHarness) {
    #expect(!harness.fake.events.contains(.registerWatchdog))
    #expect(!harness.fake.events.contains(.unregisterWatchdogAwaitingCompletion))
}

@MainActor
private func state(in store: InMemoryLoginItemRegistrationReconciliationStateStore) -> LoginItemRegistrationReconciliationState {
    guard case .found(let state) = store.read() else {
        Issue.record("Expected persisted reconciliation state")
        fatalError("Expected persisted reconciliation state")
    }
    return state
}

private func receipt(path: String, build: Int) -> LoginItemRegistrationReceipt {
    LoginItemRegistrationReceipt(bundlePath: path, build: build)
}

private func runningReceipt() -> LoginItemRegistrationReceipt {
    receipt(path: runningBundleURL.path, build: runningVersion.build)
}

private let runningBundleURL = URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true)
private let runningVersion = SolstoneBundleVersion(shortVersion: "1.4.16", build: 70)

private enum ReconciliationTestError: Error {
    case requested
}

private func placementContext() -> AppPlacementContext {
    let running = URL(fileURLWithPath: "/tmp/solstone.app", isDirectory: true)
    let canonical = URL(fileURLWithPath: "/Applications/solstone.app", isDirectory: true)
    return AppPlacementContext(
        runningBundleURL: running,
        canonicalBundleURL: canonical,
        applicationsURL: canonical.deletingLastPathComponent(),
        runningStandardizedURL: running,
        runningResolvedURL: running,
        canonicalStandardizedURL: canonical,
        canonicalResolvedURL: canonical,
        pathLooksTranslocated: false
    )
}
