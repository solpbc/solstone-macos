// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import SolstoneCapture
@testable import SolstoneCaptureCore

@Suite("IncompleteSegmentRecovery")
struct IncompleteSegmentRecoveryTests {
    private let recovery = IncompleteSegmentRecovery(verbose: false)

    @Test func parseTrackTypeSystemAudio() {
        let result = recovery.parseTrackType(from: "143022_audio_system.m4a", timePrefix: "143022")
        #expect(result == .systemAudio)
    }

    @Test func parseTrackTypeMicrophone() {
        let result = recovery.parseTrackType(from: "143022_audio_BuiltInMicrophoneDevice.m4a", timePrefix: "143022")
        #expect(result == .microphone(name: "BuiltInMicrophoneDevice", deviceUID: "BuiltInMicrophoneDevice"))
    }

    @Test func parseTrackTypeMalformedReturnsMicrophone() {
        let result = recovery.parseTrackType(from: "garbage.txt", timePrefix: "143022")
        #expect(result == .microphone(name: "Unknown", deviceUID: "unknown"))
    }
}
