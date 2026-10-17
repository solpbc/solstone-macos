// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import os

/// Manages registration state, local chord capture, and pause toggling for global keyboard shortcuts.
@MainActor
@Observable
public final class PauseShortcutController {
    public enum State: Equatable, Sendable {
        case off
        case active(PauseShortcutChord)
        case conflict(PauseShortcutChord)
        case unavailable(PauseShortcutChord)

        public var chord: PauseShortcutChord? {
            switch self {
            case .off: return nil
            case .active(let c), .conflict(let c), .unavailable(let c): return c
            }
        }
    }

    public private(set) var state: State = .off
    public private(set) var isCapturing: Bool = false
    public private(set) var captureErrorMessage: String?

    public var isUnavailableOrConflict: Bool {
        switch state {
        case .conflict, .unavailable:
            return true
        case .off, .active:
            return false
        }
    }

    private let registrar: PauseShortcutRegistrar
    private let pausePort: PauseShortcutPausePort
    private let onPersistChord: @MainActor (PauseShortcutChord?) -> Void

    private var activeToken: PauseShortcutToken?
    private var hasToggledForCurrentPress = false
    private var registrationGeneration: UInt64 = 0

    private var priorStateOnCaptureStart: State = .off
    private var localMonitor: Any?
    private var windowResignObserver: Any?

    public init(
        registrar: PauseShortcutRegistrar,
        pausePort: PauseShortcutPausePort,
        onPersistChord: @escaping @MainActor (PauseShortcutChord?) -> Void
    ) {
        self.registrar = registrar
        self.pausePort = pausePort
        self.onPersistChord = onPersistChord
    }

    deinit {
        // MainActor deinit cleanup of non-Sendable monitor
    }

    public func seedSnapshotState(_ state: State) {
        self.state = state
    }

    public func apply(chord: PauseShortcutChord?) {
        guard !isCapturing else { return }

        guard let chord else {
            unregister()
            state = .off
            return
        }

        // If already active with the same chord, maintain registration
        if case .active(let currentChord) = state, currentChord == chord, activeToken != nil {
            return
        }

        unregister()
        register(chord: chord)
    }

    public func unregister() {
        registrationGeneration &+= 1
        hasToggledForCurrentPress = false
        if let token = activeToken {
            registrar.unregisterHotKey(token)
            activeToken = nil
        }
    }

    public func beginCapture() {
        guard !isCapturing else { return }
        priorStateOnCaptureStart = state

        unregister()
        isCapturing = true
        captureErrorMessage = nil

        armLocalMonitor()
        armWindowResignObserver()
    }

    public func cancelCapture() {
        guard isCapturing else { return }
        disarmLocalMonitor()
        disarmWindowResignObserver()
        isCapturing = false
        captureErrorMessage = nil

        switch priorStateOnCaptureStart {
        case .off:
            state = .off
        case .active(let chord):
            register(chord: chord)
        case .conflict(let chord):
            state = .conflict(chord)
        case .unavailable(let chord):
            state = .unavailable(chord)
        }
    }

    public func clear() {
        disarmLocalMonitor()
        disarmWindowResignObserver()
        isCapturing = false
        captureErrorMessage = nil

        unregister()
        state = .off
        onPersistChord(nil)
    }

    public func handleApplicationDidBecomeActive() {
        guard !isCapturing else { return }
        guard let chord = state.chord else { return }

        do {
            let symbolics = try registrar.copySymbolicHotKeys()
            if symbolics.contains(where: { $0.isEnabled && $0.keyCode == chord.keyCode && $0.carbonModifiers == chord.carbonModifiers }) {
                unregister()
                state = .conflict(chord)
                return
            }

            if activeToken == nil {
                tryRegister(chord: chord)
            }
        } catch {
            Logger.general.error("Failed to query symbolic hotkeys on activation: \(error, privacy: .public)")
            unregister()
            state = .unavailable(chord)
        }
    }

