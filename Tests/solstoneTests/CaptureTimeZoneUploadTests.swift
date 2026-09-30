// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("CaptureTimeZoneUploadTests")
struct CaptureTimeZoneUploadTests {
    private typealias SegmentMetadataState = SyncService.SegmentMetadataState

    private struct DecodedEnvelope: Decodable {
        let day: String
        let segment: String
        let meta: [String: IngestJSONValue]?
    }

    private func isoDate(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: string) else {
            struct DateParseError: Error {}
            throw DateParseError()
        }
        return date
    }

    private func buildAndDecodeEnvelope(
        segmentURL: URL,
        day: String,
        segment: String,
        sidecar: SegmentMetadataState
    ) throws -> (envelope: DecodedEnvelope, rawBody: String) {
        let merged = SyncService.applyingCaptureTimeZone(segmentURL: segmentURL, sidecar: sidecar)

        let metadata: [String: IngestJSONValue]?
        switch merged {
        case .present(let dict):
            metadata = dict
        case .missing:
            metadata = nil
        case .unreadable:
            struct UnreadableError: Error {}
            throw UnreadableError()
        }

        let mediaFile = segmentURL.appendingPathComponent("\(segment)_screen.mp4")
        if !FileManager.default.fileExists(atPath: mediaFile.path) {
            try Data("test".utf8).write(to: mediaFile)
        }

        let bodyURL = segmentURL.appendingPathComponent("body-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        _ = try IngestV3UploadRequestBuilder.build(
            baseURL: "http://127.0.0.1:24680",
            day: day,
            segment: segment,
            selectedFiles: [mediaFile],
            meta: metadata,
            source: nil,
            boundary: "fixed-boundary",
            bodyURL: bodyURL
        )

        let bodyString = try String(contentsOf: bodyURL, encoding: .utf8)
        let marker = "name=\"envelope\"\r\n\r\n"
        guard let startRange = bodyString.range(of: marker) else {
            struct EnvelopeNotFoundError: Error {}
            throw EnvelopeNotFoundError()
        }
        let afterMarker = bodyString[startRange.upperBound...]
        guard let endRange = afterMarker.range(of: "\r\n--") else {
            struct EnvelopeEndNotFoundError: Error {}
            throw EnvelopeEndNotFoundError()
        }
        let envelopeJSON = String(afterMarker[..<endRange.lowerBound])
        let decoded = try JSONDecoder().decode(DecodedEnvelope.self, from: Data(envelopeJSON.utf8))
        return (decoded, bodyString)
    }

    private func reconstructInstant(day: String, segment: String, offsetSeconds: Int) throws -> Date {
        guard day.count == 8,
              let year = Int(day.prefix(4)),
              let month = Int(day.dropFirst(4).prefix(2)),
              let dayNum = Int(day.suffix(2)) else {
            struct InvalidDayError: Error {}
            throw InvalidDayError()
        }

        let timePrefix = String(segment.prefix(6))
        guard timePrefix.count == 6,
              let hour = Int(timePrefix.prefix(2)),
              let minute = Int(timePrefix.dropFirst(2).prefix(2)),
              let second = Int(timePrefix.suffix(2)) else {
            struct InvalidTimePrefixError: Error {}
            throw InvalidTimePrefixError()
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayNum
        components.hour = hour
        components.minute = minute
        components.second = second

        guard let utcCivilDate = calendar.date(from: components) else {
            struct DateComponentError: Error {}
            throw DateComponentError()
        }

        return utcCivilDate.addingTimeInterval(TimeInterval(-offsetSeconds))
    }

    @Test func wireUploadEnvelopeEncodesCaptureTimeZoneAcrossSeasonsAndOffsets() throws {
        let cases: [(iso: String, zoneID: String, expectedTZ: String, expectedOffset: Int, expectedDay: String, expectedPrefix: String)] = [
            ("2026-01-15T19:00:00Z", "America/Denver", "America/Denver", -25200, "20260115", "120000"),
            ("2026-07-15T18:00:00Z", "America/Denver", "America/Denver", -21600, "20260715", "120000"),
            ("2026-01-15T06:30:00Z", "Asia/Kolkata", "Asia/Kolkata", 19800, "20260115", "120000"),
        ]

        for testCase in cases {
            let root = try makeTempDirectory("wire-tz-\(testCase.expectedDay)-\(testCase.expectedTZ)")
            defer { try? FileManager.default.removeItem(at: root) }

            let startDate = try isoDate(testCase.iso)
            let storageManager = StorageManager(baseDirectory: root)
            let zone = try #require(TimeZone(identifier: testCase.zoneID))

            let (segmentURL, timePrefix) = try storageManager.createSegmentDirectory(
                segmentStartTime: startDate,
                timeZone: zone
            )

            let dateFolder = segmentURL.deletingLastPathComponent().lastPathComponent
            let day = dateFolder.replacingOccurrences(of: "-", with: "")
            let segment = "\(timePrefix)_300"

            #expect(day == testCase.expectedDay)
            #expect(timePrefix == testCase.expectedPrefix)

            let (decodedEnvelope, _) = try buildAndDecodeEnvelope(
                segmentURL: segmentURL,
                day: day,
                segment: segment,
                sidecar: .missing
            )

            #expect(decodedEnvelope.day == testCase.expectedDay)
            #expect(decodedEnvelope.segment == segment)

            let meta = try #require(decodedEnvelope.meta)
            #expect(meta["tz"] == .string(testCase.expectedTZ))
            #expect(meta["utc_offset_seconds"] == .integer(testCase.expectedOffset))

            let reconstructed = try reconstructInstant(
                day: decodedEnvelope.day,
                segment: decodedEnvelope.segment,
                offsetSeconds: testCase.expectedOffset
            )
            #expect(reconstructed == startDate)
        }
    }

    @Test func backlogPersistenceAndSidecarMergePrecedence() throws {
        func persistSegmentOnlyURL(root: URL, iso: String, zoneID: String) throws -> (url: URL, day: String, segment: String) {
            let startDate = try isoDate(iso)
            let zone = try #require(TimeZone(identifier: zoneID))
            let storageManager = StorageManager(baseDirectory: root)
            let (segmentURL, timePrefix) = try storageManager.createSegmentDirectory(
                segmentStartTime: startDate,
                timeZone: zone
            )
            let dateFolder = segmentURL.deletingLastPathComponent().lastPathComponent
            let day = dateFolder.replacingOccurrences(of: "-", with: "")
            return (segmentURL, day, "\(timePrefix)_300")
        }

        let root = try makeTempDirectory("backlog-tz-tests")
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Persist Denver and Kolkata and decode without retaining TimeZone reference
        let denverInfo = try persistSegmentOnlyURL(
            root: root.appendingPathComponent("denver", isDirectory: true),
            iso: "2026-01-15T19:00:00Z",
            zoneID: "America/Denver"
        )
        let kolkataInfo = try persistSegmentOnlyURL(
            root: root.appendingPathComponent("kolkata", isDirectory: true),
            iso: "2026-01-15T06:30:00Z",
            zoneID: "Asia/Kolkata"
        )

        let (denverEnvelope, _) = try buildAndDecodeEnvelope(
            segmentURL: denverInfo.url,
            day: denverInfo.day,
            segment: denverInfo.segment,
            sidecar: .missing
        )
        let denverMeta = try #require(denverEnvelope.meta)
        #expect(denverMeta["tz"] == IngestJSONValue.string("America/Denver"))
        #expect(denverMeta["utc_offset_seconds"] == IngestJSONValue.integer(-25200))

        let (kolkataEnvelope, _) = try buildAndDecodeEnvelope(
            segmentURL: kolkataInfo.url,
            day: kolkataInfo.day,
            segment: kolkataInfo.segment,
            sidecar: .missing
        )
        let kolkataMeta = try #require(kolkataEnvelope.meta)
        #expect(kolkataMeta["tz"] == IngestJSONValue.string("Asia/Kolkata"))
        #expect(kolkataMeta["utc_offset_seconds"] == IngestJSONValue.integer(19800))

        // 2. Hand-built directory without zone file and sidecar .missing omits meta (the journal refuses a non-object meta)
        let handBuiltDir = root.appendingPathComponent("handbuilt", isDirectory: true)
        try FileManager.default.createDirectory(at: handBuiltDir, withIntermediateDirectories: true)
        let (_, handBuiltBody) = try buildAndDecodeEnvelope(
            segmentURL: handBuiltDir,
            day: "20260115",
            segment: "120000_300",
            sidecar: .missing
        )
        #expect(!handBuiltBody.contains("\"meta\""))

        // 3. Denver directory with sidecar .present (mics + decoy tz/offset)
        let micValue = IngestJSONValue.object(["count": .integer(1), "devices": .array([.string("built-in-mic")])])
        let sidecarWithMicsAndDecoy: SegmentMetadataState = .present([
            "mics": micValue,
            "tz": .string("MST"),
            "utc_offset_seconds": .integer(0),
        ])
        let (overriddenEnvelope, _) = try buildAndDecodeEnvelope(
            segmentURL: denverInfo.url,
            day: denverInfo.day,
            segment: denverInfo.segment,
            sidecar: sidecarWithMicsAndDecoy
        )
        let overriddenMeta = try #require(overriddenEnvelope.meta)
        #expect(overriddenMeta["mics"] == micValue)
        #expect(overriddenMeta["tz"] == IngestJSONValue.string("America/Denver"))
        #expect(overriddenMeta["utc_offset_seconds"] == IngestJSONValue.integer(-25200))

        // 4. Corrupt capture_zone.json with sidecar .present containing only mics
        let corruptDir = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptZoneFile = corruptDir.appendingPathComponent(StorageManager.captureZoneFileName)
        try Data("{\"tz\":\"America/Denver\",\"utc_offset_seconds\":-25200.0}".utf8).write(to: corruptZoneFile)

        let sidecarWithOnlyMics: SegmentMetadataState = .present([
            "mics": micValue,
        ])
        let (corruptEnvelope, _) = try buildAndDecodeEnvelope(
            segmentURL: corruptDir,
            day: "20260115",
            segment: "120000_300",
            sidecar: sidecarWithOnlyMics
        )
        let corruptMeta = try #require(corruptEnvelope.meta)
        #expect(corruptMeta["mics"] == micValue)
        #expect(corruptMeta["tz"] == nil)
        #expect(corruptMeta["utc_offset_seconds"] == nil)
    }
}
