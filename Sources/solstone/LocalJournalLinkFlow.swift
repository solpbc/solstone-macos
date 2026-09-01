// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import SolstoneCore

enum LocalJournalDiscoveryResult: Equatable {
    case found(JournalMark)
    case fork
}

enum OnDiskJournalDiscovery: Equatable {
    case none
    case found(path: String)
}

enum LocalJournalDiscoveryPanelModel: Equatable {
    case none
    case foundRunning(JournalMark)
    case foundOnDisk(path: String)
}

protocol SolstoneUserConfigReading: Sendable {
    func readConfigToml() async -> String?
}

struct LiveSolstoneUserConfigReader: SolstoneUserConfigReading {
    func readConfigToml() async -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("solstone", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

func isJournalPathValid(_ journalPath: String?, fileManager: FileManager = .default) -> Bool {
    guard let journalPath = journalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
          !journalPath.isEmpty
    else {
        return false
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: journalPath, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
        return false
    }
    return true
}

func shouldProbeLocalJournal(
    isUploadConfigured: Bool,
    isTunnelManaged: Bool,
    localDiscoveryCompleted: Bool,
    journalPathIsValid: Bool
) -> Bool {
    (!isUploadConfigured || !journalPathIsValid) && !isTunnelManaged && !localDiscoveryCompleted
}

@MainActor
func discoverLocalJournal(
    fetchIdentity: @escaping @MainActor @Sendable (String) async -> JournalMark?
) async -> LocalJournalDiscoveryResult {
    if let mark = await fetchIdentity(ServiceMode.bundledServiceURL) {
        return .found(mark)
    }
    return .fork
}

@MainActor
func discoverLocalJournalPanelModel(
    fetchIdentity: @escaping @MainActor @Sendable (String) async -> JournalMark?,
    onDiskDiscovery: @escaping @MainActor @Sendable () async -> OnDiskJournalDiscovery
) async -> LocalJournalDiscoveryPanelModel {
    let result = await discoverLocalJournal(fetchIdentity: fetchIdentity)
    switch result {
    case .found(let mark):
        return .foundRunning(mark)
    case .fork:
        switch await onDiskDiscovery() {
        case .found(let path):
            return .foundOnDisk(path: path)
        case .none:
            return .none
        }
    }
}

func parseJournalPathFromConfigToml(_ raw: String) -> String? {
    for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        if line.hasPrefix("[") {
            return nil
        }

        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue
        }

        let key = parts[0].trimmingCharacters(in: .whitespaces)
        guard key == "journal" else {
            continue
        }

        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard let parsed = parseBasicTOMLString(value) else {
            return nil
        }
        return standardizedJournalPath(parsed)
    }

    return nil
}

func discoverOnDiskJournal(
    configReader: SolstoneUserConfigReading = LiveSolstoneUserConfigReader(),
    fileReader: OnDiskJournalFileReading = LiveOnDiskJournalFileReader(),
    timeout: TimeInterval = 1.0
) async -> OnDiskJournalDiscovery {
    var candidates: [String] = []
    if let rawConfig = await configReader.readConfigToml(),
       let configuredPath = parseJournalPathFromConfigToml(rawConfig) {
        candidates.append(configuredPath)
    }

    let defaultPath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("journal", isDirectory: true)
        .standardizedFileURL
        .path
    if !candidates.contains(defaultPath) {
        candidates.append(defaultPath)
    }

    for candidate in candidates {
        do {
            let qualifies = try await withTimeout(seconds: timeout) {
                await journalDirectoryQualifies(at: candidate, using: fileReader)
            }
            if qualifies {
                return .found(path: candidate)
            }
        } catch {
            continue
        }
    }

    return .none
}

private func parseBasicTOMLString(_ value: String) -> String? {
    guard value.first == "\"" else {
        return nil
    }

    var result = ""
    var index = value.index(after: value.startIndex)
    var closed = false

    while index < value.endIndex {
        let character = value[index]
        if character == "\\" {
            let escapeIndex = value.index(after: index)
            guard escapeIndex < value.endIndex else {
                return nil
            }
            let escaped = value[escapeIndex]
            switch escaped {
            case "\\":
                result.append("\\")
            case "\"":
                result.append("\"")
            default:
                return nil
            }
            index = value.index(after: escapeIndex)
            continue
        }

        if character == "\"" {
            index = value.index(after: index)
            closed = true
            break
        }

        result.append(character)
        index = value.index(after: index)
    }

    guard closed else {
        return nil
    }

    let trailing = value[index...].trimmingCharacters(in: .whitespaces)
    guard trailing.isEmpty else {
        return nil
    }

    return result
}

private func standardizedJournalPath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, isDirectory: true)
        .standardizedFileURL
        .path
}

@MainActor
func resetForJournalRelink(
    appState: AppState,
    journalMarkDriver: JournalMarkConfirmationDriver
) {
    journalMarkDriver.resetForNewPairAttempt()
    appState.clearConfirmedMark()
}

func resolvedJournalDisplayName(
    fetchedName: String?,
    confirmedMark: JournalMark?,
    serverURL: String?
) -> String {
    if let fetchedName, !fetchedName.isEmpty {
        return fetchedName
    }
    if let confirmedMark {
        return confirmedMark.words.joined(separator: " ")
    }
    return journalHost(serverURL)
}