    private func register(chord: PauseShortcutChord) {
        do {
            let symbolics = try registrar.copySymbolicHotKeys()
            if symbolics.contains(where: { $0.isEnabled && $0.keyCode == chord.keyCode && $0.carbonModifiers == chord.carbonModifiers }) {
                unregister()
                state = .conflict(chord)
                return
            }
            tryRegister(chord: chord)
        } catch {
            Logger.general.error("Symbolic hotkey check failed for chord: \(error, privacy: .public)")
            unregister()
            state = .unavailable(chord)
        }
    }

    private func tryRegister(chord: PauseShortcutChord) {
        let generation = registrationGeneration
        do {
            let token = try registrar.registerExclusiveHotKey(
                keyCode: chord.keyCode,
                carbonModifiers: chord.carbonModifiers,
                onPressed: { [weak self] in self?.handleHotKeyPressed(generation: generation) },
                onReleased: { [weak self] in self?.handleHotKeyReleased(generation: generation) }
            )
            activeToken = token
            state = .active(chord)
        } catch {
            Logger.general.error("Exclusive registration failed for chord: \(error, privacy: .public)")
            unregister()
            state = .unavailable(chord)
        }
    }

    public func handleHotKeyPressed() {
        handleHotKeyPressed(generation: registrationGeneration)
    }

    public func handleHotKeyReleased() {
        handleHotKeyReleased(generation: registrationGeneration)
    }

    internal func handleHotKeyPressed(generation: UInt64) {
        guard generation == registrationGeneration else { return }
        guard !isCapturing else { return }
        guard !hasToggledForCurrentPress else { return }
        hasToggledForCurrentPress = true
        togglePause()
    }

    internal func handleHotKeyReleased(generation: UInt64) {
        guard generation == registrationGeneration else { return }
        hasToggledForCurrentPress = false
    }

    private func togglePause() {
        if pausePort.isOwnerPaused {
            pausePort.resumeOwnerPause()
        } else {
            pausePort.pauseIndefinitely()
        }
    }

    private func armLocalMonitor() {
        disarmLocalMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            dispatchPrecondition(condition: .onQueue(.main))
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isCapturing else { return false }
                guard self.isSettingsKeyWindow() else { return false }
                self.handleCapturedKey(keyCode: keyCode, modifierFlags: flags)
                return true
            }
            return consumed ? nil : event
        }
    }

    private func disarmLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func armWindowResignObserver() {
        disarmWindowResignObserver()
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            dispatchPrecondition(condition: .onQueue(.main))
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.isCapturing else { return }
                if window?.identifier?.rawValue.contains(SolstoneSceneID.settings.rawValue) == true {
                    self.cancelCapture()
                }
            }
        }
    }

    private func disarmWindowResignObserver() {
        if let observer = windowResignObserver {
            NotificationCenter.default.removeObserver(observer)
            windowResignObserver = nil
        }
    }

    private func isSettingsKeyWindow() -> Bool {
        NSApp.keyWindow?.identifier?.rawValue.contains(SolstoneSceneID.settings.rawValue) == true
    }

    internal func handleCapturedKey(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        if keyCode == 53 { // Escape
            cancelCapture()
            return
        }

        let keyCodeU32 = UInt32(keyCode)
        if PauseShortcutChord.rejectedModifierKeyCodes.contains(keyCodeU32) {
            return
        }

        var carbonMods: UInt32 = 0
        if modifierFlags.contains(.command) { carbonMods |= PauseShortcutChord.cmdKey }
        if modifierFlags.contains(.shift) { carbonMods |= PauseShortcutChord.shiftKey }
        if modifierFlags.contains(.option) { carbonMods |= PauseShortcutChord.optionKey }
        if modifierFlags.contains(.control) { carbonMods |= PauseShortcutChord.controlKey }

        guard let chord = PauseShortcutChord(keyCode: keyCodeU32, carbonModifiers: carbonMods) else {
            captureErrorMessage = UICopy.SHORTCUT_ERROR_CMD_OR_CTRL
            return
        }

        disarmLocalMonitor()
        disarmWindowResignObserver()
        isCapturing = false
        captureErrorMessage = nil

        onPersistChord(chord)
        apply(chord: chord)
    }
}
