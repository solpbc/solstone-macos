// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
import AppKit
import UserNotifications
import SolstoneCore
@testable import solstone

private actor AppStateNotificationTestNotifier: SolChatNotifying {
    var status: UNAuthorizationStatus
    var requestResult: Bool
    var statusAfterRequest: UNAuthorizationStatus?
    var statusReadDelayNanoseconds: UInt64 = 0
    private(set) var requestedOptions: [UNAuthorizationOptions] = []

    init(
        status: UNAuthorizationStatus = .notDetermined,
        requestResult: Bool = true,
        statusAfterRequest: UNAuthorizationStatus? = nil
    ) {
        self.status = status
        self.requestResult = requestResult
        self.statusAfterRequest = statusAfterRequest
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        if statusReadDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: statusReadDelayNanoseconds)
        }
        return status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        requestedOptions.append(options)
        if let statusAfterRequest {
            status = statusAfterRequest
        }
        return requestResult
    }

    func post(identifier: String, title: String, body: String) async {}
    func removeDelivered(identifier: String) async {}
}

@Suite("AppState notifications", .serialized)
@MainActor
struct AppStateNotificationTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func falseGrantLeavesPreferenceUnchanged() async {
        let notifier = AppStateNotificationTestNotifier(
            status: .notDetermined,
            requestResult: false,
            statusAfterRequest: .denied
        )
        var config = AppConfig()
        config.solInitiatedChatNotificationsEnabled = false
        let state = AppState.forSnapshot(config: config, notificationStatus: .notDetermined, notifier: notifier)

        state.setSolChatNotificationPreference(true)
        await waitUntil { state.notificationAuthorizationStatus == UNAuthorizationStatus.denied }

        #expect(state.config.solInitiatedChatNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus == UNAuthorizationStatus.denied)
        #expect(await notifier.requestedOptions.count == 1)
    }

    @Test func preferenceTrueReflectsDeniedStatusWithoutBecomingAuthorized() async {
        let notifier = AppStateNotificationTestNotifier(
            status: .notDetermined,
            requestResult: false,
            statusAfterRequest: .denied
        )
        var config = AppConfig()
        config.solInitiatedChatNotificationsEnabled = true
        let state = AppState.forSnapshot(config: config, notificationStatus: .notDetermined, notifier: notifier)

        state.setSolChatNotificationPreference(true)
        await waitUntil { state.notificationAuthorizationStatus == UNAuthorizationStatus.denied }

        #expect(state.config.solInitiatedChatNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus != UNAuthorizationStatus.authorized)
    }

    @Test func preferenceTrueReflectsNotDeterminedStatusWithoutBecomingAuthorized() async {
        let notifier = AppStateNotificationTestNotifier(
            status: .notDetermined,
            requestResult: false,
            statusAfterRequest: .notDetermined
        )
        var config = AppConfig()
        config.solInitiatedChatNotificationsEnabled = true
        let state = AppState.forSnapshot(config: config, notificationStatus: .authorized, notifier: notifier)

        state.setSolChatNotificationPreference(true)
        await waitUntil { state.notificationAuthorizationStatus == UNAuthorizationStatus.notDetermined }

        #expect(state.config.solInitiatedChatNotificationsEnabled)
        #expect(state.notificationAuthorizationStatus != UNAuthorizationStatus.authorized)
    }

    @Test func lateStatusReadConvergesToCurrentStatus() async {
        let notifier = AppStateNotificationTestNotifier(status: .notDetermined)
        await notifier.setStatusReadDelay(nanoseconds: 100_000_000)
        let state = AppState.forSnapshot(notificationStatus: .notDetermined, notifier: notifier)

        state.setSolChatNotificationPreference(true)
        await notifier.setStatus(.denied)
        await waitUntil { state.notificationAuthorizationStatus == UNAuthorizationStatus.denied }

        #expect(await notifier.requestedOptions.isEmpty)
    }

    @Test func activationObserverRefreshesStatusThroughNotifier() async {
        let notifier = AppStateNotificationTestNotifier(status: .authorized)
        let state = AppState.forSnapshot(notificationStatus: .authorized, notifier: notifier)
        state.startObservingActivation()

        await notifier.setStatus(.denied)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { state.notificationAuthorizationStatus == UNAuthorizationStatus.denied }
    }

    @Test func elevateNotificationsRequestsAlertAndSound() async {
        let notifier = AppStateNotificationTestNotifier(status: .provisional)
        let state = AppState.forSnapshot(notificationStatus: .provisional, notifier: notifier)

        state.elevateNotifications()
        await waitUntil { await notifier.requestedOptions.count == 1 }

        #expect(await notifier.requestedOptions == [[.alert, .sound]])
    }

    private func waitUntil(_ predicate: @MainActor @escaping () async -> Bool) async {
        for _ in 0..<100 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await predicate())
    }
}

private extension AppStateNotificationTestNotifier {
    func setStatus(_ status: UNAuthorizationStatus) {
        self.status = status
    }

    func setStatusReadDelay(nanoseconds: UInt64) {
        statusReadDelayNanoseconds = nanoseconds
    }
}
