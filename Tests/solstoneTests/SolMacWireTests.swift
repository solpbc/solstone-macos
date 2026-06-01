// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore

@Suite("SolMacWire")
struct SolMacWireTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_714_380_496)
    private let fixedUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func commandRoundTripsAllCases() throws {
        let commands: [IPCCommand] = [
            .ping,
            .status,
            .start,
            .stop,
            .pause(seconds: 60),
            .unpause,
            .syncNow,
            .openSettings(tab: "general"),
            .openSettings(tab: nil),
            .reloadConfig,
            .versionInfo
        ]

        for command in commands {
            let decoded = try IPCWire.decoder.decode(IPCCommand.self, from: try IPCWire.encoder.encode(command))
            expect(command, equals: decoded)
        }
    }

    @Test func resultAndPayloadRoundTripAllVariants() throws {
        let payloads: [IPCPayload] = [
            .empty,
            .pong,
            .status(makeStatusInfo()),
            .versionInfo(makeVersionInfo())
        ]

        for payload in payloads {
            let decoded = try IPCWire.decoder.decode(IPCPayload.self, from: try IPCWire.encoder.encode(payload))
            expect(payload, equals: decoded)
        }

        let results: [IPCResult] = [
            .ok(.empty),
            .ok(.pong),
            .ok(.status(makeStatusInfo())),
            .ok(.versionInfo(makeVersionInfo())),
            .error(IPCError(code: "x", message: "y", hint: nil))
        ]

        for result in results {
            let decoded = try IPCWire.decoder.decode(IPCResult.self, from: try IPCWire.encoder.encode(result))
            expect(result, equals: decoded)
        }
    }

    @Test func statusDateUsesISO8601Bytes() throws {
        let response = makeStatusResponse()
        let data = try IPCWire.encoder.encode(response)
        let json = try #require(String(data: data, encoding: .utf8))

        let regex = try NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#)
        let matches = regex.matches(in: json, range: NSRange(json.startIndex..<json.endIndex, in: json))
        #expect(matches.count >= 2)
    }

    @Test func statusInfoCarriesAudioReconciledCount() throws {
        let status = StatusInfo(
            isRecording: true,
            isPaused: false,
            pauseAutoResumeAt: nil,
            serverURL: "https://example.com",
            serverConfigured: true,
            segmentTimeRemainingSeconds: nil,
            pendingUploadCount: 0,
            lastSyncedAt: nil,
            lastError: nil,
            appVersion: "1.0",
            appBuild: "100",
            screenRecordingGranted: true,
            microphoneGranted: true,
            audioReconciledCount: 1
        )

        let decoded = try IPCWire.decoder.decode(StatusInfo.self, from: try IPCWire.encoder.encode(status))

        #expect(decoded.audioReconciledCount == 1)
    }

    @Test func responseEncodingIsDeterministic() throws {
        let response = makeStatusResponse()

        let first = try IPCWire.encoder.encode(response)
        let second = try IPCWire.encoder.encode(response)

        #expect(first == second)
    }

    @Test func errorResultOmitsNilHintInEncodedBytes() throws {
        let data = try IPCWire.encoder.encode(IPCResult.error(IPCError(code: "x", message: "y", hint: nil)))
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString == #"{"kind":"error","value":{"code":"x","message":"y"}}"#)
    }

    @Test func errorResultIncludesHintWhenPresentInEncodedBytes() throws {
        let data = try IPCWire.encoder.encode(IPCResult.error(IPCError(code: "x", message: "y", hint: "z")))
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString == #"{"kind":"error","value":{"code":"x","hint":"z","message":"y"}}"#)
    }

    @Test func openSettingsCommandEmitsNullTabInEncodedBytes() throws {
        let data = try IPCWire.encoder.encode(IPCCommand.openSettings(tab: nil))
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString == #"{"kind":"openSettings","value":{"tab":null}}"#)
    }

    @Test func pauseCommandEmitsNestedSecondsInEncodedBytes() throws {
        let data = try IPCWire.encoder.encode(IPCCommand.pause(seconds: 60))
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(jsonString == #"{"kind":"pause","value":{"seconds":60}}"#)
    }

    @Test func fixtureDecodesWithCurrentSchema() throws {
        let url = try #require(Bundle.module.url(forResource: "IPCResponse-v1.0.0", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let responses = try IPCWire.decoder.decode([IPCResponse].self, from: data)

        #expect(responses.count == 2)
        #expect(responses[0].capabilities?.supportedCommands == [
            "openSettings", "pause", "ping", "reloadConfig", "start", "status", "stop", "syncNow", "unpause", "versionInfo"
        ])

        guard case .ok(.status(let status)) = responses[0].result else {
            Issue.record("Expected first fixture response to be .ok(.status)")
            return
        }

        #expect(status.isRecording)
        #expect(!status.isPaused)
        #expect(status.serverConfigured)
        #expect(status.pendingUploadCount == 3)
        #expect(status.serverURL == "https://example.com")
        #expect(status.segmentTimeRemainingSeconds == 42.5)
        #expect(status.lastError == "none")
        #expect(status.appVersion == "1.0")
        #expect(status.appBuild == "100")
        #expect(status.screenRecordingGranted == nil)
        #expect(status.microphoneGranted == nil)
        #expect(status.audioReconciledCount == nil)

        guard case .ok(.empty) = responses[1].result else {
            Issue.record("Expected second fixture response to be .ok(.empty)")
            return
        }
    }

    @Test func v110FixtureCarriesNewPermissionFields() throws {
        let url = try #require(Bundle.module.url(forResource: "IPCResponse-v1.1.0", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let responses = try IPCWire.decoder.decode([IPCResponse].self, from: data)

        #expect(responses.count == 2)

        guard case .ok(.status(let status)) = responses[0].result else {
            Issue.record("Expected first v1.1.0 fixture response to be .ok(.status)")
            return
        }

        #expect(status.appVersion == "1.1")
        #expect(status.appBuild == "110")
        #expect(status.screenRecordingGranted == true)
        #expect(status.microphoneGranted == true)
        #expect(status.audioReconciledCount == nil)

        guard case .ok(.empty) = responses[1].result else {
            Issue.record("Expected second v1.1.0 fixture response to be .ok(.empty)")
            return
        }
    }

    private func makeStatusResponse() -> IPCResponse {
        IPCResponse(
            id: fixedUUID,
            serverProtocolVersion: SolMacIPCConstants.currentProtocolVersion,
            capabilities: ServerCapabilities(
                serverProtocolVersion: SolMacIPCConstants.currentProtocolVersion,
                minSupportedClientVersion: SolMacIPCConstants.minSupportedClientVersion,
                supportedCommands: ["ping", "status", "start"]
            ),
            result: .ok(.status(makeStatusInfo()))
        )
    }

    private func makeStatusInfo() -> StatusInfo {
        StatusInfo(
            isRecording: true,
            isPaused: false,
            pauseAutoResumeAt: fixedDate.addingTimeInterval(120),
            serverURL: "https://example.com",
            serverConfigured: true,
            segmentTimeRemainingSeconds: 42.5,
            pendingUploadCount: 3,
            lastSyncedAt: fixedDate,
            lastError: "none",
            appVersion: "1.0",
            appBuild: "100",
            screenRecordingGranted: true,
            microphoneGranted: false,
            audioReconciledCount: 1
        )
    }

    private func makeVersionInfo() -> VersionInfo {
        VersionInfo(
            appVersion: "1.0",
            appBuild: "100",
            cliVersion: "1.0",
            cliBuild: "100"
        )
    }

    private func expect(_ lhs: IPCCommand, equals rhs: IPCCommand) {
        switch (lhs, rhs) {
        case (.ping, .ping),
             (.status, .status),
             (.start, .start),
             (.stop, .stop),
             (.unpause, .unpause),
             (.syncNow, .syncNow),
             (.reloadConfig, .reloadConfig),
             (.versionInfo, .versionInfo):
            #expect(true)
        case (.pause(let lhsSeconds), .pause(let rhsSeconds)):
            #expect(lhsSeconds == rhsSeconds)
        case (.openSettings(let lhsTab), .openSettings(let rhsTab)):
            #expect(lhsTab == rhsTab)
        default:
            Issue.record("Expected \(lhs) to equal \(rhs)")
        }
    }

    private func expect(_ lhs: IPCPayload, equals rhs: IPCPayload) {
        switch (lhs, rhs) {
        case (.empty, .empty), (.pong, .pong):
            #expect(true)
        case (.status(let lhsInfo), .status(let rhsInfo)):
            #expect(lhsInfo.isRecording == rhsInfo.isRecording)
            #expect(lhsInfo.isPaused == rhsInfo.isPaused)
            #expect(lhsInfo.pauseAutoResumeAt == rhsInfo.pauseAutoResumeAt)
            #expect(lhsInfo.serverURL == rhsInfo.serverURL)
            #expect(lhsInfo.serverConfigured == rhsInfo.serverConfigured)
            #expect(lhsInfo.segmentTimeRemainingSeconds == rhsInfo.segmentTimeRemainingSeconds)
            #expect(lhsInfo.pendingUploadCount == rhsInfo.pendingUploadCount)
            #expect(lhsInfo.lastSyncedAt == rhsInfo.lastSyncedAt)
            #expect(lhsInfo.lastError == rhsInfo.lastError)
            #expect(lhsInfo.appVersion == rhsInfo.appVersion)
            #expect(lhsInfo.appBuild == rhsInfo.appBuild)
            #expect(lhsInfo.screenRecordingGranted == rhsInfo.screenRecordingGranted)
            #expect(lhsInfo.microphoneGranted == rhsInfo.microphoneGranted)
            #expect(lhsInfo.audioReconciledCount == rhsInfo.audioReconciledCount)
        case (.versionInfo(let lhsInfo), .versionInfo(let rhsInfo)):
            #expect(lhsInfo.appVersion == rhsInfo.appVersion)
            #expect(lhsInfo.appBuild == rhsInfo.appBuild)
            #expect(lhsInfo.cliVersion == rhsInfo.cliVersion)
            #expect(lhsInfo.cliBuild == rhsInfo.cliBuild)
        default:
            Issue.record("Expected \(lhs) to equal \(rhs)")
        }
    }

    private func expect(_ lhs: IPCResult, equals rhs: IPCResult) {
        switch (lhs, rhs) {
        case (.ok(let lhsPayload), .ok(let rhsPayload)):
            expect(lhsPayload, equals: rhsPayload)
        case (.error(let lhsError), .error(let rhsError)):
            #expect(lhsError.code == rhsError.code)
            #expect(lhsError.message == rhsError.message)
            #expect(lhsError.hint == rhsError.hint)
        default:
            Issue.record("Expected \(lhs) to equal \(rhs)")
        }
    }
}
