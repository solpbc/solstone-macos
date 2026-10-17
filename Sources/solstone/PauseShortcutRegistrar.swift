// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
#if canImport(Carbon)
import Carbon
#endif

/// Information about a system symbolic hotkey.
public struct SymbolicHotKeyEntry: Sendable, Equatable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let isEnabled: Bool

    public init(keyCode: UInt32, carbonModifiers: UInt32, isEnabled: Bool) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.isEnabled = isEnabled
    }
}

/// Opaque token identifying an active hotkey registration.
public struct PauseShortcutToken: Hashable, Sendable {
    public let id: UInt32
    public init(id: UInt32) { self.id = id }
}

/// Protocol for querying symbolic hotkeys and managing exclusive global hotkey registration.
/// Contains no Carbon types so fakes can record calls without framework dependencies.
@MainActor
public protocol PauseShortcutRegistrar: AnyObject {
    func copySymbolicHotKeys() throws -> [SymbolicHotKeyEntry]
    func registerExclusiveHotKey(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        onPressed: @escaping @MainActor () -> Void,
        onReleased: @escaping @MainActor () -> Void
    ) throws -> PauseShortcutToken
    func unregisterHotKey(_ token: PauseShortcutToken)
}

/// Dormant registrar for snapshots and headless environments where hotkey registration must not occur.
@MainActor
public final class DormantPauseShortcutRegistrar: PauseShortcutRegistrar {
    public struct DormantError: Error, Sendable {}

    public init() {}
    public func copySymbolicHotKeys() throws -> [SymbolicHotKeyEntry] { [] }
    public func registerExclusiveHotKey(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        onPressed: @escaping @MainActor () -> Void,
        onReleased: @escaping @MainActor () -> Void
    ) throws -> PauseShortcutToken {
        throw DormantError()
    }
    public func unregisterHotKey(_ token: PauseShortcutToken) {}
}

#if canImport(Carbon)
/// Production Carbon adapter for global hotkey management using exclusive registration.
@MainActor
public final class CarbonPauseShortcutRegistrar: PauseShortcutRegistrar {
    private struct ActiveEntry {
        let hotKeyRef: EventHotKeyRef
        let onPressed: @MainActor () -> Void
        let onReleased: @MainActor () -> Void
    }

    public static let expectedHotKeySignature = OSType(0x534F4C53) // 'SOLS'

    internal var _forceEventHandlerUnavailableForTesting: Bool = false

    private var nextTokenID: UInt32 = 1
    private var activeRegistrations: [UInt32: ActiveEntry] = [:]
    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?

    // Shared weak reference used by the C event handler callback on the main runloop
    private static weak var currentRegistrar: CarbonPauseShortcutRegistrar?

    public init() {
        Self.currentRegistrar = self
        installEventHandlerIfNeeded()
    }

    deinit {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    public func unregisterAll() {
        for (_, entry) in activeRegistrations {
            let status = UnregisterEventHotKey(entry.hotKeyRef)
            if status != noErr {
                Logger.general.error("UnregisterEventHotKey failed on unregisterAll: \(status)")
            }
        }
        activeRegistrations.removeAll()
    }

    public func copySymbolicHotKeys() throws -> [SymbolicHotKeyEntry] {
        var arrayRef: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&arrayRef)
        guard status == noErr, let array = arrayRef?.takeRetainedValue() as? [[String: Any]] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
        var entries: [SymbolicHotKeyEntry] = []
        for dict in array {
            guard let keyCodeNum = dict[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modsNum = dict[kHISymbolicHotKeyModifiers as String] as? NSNumber else {
                continue
            }
            let enabled = (dict[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue ?? false
            entries.append(SymbolicHotKeyEntry(
                keyCode: keyCodeNum.uint32Value,
                carbonModifiers: modsNum.uint32Value,
                isEnabled: enabled
            ))
        }
        return entries
    }

    public func registerExclusiveHotKey(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        onPressed: @escaping @MainActor () -> Void,
        onReleased: @escaping @MainActor () -> Void
    ) throws -> PauseShortcutToken {
        guard eventHandlerRef != nil && !_forceEventHandlerUnavailableForTesting else {
            Logger.general.error("Carbon event handler is not installed; rejecting registration")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(eventNotHandledErr), userInfo: nil)
        }

        let tokenID = nextTokenID
        nextTokenID &+= 1

        let hotKeyID = EventHotKeyID(signature: Self.expectedHotKeySignature, id: tokenID) // 'SOLS'
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        )
        guard status == noErr, let ref = hotKeyRef else {
            Logger.general.error("RegisterEventHotKey failed for keyCode=\(keyCode), mods=\(carbonModifiers), status=\(status)")
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }

        activeRegistrations[tokenID] = ActiveEntry(
            hotKeyRef: ref,
            onPressed: onPressed,
            onReleased: onReleased
        )
        return PauseShortcutToken(id: tokenID)
    }

    public func unregisterHotKey(_ token: PauseShortcutToken) {
        guard let entry = activeRegistrations.removeValue(forKey: token.id) else { return }
        let status = UnregisterEventHotKey(entry.hotKeyRef)
        if status != noErr {
            Logger.general.error("UnregisterEventHotKey failed for token=\(token.id), status=\(status)")
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let handlerUPP: EventHandlerUPP = { _, event, _ -> OSStatus in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let event else { return noErr }
            let eventClass = GetEventClass(event)
            let eventKind = GetEventKind(event)
            guard eventClass == OSType(kEventClassKeyboard) else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            return MainActor.assumeIsolated {
                CarbonPauseShortcutRegistrar.processHotKeyEvent(kind: eventKind, hotKeyID: hotKeyID)
            }
        }

        var eventHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerUPP,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
        if status == noErr {
            self.eventHandlerRef = eventHandler
        } else {
            Logger.general.error("Failed to install Carbon event handler: \(status)")
        }
    }

    @MainActor
    @discardableResult
    internal static func processHotKeyEvent(kind: UInt32, hotKeyID: EventHotKeyID) -> OSStatus {
        guard hotKeyID.signature == expectedHotKeySignature else {
            return OSStatus(eventNotHandledErr)
        }
        guard let registrar = currentRegistrar else {
            return OSStatus(eventNotHandledErr)
        }
        registrar.handleEvent(kind: kind, id: hotKeyID.id)
        return noErr
    }

    private func handleEvent(kind: UInt32, id: UInt32) {
        guard let entry = activeRegistrations[id] else { return }
        if kind == UInt32(kEventHotKeyPressed) {
            entry.onPressed()
        } else if kind == UInt32(kEventHotKeyReleased) {
            entry.onReleased()
        }
    }
}
#endif
