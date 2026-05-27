// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

public protocol IncompleteSegmentRecovering: Sendable {
    func recoverAll() async -> Int
}

public actor IncompleteSegmentRecoveryCoordinator {
    public static let shared = IncompleteSegmentRecoveryCoordinator()

    private let recoveryFactory: @Sendable () -> any IncompleteSegmentRecovering
    private var isRecovering = false

    public init(
        recoveryFactory: @escaping @Sendable () -> any IncompleteSegmentRecovering = {
            IncompleteSegmentRecovery(verbose: false)
        }
    ) {
        self.recoveryFactory = recoveryFactory
    }

    public func recoverAll() async -> Int {
        guard !isRecovering else {
            Logger.storage.info("Incomplete segment recovery skipped because another recovery is already running")
            return 0
        }

        isRecovering = true
        defer { isRecovering = false }

        let recovered = await recoveryFactory().recoverAll()
        if recovered > 0 {
            Logger.general.info("Recovered \(recovered, privacy: .public) incomplete segment(s)")
        }
        return recovered
    }

    public nonisolated func scheduleDetached() {
        Task.detached { [self] in
            _ = await recoverAll()
        }
    }
}
