// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ServiceManagement

@MainActor
public protocol LoginItemService {
    var watchdogStatus: SMAppService.Status { get }
    var mainAppStatus: SMAppService.Status { get }
    func registerWatchdog() throws
    func unregisterWatchdog() throws
    func unregisterMainApp() throws
}

@MainActor
public struct LiveLoginItemService: LoginItemService {
    private static let watchdogPlistName = "app.solstone.observer.watchdog.plist"

    public init() {}

    public var watchdogStatus: SMAppService.Status {
        watchdog.status
    }

    public var mainAppStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    public func registerWatchdog() throws {
        try watchdog.register()
    }

    public func unregisterWatchdog() throws {
        try watchdog.unregister()
    }

    public func unregisterMainApp() throws {
        try SMAppService.mainApp.unregister()
    }

    private var watchdog: SMAppService {
        SMAppService.agent(plistName: Self.watchdogPlistName)
    }
}
