// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public extension Notification.Name {
    static let journalMarkLocked = Notification.Name("JournalMarkKit.journalMarkLocked")
}

public enum JournalMarkLockedNotification {
    public static let markUserInfoKey = "mark"

    @discardableResult
    public static func post(
        mark: JournalMark,
        center: NotificationCenter = .default
    ) -> Bool {
        guard let validMark = JournalMark.validate(mark) else {
            return false
        }
        center.post(
            name: .journalMarkLocked,
            object: nil,
            userInfo: [markUserInfoKey: validMark]
        )
        return true
    }

    public static func mark(from notification: Notification) -> JournalMark? {
        guard let mark = notification.userInfo?[markUserInfoKey] as? JournalMark else {
            return nil
        }
        return JournalMark.validate(mark)
    }
}
