// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ServiceManagement
import Testing
@testable import solstone

@MainActor
@Suite("Login item migration")
struct LoginItemMigrationTests {
    @Test func toggleUsesWatchdogStatusAndOperations() {
        let fake = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.setLoginItemEnabled(true)

        #expect(fake.calls == [.registerWatchdog])
        #expect(state.isLoginItemEnabled)
        #expect(fake.mainAppStatus == .notFound)

        state.setLoginItemEnabled(false)

        #expect(fake.calls == [.registerWatchdog, .unregisterWatchdog])
        #expect(!state.isLoginItemEnabled)
        #expect(fake.mainAppStatus == .notFound)
    }

    @Test func toggleRegisterFailureSurfacesErrorAndRefreshesStatus() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .notFound)
        fake.registerWatchdogError = FakeLoginItemError.requested
        let state = AppState.forLoginItemTest(loginService: fake)

        state.setLoginItemEnabled(true)

        #expect(fake.calls == [.registerWatchdog])
        #expect(!state.isLoginItemEnabled)
        #expect(state.errorMessage == UICopy.ERROR_LOGIN_ITEM)
    }

    @Test func freshInstallRegistersWatchdogOnly() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .notFound)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded()

        #expect(fake.calls == [.registerWatchdog])
        #expect(fake.watchdogStatus == .enabled)
        #expect(fake.mainAppStatus == .notFound)
        #expect(state.isLoginItemEnabled)
    }

    @Test func upgradeRegistersWatchdogBeforeUnregisteringMainApp() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .enabled)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded()

        #expect(fake.calls == [.registerWatchdog, .unregisterMainApp])
        #expect(fake.watchdogStatus == .enabled)
        #expect(fake.mainAppStatus == .notRegistered)
        #expect(state.isLoginItemEnabled)
    }

    @Test func upgradeRegisterFailureLeavesMainAppIntact() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .enabled)
        fake.registerWatchdogError = FakeLoginItemError.requested
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded()

        #expect(fake.calls == [.registerWatchdog])
        #expect(fake.watchdogStatus == .notFound)
        #expect(fake.mainAppStatus == .enabled)
        #expect(!fake.calls.contains(.unregisterMainApp))
        #expect(state.errorMessage == UICopy.ERROR_LOGIN_ITEM)
        #expect(!state.isLoginItemEnabled)
    }

    @Test func upgradeRollsBackWatchdogWhenMainAppUnregisterFails() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .enabled)
        fake.unregisterMainAppError = FakeLoginItemError.requested
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded()

        #expect(fake.calls == [.registerWatchdog, .unregisterMainApp, .unregisterWatchdog])
        #expect(fake.watchdogStatus == .notRegistered)
        #expect(fake.mainAppStatus == .enabled)
        #expect(!(fake.watchdogStatus == .enabled && fake.mainAppStatus == .enabled))
        #expect(state.errorMessage == UICopy.ERROR_LOGIN_ITEM)
        #expect(!state.isLoginItemEnabled)
    }

    @Test func legacyOptOutDoesNotRegisterWatchdog() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .notRegistered)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded()

        #expect(fake.calls.isEmpty)
        #expect(fake.watchdogStatus == .notFound)
        #expect(fake.mainAppStatus == .notRegistered)
        #expect(!state.isLoginItemEnabled)
    }

    @Test func watchdogOptOutDoesNotRegisterAnything() {
        let mainNotFound = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        let stateNotFound = AppState.forLoginItemTest(loginService: mainNotFound)

        stateNotFound.migrateLoginItemToWatchdogIfNeeded()

        #expect(mainNotFound.calls.isEmpty)
        #expect(mainNotFound.watchdogStatus == .notRegistered)
        #expect(!stateNotFound.isLoginItemEnabled)

        let mainNotRegistered = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notRegistered)
        let stateNotRegistered = AppState.forLoginItemTest(loginService: mainNotRegistered)

        stateNotRegistered.migrateLoginItemToWatchdogIfNeeded()

        #expect(mainNotRegistered.calls.isEmpty)
        #expect(mainNotRegistered.watchdogStatus == .notRegistered)
        #expect(mainNotRegistered.mainAppStatus == .notRegistered)
        #expect(!stateNotRegistered.isLoginItemEnabled)
    }

    @Test func enabledWatchdogMigrationIsIdempotent() {
        let fake = FakeLoginItemService(watchdogStatus: .enabled, mainAppStatus: .notRegistered)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded()
        state.migrateLoginItemToWatchdogIfNeeded()

        #expect(fake.calls.isEmpty)
        #expect(fake.watchdogStatus == .enabled)
        #expect(fake.mainAppStatus == .notRegistered)
        #expect(state.isLoginItemEnabled)
    }

    @Test func enabledWatchdogConvergesLegacyMainApp() {
        let fake = FakeLoginItemService(watchdogStatus: .enabled, mainAppStatus: .enabled)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded()

        #expect(fake.calls == [.unregisterMainApp])
        #expect(fake.watchdogStatus == .enabled)
        #expect(fake.mainAppStatus == .notRegistered)
        #expect(state.isLoginItemEnabled)
    }

    @Test func enabledWatchdogRollsBackWhenLegacyMainAppUnregisterFails() {
        let fake = FakeLoginItemService(watchdogStatus: .enabled, mainAppStatus: .enabled)
        fake.unregisterMainAppError = FakeLoginItemError.requested
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded()

        #expect(fake.calls == [.unregisterMainApp, .unregisterWatchdog])
        #expect(fake.watchdogStatus == .notRegistered)
        #expect(fake.mainAppStatus == .enabled)
        #expect(!(fake.watchdogStatus == .enabled && fake.mainAppStatus == .enabled))
        #expect(state.errorMessage == UICopy.ERROR_LOGIN_ITEM)
        #expect(!state.isLoginItemEnabled)
    }

}

