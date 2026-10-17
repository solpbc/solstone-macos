// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("PermissionSourceLiveStateTests")
@MainActor
struct PermissionSourceLiveStateTests {

    @Test func tokensMatchGrammarAndExactValues() {
        #expect(PermissionSourceLiveAXState.on.axToken == "on")
        #expect(PermissionSourceLiveAXState.paused.axToken == "paused")
        #expect(PermissionSourceLiveAXState.off.axToken == "off")
        #expect(PermissionSourceLiveAXState.notRunning.axToken == "not_running")

        #expect(PermissionSourceLiveState.on.axState == .on)
        #expect(PermissionSourceLiveState.paused(.owner).axState == .paused)
        #expect(PermissionSourceLiveState.paused(.protectedVideo).axState == .paused)
        #expect(PermissionSourceLiveState.off.axState == .off)
        #expect(PermissionSourceLiveState.notRunning.axState == .notRunning)
    }

    @Test func pureFunctionRecordingNotPausedActiveAndSelectedIsOn() {
        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let state = permissionSourceLiveState(
                source: source,
                isRecording: true,
                mediaPaused: false,
                activeSources: .all,
                selectedSources: .all,
                ownerPauseHeldIdle: false,
                protectedVideoHeld: false
            )
            #expect(state == .on)

            let stateProtected = permissionSourceLiveState(
                source: source,
                isRecording: true,
                mediaPaused: false,
                activeSources: .all,
                selectedSources: .all,
                ownerPauseHeldIdle: false,
                protectedVideoHeld: true
            )
            #expect(stateProtected == .on)
        }
    }

    @Test func pureFunctionMediaPausedActiveSelectedProtectedFalseIsPausedOwner() {
        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let state = permissionSourceLiveState(
                source: source,
                isRecording: true,
                mediaPaused: true,
                activeSources: .all,
                selectedSources: .all,
                ownerPauseHeldIdle: false,
                protectedVideoHeld: false
            )
            #expect(state == .paused(.owner))
        }
    }

    @Test func pureFunctionSelectedProtectedVideoHeldNotRecordingIsPausedProtectedVideo() {
        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let state = permissionSourceLiveState(
                source: source,
                isRecording: false,
                mediaPaused: false,
                activeSources: [],
                selectedSources: .all,
                ownerPauseHeldIdle: false,
                protectedVideoHeld: true
            )
            #expect(state == .paused(.protectedVideo))
        }
    }

    @Test func pureFunctionNotSelectedNotRecordingNotActiveIsOff() {
        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let state = permissionSourceLiveState(
                source: source,
                isRecording: false,
                mediaPaused: false,
                activeSources: [],
                selectedSources: [],
                ownerPauseHeldIdle: false,
                protectedVideoHeld: false
            )
            #expect(state == .off)
        }
    }

    @Test func pureFunctionSelectedNotRecordingNotPausedNotHeldIdleNotProtectedIsNotRunning() {
        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let state = permissionSourceLiveState(
                source: source,
                isRecording: false,
                mediaPaused: false,
                activeSources: [],
                selectedSources: .all,
                ownerPauseHeldIdle: false,
                protectedVideoHeld: false
            )
            #expect(state == .notRunning)
        }
    }

    @Test func pureFunctionDeselectedButActiveRecordingNotPausedIsOn() {
        let micState = permissionSourceLiveState(
            source: .microphone,
            isRecording: true,
            mediaPaused: false,
            activeSources: .all,
            selectedSources: .screen,
            ownerPauseHeldIdle: false,
            protectedVideoHeld: false
        )
        #expect(micState == .on)

        let screenState = permissionSourceLiveState(
            source: .screen,
            isRecording: true,
            mediaPaused: false,
            activeSources: .all,
            selectedSources: .screen,
            ownerPauseHeldIdle: false,
            protectedVideoHeld: false
        )
        #expect(screenState == .on)
    }

    @Test func pureFunctionPausedProtectedVideoWithUserPausedControls() {
        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let state = permissionSourceLiveState(
                source: source,
                isRecording: true,
                mediaPaused: true,
                activeSources: .all,
                selectedSources: .all,
                ownerPauseHeldIdle: false,
                protectedVideoHeld: true
            )
            #expect(state == .paused(.protectedVideo))

            let controls = permissionSourceLiveControls(
                state: state,
                isUserPaused: true,
                ownerPauseHeldIdle: false
            )
            #expect(controls.resume == true)
            #expect(controls.pause == false)
            #expect(controls.openSources == false)
            #expect(controls.checkStatus == false)
        }
    }

    @Test func pureFunctionProtectedVideoIdleControls() {
        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let state = permissionSourceLiveState(
                source: source,
                isRecording: false,
                mediaPaused: false,
                activeSources: [],
                selectedSources: .all,
                ownerPauseHeldIdle: false,
                protectedVideoHeld: true
            )
            #expect(state == .paused(.protectedVideo))

            let controls = permissionSourceLiveControls(
                state: state,
                isUserPaused: false,
                ownerPauseHeldIdle: false
            )
            #expect(controls.resume == false)
            #expect(controls.pause == false)
            #expect(controls.openSources == false)
            #expect(controls.checkStatus == false)
        }
    }

    @Test func pureFunctionOwnerPauseHeldIdleControls() {
        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let state = permissionSourceLiveState(
                source: source,
                isRecording: false,
                mediaPaused: false,
                activeSources: [],
                selectedSources: .all,
                ownerPauseHeldIdle: true,
                protectedVideoHeld: false
            )
            #expect(state == .paused(.owner))

            let controls = permissionSourceLiveControls(
                state: state,
                isUserPaused: false,
                ownerPauseHeldIdle: true
            )
            #expect(controls.resume == true)
            #expect(controls.pause == false)
            #expect(controls.openSources == false)
            #expect(controls.checkStatus == false)
        }
    }

    @Test func pureFunctionActiveScreenOnlyRecordingNotPaused() {
        let micState = permissionSourceLiveState(
            source: .microphone,
            isRecording: true,
            mediaPaused: false,
            activeSources: .screen,
            selectedSources: .all,
            ownerPauseHeldIdle: false,
            protectedVideoHeld: false
        )
        #expect(micState == .notRunning)
        let micControls = permissionSourceLiveControls(
            state: micState,
            isUserPaused: false,
            ownerPauseHeldIdle: false
        )
        #expect(micControls.checkStatus == true)
        #expect(micControls.pause == false)
        #expect(micControls.resume == false)
        #expect(micControls.openSources == false)

        let screenState = permissionSourceLiveState(
            source: .screen,
            isRecording: true,
            mediaPaused: false,
            activeSources: .screen,
            selectedSources: .all,
            ownerPauseHeldIdle: false,
            protectedVideoHeld: false
        )
        #expect(screenState == .on)
        let screenControls = permissionSourceLiveControls(
            state: screenState,
            isUserPaused: false,
            ownerPauseHeldIdle: false
        )
        #expect(screenControls.pause == true)
        #expect(screenControls.resume == false)
        #expect(screenControls.openSources == false)
        #expect(screenControls.checkStatus == false)
    }

    @Test func decibelAndBarCounts() {
        #expect(microphoneLevelLitBarCount(decibels: -50.1) == 0)
        #expect(microphoneLevelLitBarCount(decibels: -49.9) == 1)
        #expect(microphoneLevelLitBarCount(decibels: -40.1) == 1)
        #expect(microphoneLevelLitBarCount(decibels: -39.9) == 2)
        #expect(microphoneLevelLitBarCount(decibels: -30.1) == 2)
        #expect(microphoneLevelLitBarCount(decibels: -29.9) == 3)
        #expect(microphoneLevelLitBarCount(decibels: -20.1) == 3)
        #expect(microphoneLevelLitBarCount(decibels: -19.9) == 4)
        #expect(microphoneLevelLitBarCount(decibels: -10.1) == 4)
        #expect(microphoneLevelLitBarCount(decibels: -9.9) == 5)
        #expect(microphoneLevelLitBarCount(decibels: nil) == 0)

        let db0 = microphoneLevelDecibels(peak: 0)
        #expect(abs(db0 - (-120.0)) < 0.01)
        #expect(microphoneLevelLitBarCount(decibels: db0) == 0)

        let db1 = microphoneLevelDecibels(peak: 1)
        #expect(abs(db1 - 0.0) < 0.01)
        #expect(microphoneLevelLitBarCount(decibels: db1) == 5)
    }

    @Test func adapterTimedOwnerPause() {
        let state = AppState.forSnapshot()
        state.captureManager.seedRecordingForTesting(
            currentSegment: FakeCaptureSegment(outputDirectory: FileManager.default.temporaryDirectory),
            sources: .all
        )
        state.capture.handleCaptureStateChange(.paused(reasons: [.user]))
        state.pauseManager.pause(for: .minutes(15))

        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let live = state.permissionSourceLiveState(for: source)
            #expect(live == .paused(.owner))
            let controls = state.permissionSourceLiveControls(for: source)
            #expect(controls.resume == true)
            #expect(controls.pause == false)
        }
    }

    @Test func adapterOwnerPauseHeldIdle() {
        let state = AppState.forSnapshot()
        state.pauseManager.pause(for: .minutes(15))

        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let live = state.permissionSourceLiveState(for: source)
            #expect(live == .paused(.owner))
            let controls = state.permissionSourceLiveControls(for: source)
            #expect(controls.resume == true)
            #expect(controls.pause == false)
        }
    }

    @Test func adapterProtectedVideo() {
        let state = AppState.forSnapshot()
        state.captureManager.lifecycleHoldForProtectedVideo()

        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let live = state.permissionSourceLiveState(for: source)
            #expect(live == .paused(.protectedVideo))
            let controls = state.permissionSourceLiveControls(for: source)
            #expect(controls.resume == false)
            #expect(controls.pause == false)
        }
    }

    @Test func adapterDeferredStart() {
        let state = AppState.forSnapshot()
        state.capture.isStartDeferredForProtectedVideo = true
        #expect(state.captureManager.state.pausedReasons.isEmpty)

        for source in [CaptureSources.microphone, CaptureSources.screen] {
            let live = state.permissionSourceLiveState(for: source)
            #expect(live == .paused(.protectedVideo))
            let controls = state.permissionSourceLiveControls(for: source)
            #expect(controls.resume == false)
            #expect(controls.pause == false)
        }
    }

    @Test func adapterScreenOnly() {
        let state = AppState.forSnapshot()
        state.captureManager.seedRecordingForTesting(
            currentSegment: FakeCaptureSegment(outputDirectory: FileManager.default.temporaryDirectory),
            sources: .screen
        )
        state.capture.handleCaptureStateChange(.recording)

        let micState = state.permissionSourceLiveState(for: .microphone)
        #expect(micState == .notRunning)
        let micControls = state.permissionSourceLiveControls(for: .microphone)
        #expect(micControls.checkStatus == true)
        #expect(micControls.pause == false)

        let screenState = state.permissionSourceLiveState(for: .screen)
        #expect(screenState == .on)
        let screenControls = state.permissionSourceLiveControls(for: .screen)
        #expect(screenControls.pause == true)
        #expect(screenControls.checkStatus == false)
    }
}
