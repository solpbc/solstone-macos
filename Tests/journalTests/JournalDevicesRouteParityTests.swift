// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing

@Suite("JournalDevicesRouteParity")
struct JournalDevicesRouteParityTests {
    @Test func clientContainsExactlyPinnedRoutesAndNoObserverListRoute() throws {
        let expectedRoutes = [
            "/app/network/api/devices",
            "/app/network/pair-start",
            "/app/network/api/pair/nonce-status",
            "/app/network/rename",
            "/app/network/unpair",
        ]
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/journal/JournalDevicesClient.swift"),
            encoding: .utf8
        )
        let routeLiterals = appRouteLiterals(in: source)

        #expect(routeLiterals.sorted() == expectedRoutes.sorted())
        for route in expectedRoutes {
            #expect(source.components(separatedBy: route).count - 1 == 1)
        }
        #expect(!(try journalSources()).contains("/app/observer/api/list"))
    }

    private func appRouteLiterals(in source: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #""(/app/[^"]+)""#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let routeRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[routeRange])
        }
    }

    private func journalSources() throws -> String {
        let sourcesRoot = repoRoot().appendingPathComponent("Sources/journal")
        let urls = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []
        return try urls
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
