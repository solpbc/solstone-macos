// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

enum BrowserPendingMaterial<Scope: Equatable & Sendable>: Equatable, Sendable {
    case unknown
    case empty
    case present(Scope)
}

/// Holds the scope the owner actually confirmed, independently of intake status.
struct BrowserPendingDiscardInteraction<Scope: Equatable & Sendable>: Sendable {
    struct DiscardRequest: Equatable, Sendable {
        let scope: Scope
        fileprivate let serial: UInt64
        fileprivate let window: UInt64
    }

    private(set) var inventory: BrowserPendingMaterial<Scope> = .unknown
    private(set) var confirmation: Scope?
    private(set) var showsDiscarded = false
    private(set) var showsFailure = false
    private var lastKnownScope: Scope?
    private var operation: DiscardRequest?
    private var serial: UInt64 = 0
    private var window: UInt64 = 0
    private var settingsOpen = false

    var isDiscarding: Bool { operation != nil }
    var viewRevision: UInt64 { window }
    var showsNotice: Bool { lastKnownScope != nil }
    var canRequestDiscard: Bool {
        guard settingsOpen, !isDiscarding, case .present = inventory else { return false }
        return true
    }

    mutating func openSettings() {
        guard !settingsOpen else { return }
        settingsOpen = true
        window &+= 1
        clearResultAndConfirmation()
    }

    mutating func closeSettings() {
        guard settingsOpen else { return }
        settingsOpen = false
        window &+= 1
        clearResultAndConfirmation()
    }

    mutating func observe(_ measured: BrowserPendingMaterial<Scope>) {
        inventory = measured
        switch measured {
        case .unknown:
            // Losing a measurement proves neither removal nor a new scope.
            showsDiscarded = false
        case .empty:
            lastKnownScope = nil
        case .present(let scope):
            lastKnownScope = scope
            showsDiscarded = false
        }
    }

    mutating func requestDiscard() {
        guard canRequestDiscard, case .present(let scope) = inventory else { return }
        confirmation = scope
        showsFailure = false
        showsDiscarded = false
    }

    mutating func cancelDiscard() {
        guard !isDiscarding else { return }
        confirmation = nil
    }

    mutating func beginDiscard() -> DiscardRequest? {
        guard settingsOpen, !isDiscarding, let confirmed = confirmation else { return nil }
        serial &+= 1
        let request = DiscardRequest(scope: confirmed, serial: serial, window: window)
        operation = request
        showsFailure = false
        return request
    }

    mutating func finishDiscard(
        _ request: DiscardRequest,
        durablyCompleted: Bool,
        inventory measured: BrowserPendingMaterial<Scope>
    ) {
        guard operation == request else { return }
        operation = nil
        confirmation = nil
        guard settingsOpen, request.window == window else { return }
        observe(measured)
        showsDiscarded = durablyCompleted
        showsFailure = !showsDiscarded
    }

    private mutating func clearResultAndConfirmation() {
        confirmation = nil
        showsDiscarded = false
        showsFailure = false
    }
}

#endif
