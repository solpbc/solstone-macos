// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public struct IPCRequest: Codable, Sendable {
    public let id: UUID
    public let protocolVersion: Int
    public let command: IPCCommand

    public init(id: UUID, protocolVersion: Int, command: IPCCommand) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.command = command
    }
}

public enum IPCCommand: Codable, Sendable {
    case ping
    case status
    case start
    case stop
    case pause(seconds: Int)
    case unpause
    case syncNow
    case openSettings(tab: String?)
    case reloadConfig
    case versionInfo

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case ping
        case status
        case start
        case stop
        case pause
        case unpause
        case syncNow
        case openSettings
        case reloadConfig
        case versionInfo
    }

    private enum PauseValueKeys: String, CodingKey {
        case seconds
    }

    private enum OpenSettingsValueKeys: String, CodingKey {
        case tab
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ping:
            self = .ping
        case .status:
            self = .status
        case .start:
            self = .start
        case .stop:
            self = .stop
        case .pause:
            let value = try container.nestedContainer(keyedBy: PauseValueKeys.self, forKey: .value)
            self = .pause(seconds: try value.decode(Int.self, forKey: .seconds))
        case .unpause:
            self = .unpause
        case .syncNow:
            self = .syncNow
        case .openSettings:
            let value = try container.nestedContainer(keyedBy: OpenSettingsValueKeys.self, forKey: .value)
            self = .openSettings(tab: try value.decodeIfPresent(String.self, forKey: .tab))
        case .reloadConfig:
            self = .reloadConfig
        case .versionInfo:
            self = .versionInfo
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping:
            try container.encode(Kind.ping, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .status:
            try container.encode(Kind.status, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .start:
            try container.encode(Kind.start, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .stop:
            try container.encode(Kind.stop, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .pause(let seconds):
            try container.encode(Kind.pause, forKey: .kind)
            var value = container.nestedContainer(keyedBy: PauseValueKeys.self, forKey: .value)
            try value.encode(seconds, forKey: .seconds)
        case .unpause:
            try container.encode(Kind.unpause, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .syncNow:
            try container.encode(Kind.syncNow, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .openSettings(let tab):
            try container.encode(Kind.openSettings, forKey: .kind)
            var value = container.nestedContainer(keyedBy: OpenSettingsValueKeys.self, forKey: .value)
            try value.encode(tab, forKey: .tab)
        case .reloadConfig:
            try container.encode(Kind.reloadConfig, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .versionInfo:
            try container.encode(Kind.versionInfo, forKey: .kind)
            try container.encodeNil(forKey: .value)
        }
    }
}

public struct IPCResponse: Codable, Sendable {
    public let id: UUID
    public let serverProtocolVersion: Int
    public let capabilities: ServerCapabilities?
    public let result: IPCResult

    public init(id: UUID, serverProtocolVersion: Int, capabilities: ServerCapabilities?, result: IPCResult) {
        self.id = id
        self.serverProtocolVersion = serverProtocolVersion
        self.capabilities = capabilities
        self.result = result
    }
}

public enum IPCResult: Codable, Sendable {
    case ok(IPCPayload)
    case error(IPCError)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case ok
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .ok:
            self = .ok(try container.decode(IPCPayload.self, forKey: .value))
        case .error:
            self = .error(try container.decode(IPCError.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let payload):
            try container.encode(Kind.ok, forKey: .kind)
            try container.encode(payload, forKey: .value)
        case .error(let error):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(error, forKey: .value)
        }
    }
}

public enum IPCPayload: Codable, Sendable {
    case empty
    case pong
    case status(StatusInfo)
    case versionInfo(VersionInfo)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case empty
        case pong
        case status
        case versionInfo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .empty:
            self = .empty
        case .pong:
            self = .pong
        case .status:
            self = .status(try container.decode(StatusInfo.self, forKey: .value))
        case .versionInfo:
            self = .versionInfo(try container.decode(VersionInfo.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            try container.encode(Kind.empty, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .pong:
            try container.encode(Kind.pong, forKey: .kind)
            try container.encodeNil(forKey: .value)
        case .status(let status):
            try container.encode(Kind.status, forKey: .kind)
            try container.encode(status, forKey: .value)
        case .versionInfo(let versionInfo):
            try container.encode(Kind.versionInfo, forKey: .kind)
            try container.encode(versionInfo, forKey: .value)
        }
    }
}

public struct ServerCapabilities: Codable, Sendable {
    public let serverProtocolVersion: Int
    public let minSupportedClientVersion: Int
    public let supportedCommands: Set<String>

    private enum CodingKeys: String, CodingKey {
        case serverProtocolVersion
        case minSupportedClientVersion
        case supportedCommands
    }

    public init(serverProtocolVersion: Int, minSupportedClientVersion: Int, supportedCommands: Set<String>) {
        self.serverProtocolVersion = serverProtocolVersion
        self.minSupportedClientVersion = minSupportedClientVersion
        self.supportedCommands = supportedCommands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverProtocolVersion = try container.decode(Int.self, forKey: .serverProtocolVersion)
        self.minSupportedClientVersion = try container.decode(Int.self, forKey: .minSupportedClientVersion)
        let commands = try container.decode([String].self, forKey: .supportedCommands)
        self.supportedCommands = Set(commands)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverProtocolVersion, forKey: .serverProtocolVersion)
        try container.encode(minSupportedClientVersion, forKey: .minSupportedClientVersion)
        try container.encode(supportedCommands.sorted(), forKey: .supportedCommands)
    }
}

public struct StatusInfo: Codable, Sendable {
    public let isRecording: Bool
    public let isPaused: Bool
    public let pauseAutoResumeAt: Date?
    public let serverURL: String?
    public let serverConfigured: Bool
    public let segmentTimeRemainingSeconds: Double?
    public let pendingUploadCount: Int
    public let lastSyncedAt: Date?
    public let lastError: String?
    public let appVersion: String
    public let appBuild: String
    public let screenRecordingGranted: Bool?
    public let microphoneGranted: Bool?

    public init(
        isRecording: Bool,
        isPaused: Bool,
        pauseAutoResumeAt: Date?,
        serverURL: String?,
        serverConfigured: Bool,
        segmentTimeRemainingSeconds: Double?,
        pendingUploadCount: Int,
        lastSyncedAt: Date?,
        lastError: String?,
        appVersion: String,
        appBuild: String,
        screenRecordingGranted: Bool? = nil,
        microphoneGranted: Bool? = nil
    ) {
        self.isRecording = isRecording
        self.isPaused = isPaused
        self.pauseAutoResumeAt = pauseAutoResumeAt
        self.serverURL = serverURL
        self.serverConfigured = serverConfigured
        self.segmentTimeRemainingSeconds = segmentTimeRemainingSeconds
        self.pendingUploadCount = pendingUploadCount
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.screenRecordingGranted = screenRecordingGranted
        self.microphoneGranted = microphoneGranted
    }

    private enum CodingKeys: String, CodingKey {
        case isRecording
        case isPaused
        case pauseAutoResumeAt
        case serverURL
        case serverConfigured
        case segmentTimeRemainingSeconds
        case pendingUploadCount
        case lastSyncedAt
        case lastError
        case appVersion
        case appBuild
        case screenRecordingGranted
        case microphoneGranted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isRecording = try container.decode(Bool.self, forKey: .isRecording)
        self.isPaused = try container.decode(Bool.self, forKey: .isPaused)
        self.pauseAutoResumeAt = try container.decodeIfPresent(Date.self, forKey: .pauseAutoResumeAt)
        self.serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL)
        self.serverConfigured = try container.decode(Bool.self, forKey: .serverConfigured)
        self.segmentTimeRemainingSeconds = try container.decodeIfPresent(Double.self, forKey: .segmentTimeRemainingSeconds)
        self.pendingUploadCount = try container.decode(Int.self, forKey: .pendingUploadCount)
        self.lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.appVersion = try container.decode(String.self, forKey: .appVersion)
        self.appBuild = try container.decode(String.self, forKey: .appBuild)
        self.screenRecordingGranted = try container.decodeIfPresent(Bool.self, forKey: .screenRecordingGranted)
        self.microphoneGranted = try container.decodeIfPresent(Bool.self, forKey: .microphoneGranted)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isRecording, forKey: .isRecording)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encodeIfPresent(pauseAutoResumeAt, forKey: .pauseAutoResumeAt)
        try container.encodeIfPresent(serverURL, forKey: .serverURL)
        try container.encode(serverConfigured, forKey: .serverConfigured)
        try container.encodeIfPresent(segmentTimeRemainingSeconds, forKey: .segmentTimeRemainingSeconds)
        try container.encode(pendingUploadCount, forKey: .pendingUploadCount)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(appBuild, forKey: .appBuild)
        try container.encodeIfPresent(screenRecordingGranted, forKey: .screenRecordingGranted)
        try container.encodeIfPresent(microphoneGranted, forKey: .microphoneGranted)
    }
}

public struct VersionInfo: Codable, Sendable {
    public let appVersion: String
    public let appBuild: String
    public let cliVersion: String
    public let cliBuild: String

    public init(appVersion: String, appBuild: String, cliVersion: String, cliBuild: String) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.cliVersion = cliVersion
        self.cliBuild = cliBuild
    }
}

public struct IPCError: Codable, Sendable {
    public let code: String
    public let message: String
    public let hint: String?

    public init(code: String, message: String, hint: String?) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}
