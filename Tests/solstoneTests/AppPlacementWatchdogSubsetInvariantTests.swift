// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SolstoneCore
@testable import solstone

@Suite("App placement watchdog subset invariant")
struct AppPlacementWatchdogSubsetInvariantTests {
    @Test func gateAllowedLocationsResolveForWatchdog() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cachesURL = root.appendingPathComponent("Caches", isDirectory: true)
        let temporaryDirectoryURL = root.appendingPathComponent("Temporary", isDirectory: true)
        let applicationsURL = root.appendingPathComponent("Applications", isDirectory: true)
        let privateTemporaryRoot = URL(fileURLWithPath: "/private/tmp/solstone-placement-invariant-\(UUID().uuidString)", isDirectory: true)
        let privateVarTemporaryRoot = URL(fileURLWithPath: "/private/var/tmp/solstone-placement-invariant-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: privateTemporaryRoot)
            try? FileManager.default.removeItem(at: privateVarTemporaryRoot)
        }

        // The lode's a-j rows are retained below; translocation is an additional location row.
        let rows = [
            MatrixRow(
                name: "a canonical",
                app: try makeApp(at: applicationsURL, named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: true),
                expectedAllowedReason: .canonical
            ),
            MatrixRow(
                name: "b user Applications",
                app: try makeApp(at: root.appendingPathComponent("User/Applications", isDirectory: true), named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: true),
                expectedAllowedReason: .stableLocation
            ),
            MatrixRow(
                name: "c renamed stable bundle",
                app: try makeApp(at: root.appendingPathComponent("Downloads", isDirectory: true), named: "renamed.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: true),
                expectedAllowedReason: .stableLocation
            ),
            MatrixRow(
                name: "d caches",
                app: try makeApp(at: cachesURL.appendingPathComponent("nested", isDirectory: true), named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: true),
                expectedAllowedReason: nil
            ),
            MatrixRow(
                name: "e temporary",
                app: try makeApp(at: temporaryDirectoryURL.appendingPathComponent("nested", isDirectory: true), named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: true),
                expectedAllowedReason: nil
            ),
            MatrixRow(
                name: "f private tmp",
                app: try makeApp(at: privateTemporaryRoot, named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: true),
                expectedAllowedReason: nil
            ),
            MatrixRow(
                name: "g private var tmp",
                app: try makeApp(at: privateVarTemporaryRoot, named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: true),
                expectedAllowedReason: nil
            ),
            MatrixRow(
                name: "translocation",
                app: try makeApp(at: root.appendingPathComponent("AppTranslocation/id/d", isDirectory: true), named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: true),
                expectedAllowedReason: nil
            ),
            MatrixRow(
                name: "h non-local volume",
                app: try makeApp(at: root.appendingPathComponent("NonLocal", isDirectory: true), named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: true, isLocal: false),
                expectedAllowedReason: nil
            ),
            MatrixRow(
                name: "i non-internal local volume",
                app: try makeApp(at: root.appendingPathComponent("External", isDirectory: true), named: "solstone.app"),
                facts: AppPlacementVolumeFacts(isInternal: nil, isLocal: true),
                expectedAllowedReason: nil
            ),
            MatrixRow(
                name: "j unreadable volume facts",
                app: try makeApp(at: root.appendingPathComponent("Unknown", isDirectory: true), named: "solstone.app"),
                facts: nil,
                expectedAllowedReason: nil
            )
        ]

        for row in rows {
            let decision = AppPlacementGate.evaluate(dependencies: .init(
                bundleURL: row.app.bundleURL,
                environment: [:],
                applicationsURL: applicationsURL,
                cachesURL: cachesURL,
                temporaryDirectoryURL: temporaryDirectoryURL,
                volumeFacts: { _ in row.facts }
            ))

            if let expectedAllowedReason = row.expectedAllowedReason {
                #expect(decision == .allowed(expectedAllowedReason), "\(row.name) gate verdict")
                let resolution = WatchdogIdentityResolver.resolve(
                    writerExecutableURL: row.app.executableURL,
                    cachesURL: cachesURL,
                    temporaryDirectoryURL: temporaryDirectoryURL,
                    volumeIsLocal: { _ in row.facts?.isLocal }
                )
                guard case .resolved = resolution else {
                    Issue.record("\(row.name) gate allowed but watchdog did not resolve: \(resolution)")
                    continue
                }
            } else {
                guard case .repair = decision else {
                    Issue.record("\(row.name) expected gate repair, got \(decision)")
                    continue
                }
            }
        }
    }

    private struct MatrixRow {
        let name: String
        let app: (bundleURL: URL, executableURL: URL)
        let facts: AppPlacementVolumeFacts?
        let expectedAllowedReason: AppPlacementAllowedReason?
    }
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("solstone-placement-invariant-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeApp(at root: URL, named name: String) throws -> (bundleURL: URL, executableURL: URL) {
    let bundleURL = root.appendingPathComponent(name, isDirectory: true)
    let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/solstone-watchdog")
    try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleExecutable": "solstone-watchdog",
        "CFBundleIdentifier": "app.solstone.observer"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    return (bundleURL, executableURL)
}
