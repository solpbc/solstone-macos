// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
@MainActor
final class AppPlacementRepairCoordinator {
    static let shared = AppPlacementRepairCoordinator()

    private let present: (AppPlacementContext) -> Void
    private var pendingContext: AppPlacementContext?
    private var isReady = false
    private var hasPresented = false

    init(
        present: @escaping (AppPlacementContext) -> Void = {
            AppPlacementRepairTerminal.run(context: $0)
        }
    ) {
        self.present = present
    }

    func registerRepair(context: AppPlacementContext) {
        pendingContext = context
        presentIfReady()
    }

    func signalReadiness() {
        isReady = true
        presentIfReady()
    }

    private func presentIfReady() {
        guard isReady, !hasPresented, let context = pendingContext else { return }
        hasPresented = true
        present(context)
    }
}
