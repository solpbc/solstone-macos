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

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

        #expect(fake.calls == [.registerWatchdog])
        #expect(fake.watchdogStatus == .enabled)
        #expect(fake.mainAppStatus == .notFound)
        #expect(state.isLoginItemEnabled)
    }

    @Test func upgradeRegistersWatchdogBeforeUnregisteringMainApp() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .enabled)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

        #expect(fake.calls == [.registerWatchdog, .unregisterMainApp])
        #expect(fake.watchdogStatus == .enabled)
        #expect(fake.mainAppStatus == .notRegistered)
        #expect(state.isLoginItemEnabled)
    }

    @Test func upgradeRegisterFailureLeavesMainAppIntact() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .enabled)
        fake.registerWatchdogError = FakeLoginItemError.requested
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

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

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

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

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

        #expect(fake.calls.isEmpty)
        #expect(fake.watchdogStatus == .notFound)
        #expect(fake.mainAppStatus == .notRegistered)
        #expect(!state.isLoginItemEnabled)
    }

    @Test func watchdogOptOutDoesNotRegisterAnything() {
        let mainNotFound = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        let stateNotFound = AppState.forLoginItemTest(loginService: mainNotFound)

        stateNotFound.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

        #expect(mainNotFound.calls.isEmpty)
        #expect(mainNotFound.watchdogStatus == .notRegistered)
        #expect(!stateNotFound.isLoginItemEnabled)

        let mainNotRegistered = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notRegistered)
        let stateNotRegistered = AppState.forLoginItemTest(loginService: mainNotRegistered)

        stateNotRegistered.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

        #expect(mainNotRegistered.calls.isEmpty)
        #expect(mainNotRegistered.watchdogStatus == .notRegistered)
        #expect(mainNotRegistered.mainAppStatus == .notRegistered)
        #expect(!stateNotRegistered.isLoginItemEnabled)
    }

    @Test func enabledWatchdogMigrationIsIdempotent() {
        let fake = FakeLoginItemService(watchdogStatus: .enabled, mainAppStatus: .notRegistered)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)
        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

        #expect(fake.calls.isEmpty)
        #expect(fake.watchdogStatus == .enabled)
        #expect(fake.mainAppStatus == .notRegistered)
        #expect(state.isLoginItemEnabled)
    }

    @Test func enabledWatchdogConvergesLegacyMainApp() {
        let fake = FakeLoginItemService(watchdogStatus: .enabled, mainAppStatus: .enabled)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

        #expect(fake.calls == [.unregisterMainApp])
        #expect(fake.watchdogStatus == .enabled)
        #expect(fake.mainAppStatus == .notRegistered)
        #expect(state.isLoginItemEnabled)
    }

    @Test func enabledWatchdogRollsBackWhenLegacyMainAppUnregisterFails() {
        let fake = FakeLoginItemService(watchdogStatus: .enabled, mainAppStatus: .enabled)
        fake.unregisterMainAppError = FakeLoginItemError.requested
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

        #expect(fake.calls == [.unregisterMainApp, .unregisterWatchdog])
        #expect(fake.watchdogStatus == .notRegistered)
        #expect(fake.mainAppStatus == .enabled)
        #expect(!(fake.watchdogStatus == .enabled && fake.mainAppStatus == .enabled))
        #expect(state.errorMessage == UICopy.ERROR_LOGIN_ITEM)
        #expect(!state.isLoginItemEnabled)
    }

    @Test func translocationGateDoesNothing() {
        let fake = FakeLoginItemService(watchdogStatus: .notFound, mainAppStatus: .enabled)
        let state = AppState.forLoginItemTest(loginService: fake)

        state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: true)

        #expect(fake.calls.isEmpty)
        #expect(fake.watchdogStatus == .notFound)
        #expect(fake.mainAppStatus == .enabled)
        #expect(!state.isLoginItemEnabled)
    }
}

private enum FakeLoginItemError: Error {
    case requested
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
    enum Call: Equatable {
        case registerWatchdog
        case unregisterWatchdog
        case unregisterMainApp
    }

    var watchdogStatus: SMAppService.Status
    var mainAppStatus: SMAppService.Status
    var watchdogStatusAfterRegister: SMAppService.Status = .enabled
    var registerWatchdogError: Error?
    var unregisterWatchdogError: Error?
    var unregisterMainAppError: Error?
    private(set) var calls: [Call] = []

    init(watchdogStatus: SMAppService.Status, mainAppStatus: SMAppService.Status) {
        self.watchdogStatus = watchdogStatus
        self.mainAppStatus = mainAppStatus
    }

    func registerWatchdog() throws {
        calls.append(.registerWatchdog)
        if let registerWatchdogError {
            throw registerWatchdogError
        }
        watchdogStatus = watchdogStatusAfterRegister
    }

    func unregisterWatchdog() throws {
        calls.append(.unregisterWatchdog)
        if let unregisterWatchdogError {
            throw unregisterWatchdogError
        }
        watchdogStatus = .notRegistered
    }

    func unregisterMainApp() throws {
        calls.append(.unregisterMainApp)
        if let unregisterMainAppError {
            throw unregisterMainAppError
        }
        mainAppStatus = .notRegistered
    }
}