private enum FakeLoginItemError: Error {
    case requested
}

@MainActor
final class FakeLoginItemService: LoginItemService {
    enum Call: Equatable {
        case registerWatchdog
        case unregisterWatchdog
        case unregisterMainApp
    }

    enum Event: Equatable {
        case watchdogStatusRead
        case registerWatchdog
        case unregisterWatchdog
        case unregisterWatchdogAwaitingCompletion
        case unregisterCompletionReleased
        case unregisterMainApp
    }

    private var storedWatchdogStatus: SMAppService.Status
    var mainAppStatus: SMAppService.Status
    var watchdogStatusAfterRegister: SMAppService.Status = .enabled
    var registerWatchdogError: Error?
    var unregisterWatchdogError: Error?
    var unregisterWatchdogAwaitingCompletionError: Error?
    var unregisterMainAppError: Error?
    private(set) var calls: [Call] = []
    private(set) var events: [Event] = []
    private(set) var reconciliationUnregisterCountAtMainAppUnregister: [Int] = []
    var holdAwaitableUnregister = false
    private var pendingUnregisterContinuation: CheckedContinuation<Void, Error>?
    private var unregisterEnteredContinuation: CheckedContinuation<Void, Never>?

    var watchdogStatus: SMAppService.Status {
        get {
            events.append(.watchdogStatusRead)
            return storedWatchdogStatus
        }
        set {
            storedWatchdogStatus = newValue
        }
    }

    init(watchdogStatus: SMAppService.Status, mainAppStatus: SMAppService.Status) {
        storedWatchdogStatus = watchdogStatus
        self.mainAppStatus = mainAppStatus
    }

    func registerWatchdog() throws {
        calls.append(.registerWatchdog)
        events.append(.registerWatchdog)
        if let registerWatchdogError {
            throw registerWatchdogError
        }
        storedWatchdogStatus = watchdogStatusAfterRegister
    }

    func unregisterWatchdog() throws {
        calls.append(.unregisterWatchdog)
        events.append(.unregisterWatchdog)
        if let unregisterWatchdogError {
            throw unregisterWatchdogError
        }
        storedWatchdogStatus = .notRegistered
    }

    func unregisterWatchdogAwaitingCompletion() async throws {
        events.append(.unregisterWatchdogAwaitingCompletion)
        if let unregisterWatchdogAwaitingCompletionError {
            throw unregisterWatchdogAwaitingCompletionError
        }
        guard holdAwaitableUnregister else {
            storedWatchdogStatus = .notRegistered
            events.append(.unregisterCompletionReleased)
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingUnregisterContinuation = continuation
            let enteredContinuation = unregisterEnteredContinuation
            unregisterEnteredContinuation = nil
            enteredContinuation?.resume()
        }
    }

    func waitForAwaitableUnregisterEntered() async {
        guard !events.contains(.unregisterWatchdogAwaitingCompletion) else { return }
        await withCheckedContinuation { continuation in
            unregisterEnteredContinuation = continuation
        }
    }

    func releaseAwaitableUnregister() {
        events.append(.unregisterCompletionReleased)
        storedWatchdogStatus = .notRegistered
        let continuation = pendingUnregisterContinuation
        pendingUnregisterContinuation = nil
        continuation?.resume()
    }

    func unregisterMainApp() throws {
        reconciliationUnregisterCountAtMainAppUnregister.append(
            events.filter { $0 == .unregisterWatchdogAwaitingCompletion }.count
        )
        calls.append(.unregisterMainApp)
        events.append(.unregisterMainApp)
        if let unregisterMainAppError {
            throw unregisterMainAppError
        }
        mainAppStatus = .notRegistered
    }
}
