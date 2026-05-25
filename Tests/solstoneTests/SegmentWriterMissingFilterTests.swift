// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Testing
@testable import solstone

@Suite("SegmentWriter missing filter precondition")
struct SegmentWriterMissingFilterTests {
    @MainActor
    @Test func startThrowsBeforeCreatingCapturersWhenFilterIsMissing() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let writer = SegmentWriter(outputDirectory: outputDirectory, timePrefix: "120000")
        let displayInfo = DisplayInfo(
            displayID: 42,
            width: 1920,
            height: 1080,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        do {
            try await writer.start(
                displayInfos: [displayInfo],
                filters: [:],
                audioFilter: nil
            )
            Issue.record("expected missingContentFilter")
        } catch let error as SegmentWriter.SegmentError {
            guard case .missingContentFilter(let displayID) = error else {
                Issue.record("expected missingContentFilter, got \(error)")
                return
            }
            #expect(displayID == 42)
            #expect(error.errorDescription == "Missing SCContentFilter for display 42")
        } catch {
            Issue.record("expected SegmentError.missingContentFilter, got \(error)")
        }
    }
}
