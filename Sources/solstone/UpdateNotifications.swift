// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UserNotifications
import UpdateKit

enum UpdateNotificationIdentifier {
    static let prefix = "app.solstone.observer.updates.version."

    static func make(version: String) -> String {
        prefix + version
    }
}

enum UserNotificationClickDestination: Equatable {
    case updatesSettings
    case solChat(requestID: String)
}

func userNotificationClickDestination(for identifier: String) -> UserNotificationClickDestination {
    if identifier.hasPrefix(UpdateNotificationIdentifier.prefix) {
        return .updatesSettings
    }
    return .solChat(requestID: identifier)
}

func userNotificationPresentationOptions(for identifier: String) -> UNNotificationPresentationOptions {
    switch userNotificationClickDestination(for: identifier) {
    case .updatesSettings:
        [.list]
    case .solChat:
        [.banner, .list, .sound]
    }
}

struct UpdateNotificationAnnouncer: Sendable {
    private let notifier: any SolChatNotifying
    private let copy: UpdatesCopy

    init(
        notifier: any SolChatNotifying = UNUserNotificationSolChatNotifier(),
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
