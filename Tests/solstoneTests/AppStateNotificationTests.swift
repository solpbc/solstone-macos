// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
import AppKit
import UserNotifications
import SolstoneCore
@testable import solstone

private actor AppStateNotificationTestNotifier: UserNotifying {
    var status: UNAuthorizationStatus
    var requestResult: Bool
    var statusAfterRequest: UNAuthorizationStatus?
    var statusReadDelayNanoseconds: UInt64 = 0
    private(set) var requestedOptions: [UNAuthorizationOptions] = []
    private(set) var posts: [(identifier: String, title: String, body: String, sound: Bool)] = []

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

    func post(identifier: String, title: String, body: String, sound: Bool) async {
        posts.append((identifier: identifier, title: title, body: body, sound: sound))
    }
}

@Suite("AppState notifications", .serialized)
@MainActor
struct AppStateNotificationTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func bootstrapRequestsAuthorizationWhenNotDeterminedAndDenied() async {
        let notifier = AppStateNotificationTestNotifier(
            status: .notDetermined,
            requestResult: false,
            statusAfterRequest: .denied
        )
        let state = AppState.forSnapshot(notificationStatus: .notDetermined, notifier: notifier)

        await state.bootstrapNotificationAuthorization()
        await waitUntil { state.notificationAuthorizationStatus == UNAuthorizationStatus.denied }

        #expect(state.notificationAuthorizationStatus == UNAuthorizationStatus.denied)
        #expect(await notifier.requestedOptions.count == 1)
    }

    @Test func bootstrapReflectsNotDeterminedStatusWithoutBecomingAuthorized() async {
        let notifier = AppStateNotificationTestNotifier(
            status: .notDetermined,
            requestResult: false,
            statusAfterRequest: .notDetermined
        )
        let state = AppState.forSnapshot(notificationStatus: .authorized, notifier: notifier)

        await state.bootstrapNotificationAuthorization()
        await waitUntil { state.notificationAuthorizationStatus == UNAuthorizationStatus.notDetermined }

        #expect(state.notificationAuthorizationStatus != UNAuthorizationStatus.authorized)
    }

    @Test func lateStatusReadConvergesToCurrentStatus() async {
        let notifier = AppStateNotificationTestNotifier(status: .notDetermined)
        await notifier.setStatusReadDelay(nanoseconds: 100_000_000)
        let state = AppState.forSnapshot(notificationStatus: .notDetermined, notifier: notifier)

        Task { await state.bootstrapNotificationAuthorization() }
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

    @Test func activationObserverRefreshesMicrophoneAuthorizationThroughReader() async {
        let notifier = AppStateNotificationTestNotifier(status: .authorized)
        let state = AppState.forSnapshot(notificationStatus: .authorized, notifier: notifier)
        state.capture.microphoneAuthorizationReader = { .denied }
        state.refreshMicrophoneAuthorization()
        #expect(state.microphoneAuthorizationCause == .denied)
        state.startObservingActivation()

        state.capture.microphoneAuthorizationReader = { .authorized }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { state.microphoneAuthorizationCause == .authorized }
    }

    @Test func elevateNotificationsRequestsAlertAndSound() async {
        let notifier = AppStateNotificationTestNotifier(status: .provisional)
        let state = AppState.forSnapshot(notificationStatus: .provisional, notifier: notifier)

        state.elevateNotifications()
        await waitUntil { await notifier.requestedOptions.count == 1 }

        #expect(await notifier.requestedOptions == [[.alert, .sound]])
    }

    @Test func updateAnnouncementDoesNotRequestNotificationAuthorization() async {
        let notifier = AppStateNotificationTestNotifier(status: .notDetermined)
        let announcer = UpdateNotificationAnnouncer(notifier: notifier)

        announcer.announce(version: "1.3.9")
        await waitUntil { await notifier.posts.count == 1 }

        let posts = await notifier.posts
        #expect(posts.first?.identifier == UpdateNotificationIdentifier.make(version: "1.3.9"))
        #expect(posts.first?.title == "sol 1.3.9 is ready when you are")
        #expect(posts.first?.body == "it'll be applied the next time you quit and reopen sol.")
        #expect(posts.first?.sound == false)
        #expect(await notifier.requestedOptions.isEmpty)
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
