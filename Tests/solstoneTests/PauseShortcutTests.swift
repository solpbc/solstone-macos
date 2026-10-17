// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import Testing
@testable import solstone

// MARK: - Test Doubles

@MainActor
private final class FakePauseShortcutRegistrar: PauseShortcutRegistrar {
    var symbolicHotKeys: [SymbolicHotKeyEntry] = []
    var shouldThrowCopySymbolic = false
    var shouldThrowRegister = false

    struct RegistrationRecord {
        let token: PauseShortcutToken
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let onPressed: @MainActor () -> Void
        let onReleased: @MainActor () -> Void
    }

    var registrations: [RegistrationRecord] = []
    var unregisteredTokens: [PauseShortcutToken] = []
    private var nextTokenId: UInt32 = 1

    func copySymbolicHotKeys() throws -> [SymbolicHotKeyEntry] {
        if shouldThrowCopySymbolic {
            struct QueryError: Error {}
            throw QueryError()
        }
        return symbolicHotKeys
    }

    func registerExclusiveHotKey(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        onPressed: @escaping @MainActor () -> Void,
        onReleased: @escaping @MainActor () -> Void
    ) throws -> PauseShortcutToken {
        if shouldThrowRegister {
            struct RegError: Error {}
            throw RegError()
        }
        let token = PauseShortcutToken(id: nextTokenId)
        nextTokenId += 1
        let record = RegistrationRecord(
            token: token,
            keyCode: keyCode,
            carbonModifiers: carbonModifiers,
            onPressed: onPressed,
            onReleased: onReleased
        )
        registrations.append(record)
        return token
    }

    func unregisterHotKey(_ token: PauseShortcutToken) {
        unregisteredTokens.append(token)
        registrations.removeAll { $0.token == token }
    }
}

@MainActor
private final class FakePausePort: PauseShortcutPausePort {
    var isOwnerPaused: Bool = false
    var pauseIndefinitelyCalls = 0
    var resumeOwnerPauseCalls = 0

    func pauseIndefinitely() {
        pauseIndefinitelyCalls += 1
        isOwnerPaused = true
    }

    func resumeOwnerPause() {
        resumeOwnerPauseCalls += 1
        isOwnerPaused = false
    }
}

// MARK: - Test Suite

