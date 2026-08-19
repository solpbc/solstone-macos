// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import solstone

@MainActor
final class FakeRecoveryScheduler {
    private(set) var scheduledDelays: [TimeInterval] = []
    private(set) var invalidatedCount = 0
    private var activeToken: FakeRecoveryTimerToken?

    var hasActiveToken: Bool {
        guard let activeToken else { return false }
        return !activeToken.isInvalidated
    }

    func schedule(
        delay: TimeInterval,
        fire: @escaping @MainActor @Sendable () async -> Void
    ) -> any RecoveryTimerToken {
        let token = FakeRecoveryTimerToken(
            fire: fire,
            onInvalidate: { [weak self] in
                self?.invalidatedCount += 1
            }
        )
        scheduledDelays.append(delay)
        activeToken = token
        return token
    }

    func fireNext() async {
        guard let token = activeToken else { return }
        activeToken = nil
        await token.fireIfValid()
    }
}

@MainActor
final class FakeRecoveryTimerToken: RecoveryTimerToken {
    private let fire: @MainActor @Sendable () async -> Void
    private let onInvalidate: @MainActor () -> Void
    private(set) var isInvalidated = false

    init(
        fire: @escaping @MainActor @Sendable () async -> Void,
        onInvalidate: @escaping @MainActor () -> Void
    ) {
        self.fire = fire
        self.onInvalidate = onInvalidate
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        onInvalidate()
    }

    func fireIfValid() async {
        guard !isInvalidated else { return }
        await fire()
    }
}
