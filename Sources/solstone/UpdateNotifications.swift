// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UserNotifications
import UpdateKit

enum UpdateNotificationIdentifier {
    static let prefix = "app.solstone.observer.updates.version."

    static func make(version: String) -> String {
        prefix + version
    }

    static func isUpdateNotification(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix)
    }
}

func userNotificationPresentationOptions(for identifier: String) -> UNNotificationPresentationOptions {
    if UpdateNotificationIdentifier.isUpdateNotification(identifier) {
        [.list]
    } else {
        []
    }
}

struct UpdateNotificationAnnouncer: Sendable {
    private let notifier: any UserNotifying
    private let copy: UpdatesCopy

    init(
        notifier: any UserNotifying = UNUserNotificationCenterNotifier(),
        copy: UpdatesCopy = UpdatesCopy(provider: .solstone)
    ) {
        self.notifier = notifier
        self.copy = copy
    }

    @MainActor
    func announce(version: String) {
        let identifier = UpdateNotificationIdentifier.make(version: version)
        let title = copy.updateNotificationTitle(version: version)
        let body = copy.updateNotificationBody
        Task {
            await self.notifier.post(identifier: identifier, title: title, body: body, sound: false)
        }
    }
}