@Suite("PauseShortcut")
struct PauseShortcutTests {
    @Test @MainActor func defaultOff() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()
        var persisted: PauseShortcutChord? = nil

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { persisted = $0 }
        )

        #expect(controller.state == .off)
        #expect(!controller.isCapturing)
        #expect(!controller.isUnavailableOrConflict)
        #expect(persisted == nil)
    }

    @Test func roundTripPersistenceThroughAppConfig() throws {
        let isolatedDefaults = IsolatedUserDefaults()
        defer { isolatedDefaults.clear() }

        var config = AppConfig.load(from: isolatedDefaults.defaults)
        #expect(config.pauseShortcut == nil)

        let chord = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!
        config.pauseShortcut = chord
        try config.save(to: isolatedDefaults.defaults)

        let reloaded = AppConfig.load(from: isolatedDefaults.defaults)
        #expect(reloaded.pauseShortcut == chord)

        // Clear shortcut
        config.pauseShortcut = nil
        try config.save(to: isolatedDefaults.defaults)
        let cleared = AppConfig.load(from: isolatedDefaults.defaults)
        #expect(cleared.pauseShortcut == nil)
    }

    @Test func invalidChordsRejected() {
        // Empty or malformed strings
        #expect(PauseShortcutChord(serialized: "") == nil)
        #expect(PauseShortcutChord(serialized: "35") == nil)
        #expect(PauseShortcutChord(serialized: "35,256,1") == nil)
        #expect(PauseShortcutChord(serialized: "35,abc") == nil)

        // Modifier-only key codes
        for code in PauseShortcutChord.rejectedModifierKeyCodes {
            #expect(PauseShortcutChord(keyCode: code, carbonModifiers: PauseShortcutChord.cmdKey) == nil)
            #expect(PauseShortcutChord(serialized: "\(code),256") == nil)
        }

        // Chords lacking cmd or ctrl
        #expect(PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.shiftKey) == nil)
        #expect(PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.optionKey) == nil)
        #expect(PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.shiftKey | PauseShortcutChord.optionKey) == nil)

        // Disallowed modifier bits
        #expect(PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey | 0x8000) == nil)

        // Valid chord
        let valid = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)
        #expect(valid != nil)
        #expect(valid?.serialized == "0,256")
        #expect(valid?.displayString == "⌘A")
    }

    @Test @MainActor func enabledSymbolicHotkeyRejectedBeforeRegister() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()
        let chord = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!

        registrar.symbolicHotKeys = [
            SymbolicHotKeyEntry(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey, isEnabled: true)
        ]

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { _ in }
        )

        controller.apply(chord: chord)
        #expect(controller.state == .conflict(chord))
        #expect(controller.isUnavailableOrConflict)
        #expect(registrar.registrations.isEmpty)
    }

    @Test @MainActor func disabledSymbolicHotkeyDoesNotConflict() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()
        let chord = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!

        registrar.symbolicHotKeys = [
            SymbolicHotKeyEntry(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey, isEnabled: false)
        ]

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { _ in }
        )

        controller.apply(chord: chord)
        #expect(controller.state == .active(chord))
        #expect(!controller.isUnavailableOrConflict)
        #expect(registrar.registrations.count == 1)
    }

    @Test @MainActor func failedQueryDoesNotRegister() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()
        let chord = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!
        registrar.shouldThrowCopySymbolic = true

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { _ in }
        )

        controller.apply(chord: chord)
        #expect(controller.state == .unavailable(chord))
        #expect(controller.isUnavailableOrConflict)
        #expect(registrar.registrations.isEmpty)
    }

    @Test @MainActor func registrationFailureLeavesNothingRegistered() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()
        let chord = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!
        registrar.shouldThrowRegister = true

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { _ in }
        )

        controller.apply(chord: chord)
        #expect(controller.state == .unavailable(chord))
        #expect(controller.isUnavailableOrConflict)
        #expect(registrar.registrations.isEmpty)
    }

    @Test @MainActor func replaceUnregisterAndClear() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()
        var persisted: PauseShortcutChord? = nil

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { persisted = $0 }
        )

        let chord1 = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!
        let chord2 = PauseShortcutChord(keyCode: 1, carbonModifiers: PauseShortcutChord.controlKey)!

        // Initial apply
        controller.apply(chord: chord1)
        #expect(controller.state == .active(chord1))
        #expect(registrar.registrations.count == 1)

        // Replace
        controller.apply(chord: chord2)
        #expect(controller.state == .active(chord2))
        #expect(registrar.unregisteredTokens.count == 1)
        #expect(registrar.registrations.count == 1)
        #expect(registrar.registrations.first?.keyCode == 1)

        // Unregister
        controller.unregister()
        #expect(registrar.registrations.isEmpty)

        // Clear
        controller.clear()
        #expect(controller.state == .off)
        #expect(persisted == nil)
    }

    @Test @MainActor func heldPressTogglesOnceReleaseAllowsAnotherToggle() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { _ in }
        )

        let chord = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!
        controller.apply(chord: chord)

        #expect(!pausePort.isOwnerPaused)
        #expect(pausePort.pauseIndefinitelyCalls == 0)
        #expect(pausePort.resumeOwnerPauseCalls == 0)

        // First press: toggles to pause
        controller.handleHotKeyPressed()
        #expect(pausePort.isOwnerPaused)
        #expect(pausePort.pauseIndefinitelyCalls == 1)
        #expect(pausePort.resumeOwnerPauseCalls == 0)

        // Held press: no additional toggle
        controller.handleHotKeyPressed()
        controller.handleHotKeyPressed()
        #expect(pausePort.isOwnerPaused)
        #expect(pausePort.pauseIndefinitelyCalls == 1)
        #expect(pausePort.resumeOwnerPauseCalls == 0)

        // Key release
        controller.handleHotKeyReleased()

        // Second press: toggles back to resume
        controller.handleHotKeyPressed()
        #expect(!pausePort.isOwnerPaused)
        #expect(pausePort.pauseIndefinitelyCalls == 1)
        #expect(pausePort.resumeOwnerPauseCalls == 1)

        // Key release
        controller.handleHotKeyReleased()

        // Third press: pauses again
        controller.handleHotKeyPressed()
        #expect(pausePort.isOwnerPaused)
        #expect(pausePort.pauseIndefinitelyCalls == 2)
        #expect(pausePort.resumeOwnerPauseCalls == 1)
    }

    @Test @MainActor func duringCaptureSuspendedBindingAndRecorderKeysDoNotToggle() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { _ in }
        )

        let chord = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!
        controller.apply(chord: chord)
        #expect(registrar.registrations.count == 1)

        controller.beginCapture()
        #expect(controller.isCapturing)
        #expect(registrar.registrations.isEmpty)

        // Incoming hotkey pressed while capturing must return immediately
        controller.handleHotKeyPressed()
        #expect(pausePort.pauseIndefinitelyCalls == 0)
        #expect(pausePort.resumeOwnerPauseCalls == 0)
    }

    @Test @MainActor func cancelCaptureRestoresPriorBindingAndLeavesPauseUnchanged() {
        let registrar = FakePauseShortcutRegistrar()
        let pausePort = FakePausePort()

        let controller = PauseShortcutController(
            registrar: registrar,
            pausePort: pausePort,
            onPersistChord: { _ in }
        )

        let chord = PauseShortcutChord(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey)!

        // Case 1: Prior active
        controller.apply(chord: chord)
        #expect(controller.state == .active(chord))
        controller.beginCapture()
        #expect(controller.isCapturing)
        controller.cancelCapture()
        #expect(!controller.isCapturing)
        #expect(controller.state == .active(chord))
        #expect(registrar.registrations.count == 1)
        #expect(pausePort.pauseIndefinitelyCalls == 0)

        // Case 2: Prior conflict
        controller.clear()
        registrar.symbolicHotKeys = [
            SymbolicHotKeyEntry(keyCode: 0, carbonModifiers: PauseShortcutChord.cmdKey, isEnabled: true)
        ]
        controller.apply(chord: chord)
        #expect(controller.state == .conflict(chord))
        controller.beginCapture()
        controller.cancelCapture()
        #expect(controller.state == .conflict(chord))
        #expect(pausePort.pauseIndefinitelyCalls == 0)

        // Case 3: Prior unavailable
        controller.clear()
        registrar.symbolicHotKeys = []
        registrar.shouldThrowRegister = true
        controller.apply(chord: chord)
        #expect(controller.state == .unavailable(chord))
        controller.beginCapture()
        controller.cancelCapture()
        #expect(controller.state == .unavailable(chord))
        #expect(pausePort.pauseIndefinitelyCalls == 0)

        // Case 4: Settings window resigning key cancels capture and restores prior state
        controller.clear()
        registrar.shouldThrowRegister = false
        controller.apply(chord: chord)
        #expect(controller.state == .active(chord))
        controller.beginCapture()
        #expect(controller.isCapturing)

        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(SolstoneSceneID.settings.rawValue)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        #expect(!controller.isCapturing)
        #expect(controller.state == .active(chord))
        #expect(pausePort.pauseIndefinitelyCalls == 0)
    }

    private struct LocalTestError: Error, Sendable {}

    @Test @MainActor func captureManagerMultiReasonPauseStaysPausedOnUserResume() async {
        let root = URL(fileURLWithPath: "/var/tmp/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            allowsEmptyDisplayConfigurationForTesting: false,
            shareableContentProvider: {
                throw LocalTestError()
            },
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { [] },
            unlockResumeDelay: {}
        )

        // Pause for all 4 reasons
        _ = await manager.lifecyclePauseCapture(reason: PauseReason.user, stopAudio: false)
        _ = await manager.lifecyclePauseCapture(reason: PauseReason.sleep, stopAudio: false)
        _ = await manager.lifecyclePauseCapture(reason: PauseReason.lock, stopAudio: false)
        _ = await manager.lifecyclePauseCapture(reason: PauseReason.protectedVideo, stopAudio: false)

        let expectedAll: Set<PauseReason> = [.user, .sleep, .lock, .protectedVideo]
        #expect(manager.state.pausedReasons == expectedAll)

        // Resume for .user clears only .user
        let resolution = manager.lifecycleApplyResumeReason(ResumeReason.user)
        switch resolution {
        case .stayedPaused:
            break
        case .readyToResume:
            Issue.record("Expected stayedPaused but got readyToResume")
        }
        let expectedRemaining: Set<PauseReason> = [.sleep, .lock, .protectedVideo]
        #expect(manager.state.pausedReasons == expectedRemaining)
    }

    @Test func accessibilityIdentifiersAreStaticAndValid() {
        #expect(AXID.Settings.Observer.shortcut == "settings.observer.general.shortcut")
        #expect(AXID.Settings.Observer.shortcutSet == "settings.observer.general.shortcut.set")
        #expect(AXID.Settings.Observer.shortcutClear == "settings.observer.general.shortcut.clear")
        #expect(AXID.Settings.Observer.shortcutCancel == "settings.observer.general.shortcut.cancel")
        #expect(AXID.Settings.Observer.shortcutStatus == "settings.observer.general.shortcut.status")
        #expect(AXID.Settings.Observer.shortcutPermission == "settings.observer.general.shortcut.permission")
        #expect(AXID.Menubar.shortcutUnavailable == "menubar.shortcut.unavailable")
    }
}
