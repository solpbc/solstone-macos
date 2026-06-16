// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Foundation
import os
import os.lock
import SolstoneCore

private struct ListenerBlockToken: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock
}

final class HALPropertyListener: @unchecked Sendable {
    private struct State {
        var invalidated = false
        var active = false
    }

    private static let queue = DispatchQueue(label: "app.solstone.observer.hal-property-listener")

    private let objectID: AudioObjectID
    private let selector: AudioObjectPropertySelector
    private let scope: AudioObjectPropertyScope
    private let element: AudioObjectPropertyElement
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let token: ListenerBlockToken

    init(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.objectID = objectID
        self.selector = selector
        self.scope = scope
        self.element = element

        let lock = self.lock
        let block: AudioObjectPropertyListenerBlock = { @Sendable _, _ in
            Task { @MainActor in
                guard lock.withLock({ !$0.invalidated }) else { return }
                onChange()
            }
        }
        self.token = ListenerBlockToken(block: block)

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, Self.queue, block)
        if status == noErr {
            lock.withLock { $0.active = true }
        } else {
            Logger.audio.warning("Failed to add HAL property listener selector=\(selector, privacy: .public) status=\(status, privacy: .public)")
        }
    }

    func invalidate() {
        let wasActive = lock.withLock { state in
            if state.invalidated { return false }
            state.invalidated = true
            return state.active
        }
        guard wasActive else { return }

        let objectID = objectID
        let selector = selector
        let scope = scope
        let element = element
        let token = token
        Self.queue.async {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: element
            )
            AudioObjectRemovePropertyListenerBlock(objectID, &address, Self.queue, token.block)
        }
    }

    internal func simulateChangeForTesting() {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        withUnsafePointer(to: &address) { pointer in
            token.block(1, pointer)
        }
    }

    deinit {
        invalidate()
    }
}
