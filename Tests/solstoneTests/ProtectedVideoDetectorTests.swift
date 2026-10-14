// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Testing
@testable import solstone

@Suite("ProtectedVideoDetectorTests")
struct ProtectedVideoDetectorTests {
    struct MatchTestCase: CustomTestStringConvertible, Sendable {
        let name: String
        let windows: [OnScreenWindowRecord]
        let patterns: [String]
        let enabled: Bool
        let ownPid: pid_t
        let expectedService: String?

        var testDescription: String { name }
    }

    private static let testCases: [MatchTestCase] = [
        // Two distinct inputs per canonical service
        // 1. Netflix
        MatchTestCase(
            name: "netflix chrome",
            windows: [OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Netflix"
        ),
        MatchTestCase(
            name: "netflix safari official site",
            windows: [OnScreenWindowRecord(windowID: 102, pid: 200, ownerName: "Safari", title: "Stranger Things | Netflix Official Site")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Netflix"
        ),

        // 2. Disney+
        MatchTestCase(
            name: "disney+ arc",
            windows: [OnScreenWindowRecord(windowID: 103, pid: 200, ownerName: "Arc", title: "Disney+ | Movies and Shows")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Disney+"
        ),
        MatchTestCase(
            name: "disney+ brave alias",
            windows: [OnScreenWindowRecord(windowID: 104, pid: 200, ownerName: "Brave Browser", title: "Loki - Disney Plus")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Disney+"
        ),

        // 3. Prime Video
        MatchTestCase(
            name: "prime video app",
            windows: [OnScreenWindowRecord(windowID: 105, pid: 200, ownerName: "Prime Video", title: "The Boys")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Prime Video"
        ),
        MatchTestCase(
            name: "prime video safari",
            windows: [OnScreenWindowRecord(windowID: 106, pid: 200, ownerName: "Safari", title: "Watch The Boys | Prime Video")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Prime Video"
        ),

        // 4. Max
        MatchTestCase(
            name: "max firefox",
            windows: [OnScreenWindowRecord(windowID: 107, pid: 200, ownerName: "Firefox", title: "Succession | Max")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Max"
        ),
        MatchTestCase(
            name: "max hbo max chrome",
            windows: [OnScreenWindowRecord(windowID: 108, pid: 200, ownerName: "Google Chrome", title: "House of the Dragon - HBO Max")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Max"
        ),

        // 5. Hulu
        MatchTestCase(
            name: "hulu chrome",
            windows: [OnScreenWindowRecord(windowID: 109, pid: 200, ownerName: "Google Chrome", title: "The Bear | Hulu")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Hulu"
        ),
        MatchTestCase(
            name: "hulu safari stream",
            windows: [OnScreenWindowRecord(windowID: 110, pid: 200, ownerName: "Safari", title: "Hulu - Stream TV")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Hulu"
        ),

        // 6. Apple TV
        MatchTestCase(
            name: "apple tv app",
            windows: [OnScreenWindowRecord(windowID: 111, pid: 200, ownerName: "TV", title: "Ted Lasso")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Apple TV"
        ),
        MatchTestCase(
            name: "apple tv chrome web",
            windows: [OnScreenWindowRecord(windowID: 112, pid: 200, ownerName: "Google Chrome", title: "Severance | Apple TV+")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Apple TV"
        ),

        // 7. Peacock
        MatchTestCase(
            name: "peacock firefox",
            windows: [OnScreenWindowRecord(windowID: 113, pid: 200, ownerName: "Firefox", title: "The Office | Peacock")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Peacock"
        ),
        MatchTestCase(
            name: "peacock safari",
            windows: [OnScreenWindowRecord(windowID: 114, pid: 200, ownerName: "Safari", title: "Peacock - Watch TV")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Peacock"
        ),

        // 8. Paramount+
        MatchTestCase(
            name: "paramount+ chrome",
            windows: [OnScreenWindowRecord(windowID: 115, pid: 200, ownerName: "Google Chrome", title: "Star Trek | Paramount+")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Paramount+"
        ),
        MatchTestCase(
            name: "paramount+ opera alias",
            windows: [OnScreenWindowRecord(windowID: 116, pid: 200, ownerName: "Opera", title: "Survivor - Paramount Plus")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Paramount+"
        ),

        // 9. Crunchyroll
        MatchTestCase(
            name: "crunchyroll vivaldi",
            windows: [OnScreenWindowRecord(windowID: 117, pid: 200, ownerName: "Vivaldi", title: "Jujutsu Kaisen | Crunchyroll")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Crunchyroll"
        ),
        MatchTestCase(
            name: "crunchyroll chrome",
            windows: [OnScreenWindowRecord(windowID: 118, pid: 200, ownerName: "Google Chrome", title: "Crunchyroll - Watch Popular Anime")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Crunchyroll"
        ),

        // Clear cases and edge cases
        MatchTestCase(
            name: "TVHelper clear",
            windows: [OnScreenWindowRecord(windowID: 119, pid: 200, ownerName: "TVHelper", title: "TVHelper Status")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "app named Max clear",
            windows: [OnScreenWindowRecord(windowID: 120, pid: 200, ownerName: "Max", title: "Max Patch 1.2.3")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "comet netflix suffix",
            windows: [OnScreenWindowRecord(windowID: 121, pid: 200, ownerName: "Comet", title: "Netflix - Comet")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Netflix"
        ),
        MatchTestCase(
            name: "firefox netflix",
            windows: [OnScreenWindowRecord(windowID: 122, pid: 200, ownerName: "Firefox", title: "Netflix")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: "Netflix"
        ),
        MatchTestCase(
            name: "google chrome netflix stock falls google search clear",
            windows: [OnScreenWindowRecord(windowID: 123, pid: 200, ownerName: "Google Chrome", title: "Netflix stock falls - Google Search")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "finder netflix clear",
            windows: [OnScreenWindowRecord(windowID: 124, pid: 200, ownerName: "Finder", title: "Netflix")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "google chrome maximum clear",
            windows: [OnScreenWindowRecord(windowID: 125, pid: 200, ownerName: "Google Chrome", title: "Maximum")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "google chrome stranger things trailer youtube clear",
            windows: [OnScreenWindowRecord(windowID: 126, pid: 200, ownerName: "Google Chrome", title: "Stranger Things 5 | Official Trailer | Netflix - YouTube")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "google chrome lowercase netflix google search clear",
            windows: [OnScreenWindowRecord(windowID: 127, pid: 200, ownerName: "Google Chrome", title: "netflix - Google Search")],
            patterns: [],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "pattern mubi matches non-browser",
            windows: [OnScreenWindowRecord(windowID: 128, pid: 200, ownerName: "SomeApp", title: "MUBI | Watch")],
            patterns: ["mubi"],
            enabled: true,
            ownPid: 100,
            expectedService: "mubi"
        ),
        MatchTestCase(
            name: "blank pattern never matches",
            windows: [OnScreenWindowRecord(windowID: 129, pid: 200, ownerName: "SomeApp", title: "Document 1")],
            patterns: ["  "],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "own pid with matching pattern clear",
            windows: [OnScreenWindowRecord(windowID: 130, pid: 100, ownerName: "solstone", title: "Netflix")],
            patterns: ["Netflix"],
            enabled: true,
            ownPid: 100,
            expectedService: nil
        ),
        MatchTestCase(
            name: "toggle off clear",
            windows: [OnScreenWindowRecord(windowID: 131, pid: 200, ownerName: "Google Chrome", title: "Netflix")],
            patterns: [],
            enabled: false,
            ownPid: 100,
            expectedService: nil
        )
    ]

    @Test(arguments: testCases)
    func matchEvaluation(testCase: MatchTestCase) {
        let match = ProtectedVideoDetector.match(
            windows: testCase.windows,
            patterns: testCase.patterns,
            enabled: testCase.enabled,
            ownPid: testCase.ownPid
        )

        if let expected = testCase.expectedService {
            #expect(match != nil)
            #expect(match?.service == expected)
            if let window = testCase.windows.first {
                #expect(match?.windowID == window.windowID)
                #expect(match?.pid == window.pid)
                #expect(match?.ownerName == window.ownerName)
                #expect(match?.title == window.title)
            }
        } else {
            #expect(match == nil)
        }
    }
}
