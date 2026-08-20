// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import UserNotifications
import os
import SolstoneCore

public protocol UserNotifying: Sendable {
    func currentAuthorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool
    func post(identifier: String, title: String, body: String, sound: Bool) async
}

public final class UNUserNotificationCenterNotifier: UserNotifying, @unchecked Sendable {
    public init() {}

    public func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    public func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        } catch {
            Logger.general.info("Notification authorization failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    public func post(identifier: String, title: String, body: String, sound: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.general.info("Notification post failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

struct NoopUserNotifier: UserNotifying {
    func currentAuthorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool { true }
    func post(identifier: String, title: String, body: String, sound: Bool) async {}
}

private final class UserNotificationCompletion: @unchecked Sendable {
    private let completionHandler: () -> Void

    init(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
    }

    func call() {
        completionHandler()
    }
}

final class UserNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let completion = UserNotificationCompletion(completionHandler)
        Task { @MainActor in
            if UpdateNotificationIdentifier.isUpdateNotification(id) {
                if let state = AppState.shared {
                    state.pendingSettingsTab = "updates"
                } else {
                    Logger.general.error("AppState.shared nil in update notification click")
                }
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
            completion.call()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(userNotificationPresentationOptions(for: notification.request.identifier))
    }
}
