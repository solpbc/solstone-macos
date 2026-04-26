// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

@MainActor
public final class SolMacResponder {
    public static let supportedCommandKinds: Set<String> = [
        "ping",
        "status",
        "start",
        "stop",
        "pause",
        "unpause",
        "syncNow",
        "openSettings",
        "reloadConfig",
        "versionInfo"
    ]

    private let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public func handle(_ request: IPCRequest, isFirstResponseOnConnection: Bool) async -> IPCResponse {
        Logger.general.debug("ipc request kind=\(self.commandKind(for: request.command), privacy: .public)")

        if request.protocolVersion != SolMacIPCConstants.currentProtocolVersion ||
            request.protocolVersion < SolMacIPCConstants.minSupportedClientVersion {
            return makeResponse(
                for: request,
                isFirstResponseOnConnection: isFirstResponseOnConnection,
                result: .error(IPCError(code: "version_mismatch", message: "protocol version mismatch", hint: nil))
            )
        }

        let result: IPCResult
        switch request.command {
        case .ping:
            result = .ok(.pong)
        case .status:
            result = .ok(.status(buildStatusInfo()))
        case .start:
            guard !appState.isRecording else {
                result = .error(IPCError(code: "already_in_state", message: "already recording", hint: nil))
                break
            }
            await appState.startRecording()
            result = .ok(.empty)
        case .stop:
            guard appState.isRecording else {
                result = .error(IPCError(code: "already_in_state", message: "already stopped", hint: nil))
                break
            }
            await appState.stopRecording()
            result = .ok(.empty)
        case .pause(let seconds):
            guard !isPaused else {
                result = .error(IPCError(code: "already_in_state", message: "already paused", hint: nil))
                break
            }
            if seconds == 0 {
                appState.pauseManager.pause(for: .indefinite)
            } else {
                appState.pauseManager.pause(for: .seconds(seconds))
            }
            result = .ok(.empty)
        case .unpause:
            guard isPaused else {
                result = .error(IPCError(code: "already_in_state", message: "not paused", hint: nil))
                break
            }
            appState.pauseManager.resume()
            result = .ok(.empty)
        case .syncNow:
            guard appState.config.isUploadConfigured else {
                result = .error(IPCError(
                    code: "not_configured",
                    message: "server not configured",
                    hint: "set serverURL and serverKey in settings"
                ))
                break
            }
            appState.uploadCoordinator.triggerSync()
            result = .ok(.empty)
        case .openSettings(let tab):
            appState.pendingSettingsTab = tab
            NotificationCenter.default.post(name: .solMacOpenSettings, object: nil)
            result = .ok(.empty)
        case .reloadConfig:
            Task { @MainActor [appState] in
                appState.reloadConfigFromDisk()
            }
            result = .ok(.empty)
        case .versionInfo:
            result = .ok(.versionInfo(buildVersionInfo()))
        }

        return makeResponse(for: request, isFirstResponseOnConnection: isFirstResponseOnConnection, result: result)
    }

    private var isPaused: Bool {
        appState.pauseManager.isPaused || appState.isPaused
    }

    private func makeResponse(
        for request: IPCRequest,
        isFirstResponseOnConnection: Bool,
        result: IPCResult
    ) -> IPCResponse {
        IPCResponse(
            id: request.id,
            serverProtocolVersion: SolMacIPCConstants.currentProtocolVersion,
            // v1 always populates capabilities (one request per connection); v1.1 may omit on subsequent responses.
            capabilities: isFirstResponseOnConnection ? buildCapabilities() : nil,
            result: result
        )
    }

    private func buildCapabilities() -> ServerCapabilities {
        ServerCapabilities(
            serverProtocolVersion: SolMacIPCConstants.currentProtocolVersion,
            minSupportedClientVersion: SolMacIPCConstants.minSupportedClientVersion,
            supportedCommands: Self.supportedCommandKinds
        )
    }

    private func buildStatusInfo() -> StatusInfo {
        let versionInfo = buildVersionInfo()
        return StatusInfo(
            isRecording: appState.isRecording,
            isPaused: isPaused,
            pauseAutoResumeAt: appState.pauseManager.pauseState.expirationDate,
            serverURL: appState.config.serverURL,
            serverConfigured: appState.config.isUploadConfigured,
            segmentTimeRemainingSeconds: appState.isRecording ? appState.captureManager.segmentTimeRemaining : nil,
            pendingUploadCount: appState.uploadCoordinator.pendingCount,
            lastSyncedAt: appState.uploadCoordinator.lastSyncedAt,
            lastError: appState.errorMessage ?? appState.uploadCoordinator.lastError,
            appVersion: versionInfo.appVersion,
            appBuild: versionInfo.appBuild
        )
    }

    private func buildVersionInfo() -> VersionInfo {
        let infoDictionary = Bundle.main.infoDictionary
        let appVersion = infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let appBuild = infoDictionary?["CFBundleVersion"] as? String ?? ""
        return VersionInfo(
            appVersion: appVersion,
            appBuild: appBuild,
            cliVersion: appVersion,
            cliBuild: appBuild
        )
    }

    private func commandKind(for command: IPCCommand) -> String {
        switch command {
        case .ping: return "ping"
        case .status: return "status"
        case .start: return "start"
        case .stop: return "stop"
        case .pause: return "pause"
        case .unpause: return "unpause"
        case .syncNow: return "syncNow"
        case .openSettings: return "openSettings"
        case .reloadConfig: return "reloadConfig"
        case .versionInfo: return "versionInfo"
        }
    }
}
