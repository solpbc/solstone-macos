// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import Foundation
import os

@MainActor
enum IngestV3LiveProbe {
    private static let modeEnvironmentKey = "SOLSTONE_V3_LIVE_PROBE"
    private static let fixtureEnvironmentKey = "SOLSTONE_V3_PROBE_FIXTURE"
    private static let disposableJournalEnvironmentKey = "SOLSTONE_V3_PROBE_DISPOSABLE_JOURNAL"
    private static let routeEnvironmentKey = "SOLSTONE_V3_PROBE_ROUTE"
    private static let disposableJournalAcknowledgement = "I_UNDERSTAND_THIS_IS_DISPOSABLE"
    private static let connectionTimeout: Duration = .seconds(30)

    enum Launch {
        case inactive
        case refused(String)
        case requested(Request)

        var suppressesNormalPipeline: Bool {
            switch self {
            case .inactive: false
            case .refused, .requested: true
            }
        }
    }

    struct Request: Sendable {
        let fixtureURL: URL
        let expectedRoute: TunnelConnectionRoute
    }

    private static var launch: Launch = .inactive

    static func configure(environment: [String: String] = ProcessInfo.processInfo.environment) -> Launch {
        guard environment[modeEnvironmentKey] == "1" else {
            launch = .inactive
            return launch
        }
        guard environment[AppPlacementGate.developerLaunchEnvironmentKey] == "1" else {
            launch = .refused("refusing v3 live probe: \(AppPlacementGate.developerLaunchEnvironmentKey)=1 is required")
            return launch
        }
        guard environment[disposableJournalEnvironmentKey] == disposableJournalAcknowledgement else {
            launch = .refused("refusing v3 live probe: explicit disposable-journal acknowledgement is required")
            return launch
        }
        guard let fixturePath = environment[fixtureEnvironmentKey], !fixturePath.isEmpty else {
            launch = .refused("refusing v3 live probe: \(fixtureEnvironmentKey) is required")
            return launch
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            launch = .refused("refusing v3 live probe: fixture does not exist")
            return launch
        }
        let expectedRoute: TunnelConnectionRoute
        switch environment[routeEnvironmentKey] {
        case "direct-pl": expectedRoute = .lan
        case "relay-spl": expectedRoute = .relay
        default:
            launch = .refused("refusing v3 live probe: \(routeEnvironmentKey) must be direct-pl or relay-spl")
            return launch
        }
        launch = .requested(Request(fixtureURL: fixtureURL, expectedRoute: expectedRoute))
        return launch
    }

    static func startIfRequested(appState: AppState) {
        switch launch {
        case .inactive:
            return
        case .refused(let reason):
            report(reason)
        case .requested(let request):
            Task { @MainActor in
                await run(request: request, appState: appState)
            }
        }
    }

    private static func run(request: Request, appState: AppState) async {
        guard let route = await waitForConnectedRoute(appState: appState) else {
            report("v3 live probe refused: paired loopback did not connect within 30 seconds")
            return
        }
        guard route == request.expectedRoute else {
            report("v3 live probe refused: requested route did not become connected")
            return
        }
        guard appState.isPairedIngestReady else {
            report("v3 live probe refused: connected loopback has no cached pairing identity")
            return
        }

        let day = Self.dayString()
        let segment = "\(Self.clockString())_\(Int.random(in: 100_000...999_999))"
        let directory = appState.storageManager.baseDirectory
            .appendingPathComponent("v3-live-probe", isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(segment, isDirectory: true)
        let stagedFixture = directory.appendingPathComponent("\(segment)_audio.m4a")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try FileManager.default.linkItem(at: request.fixtureURL, to: stagedFixture)
            } catch {
                try FileManager.default.copyItem(at: request.fixtureURL, to: stagedFixture)
            }
            defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }

            let file = try await appState.uploadCoordinator.runLiveIngestProbe(
                segmentURL: directory,
                day: day,
                segment: segment
            )
            report("v3 live probe succeeded: name=\(file.submittedName) sha256=\(file.sha256) size=\(file.size) custody=\(String(describing: file.status))")
        } catch {
            report("v3 live probe failed: \(error.localizedDescription)")
        }
    }

    private static func waitForConnectedRoute(appState: AppState) async -> TunnelConnectionRoute? {
        let deadline = ContinuousClock.now.advanced(by: connectionTimeout)
        while ContinuousClock.now < deadline {
            if case .connected(_, let route) = appState.tunnelLifecycleOwner.state {
                return route
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func dayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }

    private static func clockString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }

    private static func report(_ message: String) {
        Logger.upload.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
#endif
