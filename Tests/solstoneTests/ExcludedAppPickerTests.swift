// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Testing
@testable import solstone
@testable import SolstoneCore

@Suite("ExcludedAppPickerTests")
struct ExcludedAppPickerTests {
    // MARK: - Fixtures

    private func makeWindowDict(
        windowID: CGWindowID?,
        ownerName: String,
        title: String = "",
        layer: Int = 0
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowOwnerName as String: ownerName,
            kCGWindowName as String: title,
            kCGWindowLayer as String: layer
        ]
        if let windowID {
            dict[kCGWindowNumber as String] = windowID
        }
        return dict
    }

    // MARK: - Layer-0 Records Extraction

    @Test func layer0RecordsExtractsOnlyNormalLayerWindows() {
        let rawWindows: [[String: Any]] = [
            makeWindowDict(windowID: 101, ownerName: "TV", title: "Apple TV Show", layer: 0),
            makeWindowDict(windowID: 102, ownerName: "Code", title: "ExcludedAppPicker.swift", layer: 0),
            makeWindowDict(windowID: 103, ownerName: "Dock", title: "Dock", layer: 20),
            makeWindowDict(windowID: 104, ownerName: "Overlay", title: "HUD", layer: -1),
            makeWindowDict(windowID: nil, ownerName: "MissingNumber", title: "Ghost", layer: 0)
        ]

        let records = OnScreenWindowList.layer0Records(from: rawWindows)

        #expect(records.count == 2)
        #expect(records[0].windowID == 101)
        #expect(records[0].ownerName == "TV")
        #expect(records[0].title == "Apple TV Show")
        #expect(records[1].windowID == 102)
        #expect(records[1].ownerName == "Code")
        #expect(records[1].title == "ExcludedAppPicker.swift")
    }

    // MARK: - Picker Availability

    @Test func pickerAvailabilityNeedsScreenRecordingWhenPermissionMissing() {
        let rawWindows: [[String: Any]] = [
            makeWindowDict(windowID: 101, ownerName: "TV", layer: 0),
            makeWindowDict(windowID: 102, ownerName: "Code", layer: 0)
        ]
        let records = OnScreenWindowList.layer0Records(from: rawWindows)

        let result = ExcludedAppPicker.evaluate(
            screenRecordingGranted: false,
            records: records,
            alreadyExcludedNames: []
        )

        #expect(result.availability == .needsScreenRecording)
        #expect(result.candidateNames.isEmpty)
        #expect(result.availability.axToken == "needs_screen_recording")
    }

    @Test func pickerAvailabilityNothingAvailableWhenNoCandidateWindows() {
        let rawWindows: [[String: Any]] = [
            makeWindowDict(windowID: 101, ownerName: "", layer: 0),
            makeWindowDict(windowID: 102, ownerName: "   ", layer: 0),
            makeWindowDict(windowID: 103, ownerName: "Overlay", layer: 1)
        ]
        let records = OnScreenWindowList.layer0Records(from: rawWindows)

        let result = ExcludedAppPicker.evaluate(
            screenRecordingGranted: true,
            records: records,
            alreadyExcludedNames: []
        )

        #expect(result.availability == .nothingAvailable)
        #expect(result.candidateNames.isEmpty)
        #expect(result.availability.axToken == "nothing_available")
    }

    @Test func pickerAvailabilityReadyWithSortedUniqueCandidateNames() {
        let rawWindows: [[String: Any]] = [
            makeWindowDict(windowID: 101, ownerName: "TV", layer: 0),
            makeWindowDict(windowID: 102, ownerName: "Code", layer: 0),
            makeWindowDict(windowID: 103, ownerName: "TV", layer: 0),
            makeWindowDict(windowID: 104, ownerName: "Safari", layer: 0)
        ]
        let records = OnScreenWindowList.layer0Records(from: rawWindows)

        let result = ExcludedAppPicker.evaluate(
            screenRecordingGranted: true,
            records: records,
            alreadyExcludedNames: ["Safari"]
        )

        #expect(result.availability == .ready)
        #expect(result.candidateNames == ["Code", "TV"])
        #expect(result.availability.axToken == "ready")
    }

    // MARK: - Exact Stored Name Persistence & Coexistence

    @Test func pickerSelectionPersistsExactOwnerNameFromSameRecord() {
        let rawWindows: [[String: Any]] = [
            makeWindowDict(windowID: 201, ownerName: "TV", layer: 0),
            makeWindowDict(windowID: 202, ownerName: "Code", layer: 0)
        ]
        let records = OnScreenWindowList.layer0Records(from: rawWindows)

        let result = ExcludedAppPicker.evaluate(
            screenRecordingGranted: true,
            records: records,
            alreadyExcludedNames: []
        )

        #expect(result.availability == .ready)

        guard let codeRecord = records.first(where: { $0.ownerName == "Code" }),
              let tvRecord = records.first(where: { $0.ownerName == "TV" }) else {
            Issue.record("Expected records not found")
            return
        }

        var config = AppConfig()
        let initialCount = config.excludedApps.count

        // Add "Code" via helper
        config.excludedApps = ExcludedAppPicker.appending(codeRecord.ownerName, to: config.excludedApps)

        #expect(config.excludedApps.last?.name == codeRecord.ownerName)
        #expect(config.excludedApps.count == initialCount + 1)

        // Add "TV" via helper
        config.excludedApps = ExcludedAppPicker.appending(tvRecord.ownerName, to: config.excludedApps)

        #expect(config.excludedApps.last?.name == tvRecord.ownerName)
        #expect(config.excludedApps.count == initialCount + 2)
    }

    @Test func typedGuessAndPickerNameCoexist() {
        let rawWindows: [[String: Any]] = [
            makeWindowDict(windowID: 301, ownerName: "TV", layer: 0)
        ]
        let records = OnScreenWindowList.layer0Records(from: rawWindows)

        guard let tvRecord = records.first else {
            Issue.record("Expected TV record not found")
            return
        }

        var config = AppConfig()
        // User previously typed guess "Apple TV"
        let typedGuess = "Apple TV"
        config.excludedApps = ExcludedAppPicker.appending(typedGuess, to: config.excludedApps)

        // User subsequently picks window-server name "TV" from picker
        config.excludedApps = ExcludedAppPicker.appending(tvRecord.ownerName, to: config.excludedApps)

        // Both rows must coexist
        let names = config.excludedApps.map(\.name)
        #expect(names.contains(typedGuess))
        #expect(names.contains(tvRecord.ownerName))
    }

    @Test func sameNameCaseInsensitiveSkipPreventsDuplicate() {
        let rawWindows: [[String: Any]] = [
            makeWindowDict(windowID: 401, ownerName: "TV", layer: 0)
        ]
        let records = OnScreenWindowList.layer0Records(from: rawWindows)
        guard let tvRecord = records.first else {
            Issue.record("Expected TV record not found")
            return
        }

        var config = AppConfig()
        config.excludedApps = ExcludedAppPicker.appending(tvRecord.ownerName, to: config.excludedApps)
        let countBefore = config.excludedApps.count

        // Attempt to add "tv"
        config.excludedApps = ExcludedAppPicker.appending(tvRecord.ownerName.lowercased(), to: config.excludedApps)

        #expect(config.excludedApps.count == countBefore)
    }

    // MARK: - Detector Matching

    @Test func detectorMatchesFixtureOwnerNamesWithoutBundleID() {
        let rawWindows: [[String: Any]] = [
            makeWindowDict(windowID: 501, ownerName: "TV", title: "Ted Lasso", layer: 0),
            makeWindowDict(windowID: 502, ownerName: "Code", title: "App.swift", layer: 0),
            makeWindowDict(windowID: 503, ownerName: "Finder", title: "Downloads", layer: 0)
        ]

        let records = OnScreenWindowList.layer0Records(from: rawWindows)

        guard let tvRecord = records.first(where: { $0.ownerName == "TV" }),
              let codeRecord = records.first(where: { $0.ownerName == "Code" }),
              let finderRecord = records.first(where: { $0.ownerName == "Finder" }) else {
            Issue.record("Expected records not found")
            return
        }

        let detector = WindowExclusionDetector(
            appNames: [tvRecord.ownerName, codeRecord.ownerName],
            detectPrivateBrowsing: false,
            titlePatterns: [],
            windowRecordProvider: { records }
        )

        let excludedIDs = detector.detectExcludedWindowIDs()

        #expect(excludedIDs.contains(tvRecord.windowID))
        #expect(excludedIDs.contains(codeRecord.windowID))
        #expect(!excludedIDs.contains(finderRecord.windowID))
    }
}
