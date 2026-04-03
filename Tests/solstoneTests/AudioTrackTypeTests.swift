// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("AudioTrackType")
struct AudioTrackTypeTests {
    @Test func systemAudioDisplayName() {
        #expect(AudioTrackType.systemAudio.displayName == "System Audio")
    }

    @Test func microphoneDisplayName() {
        let mic = AudioTrackType.microphone(name: "Blue Yeti", deviceUID: "uid-123")
        #expect(mic.displayName == "Blue Yeti")
    }

    @Test func systemAudioSourceID() {
        #expect(AudioTrackType.systemAudio.sourceID == "system")
    }

    @Test func microphoneSourceID() {
        let mic = AudioTrackType.microphone(name: "Blue Yeti", deviceUID: "uid-123")
        #expect(mic.sourceID == "uid-123")
    }

    @Test func equality() {
        let a = AudioTrackType.microphone(name: "Mic", deviceUID: "uid-1")
        let b = AudioTrackType.microphone(name: "Mic", deviceUID: "uid-1")
        let c = AudioTrackType.microphone(name: "Mic", deviceUID: "uid-2")
        #expect(a == b)
        #expect(a != c)
        #expect(AudioTrackType.systemAudio == AudioTrackType.systemAudio)
        #expect(AudioTrackType.systemAudio != a)
    }
}
