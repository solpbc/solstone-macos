// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
import AVFoundation
@testable import solstone

@Suite("Permission outcome")
struct PermissionOutcomeTests {
    @Test func microphoneAuthorizationCauseMapsAVAuthorizationStatus() {
        let cases: [(AVAuthorizationStatus, MicrophoneAuthorizationCause)] = [
            (.authorized, .authorized),
            (.notDetermined, .notDetermined),
            (.denied, .denied),
            (.restricted, .restricted),
        ]

        for (status, expected) in cases {
            #expect(PermissionChecker.microphoneAuthorizationCause(from: status) == expected)
        }
    }

    @Test func screenRecordingChecksAreCheckingBeforeInitialPass() {
        #expect(PermissionOutcome.screenRecording(
            initialPermissionCheckComplete: false,
            screenRecordingGranted: false,
            hasPromptedScreenRecording: false,
            preflightSucceeded: false,
            sckFailedAfterPositivePreflight: false
        ) == .checking)
    }

    @Test func screenRecordingGrantedAfterRealSuccess() {
        #expect(PermissionOutcome.screenRecording(
            initialPermissionCheckComplete: true,
            screenRecordingGranted: true,
            hasPromptedScreenRecording: true,
            preflightSucceeded: true,
            sckFailedAfterPositivePreflight: false
        ) == .granted)
        #expect(PermissionOutcome.screenRecording(
            initialPermissionCheckComplete: true,
            screenRecordingGranted: false,
            hasPromptedScreenRecording: true,
            preflightSucceeded: true,
            sckFailedAfterPositivePreflight: false
        ) == .granted)
    }

    @Test func screenRecordingConclusiveNotGrantedDoesNotBecomeUnavailable() {
        #expect(PermissionOutcome.screenRecording(
            initialPermissionCheckComplete: true,
            screenRecordingGranted: false,
            hasPromptedScreenRecording: true,
            preflightSucceeded: false,
            sckFailedAfterPositivePreflight: false
        ) == .notGranted)
    }

    @Test func screenRecordingPositivePreflightSCKFailureIsUnavailable() {
        #expect(PermissionOutcome.screenRecording(
            initialPermissionCheckComplete: true,
            screenRecordingGranted: false,
            hasPromptedScreenRecording: true,
            preflightSucceeded: true,
            sckFailedAfterPositivePreflight: true
        ) == .unavailable)
    }

    @Test func microphoneOutcomesDistinguishCauses() {
        #expect(PermissionOutcome.microphone(
            initialPermissionCheckComplete: false,
            cause: .notDetermined
        ) == .checking)
        #expect(PermissionOutcome.microphone(
            initialPermissionCheckComplete: true,
            cause: .authorized
        ) == .granted)
        #expect(PermissionOutcome.microphone(
            initialPermissionCheckComplete: true,
            cause: .notDetermined
        ) == .notGranted)
        #expect(PermissionOutcome.microphone(
            initialPermissionCheckComplete: true,
            cause: .denied
        ) == .notGranted)
        #expect(PermissionOutcome.microphone(
            initialPermissionCheckComplete: true,
            cause: .restricted
        ) == .notGranted)
        #expect(PermissionOutcome.microphone(
            initialPermissionCheckComplete: true,
            cause: .unknown
        ) == .unavailable)
    }
}
