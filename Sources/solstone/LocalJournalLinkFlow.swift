// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import os
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
    hasPersistedPairing: Bool,
    localDiscoveryCompleted: Bool,
    journalPathIsValid: Bool
) -> Bool {
    (!isUploadConfigured || !journalPathIsValid) && !hasPersistedPairing && !localDiscoveryCompleted
}

func shouldReprobeLocalJournalOnReturn(
    showsConfiguredJournal: Bool,
    hasPersistedPairing: Bool,
    runningJournalFound: Bool,
    localLinkInProgress: Bool,
    freshJournalWaiting: Bool,
    discoveryInFlight: Bool,
    lastProbeFinishedAt: Date?,
    now: Date
) -> Bool {
    guard !showsConfiguredJournal,
          !hasPersistedPairing,
          !runningJournalFound,
          !localLinkInProgress,
          !freshJournalWaiting,
          !discoveryInFlight
    else {
        return false
    }
    if let lastProbeFinishedAt, now.timeIntervalSince(lastProbeFinishedAt) < 2 {
        return false
    }
    return true
}

func reprobedLocalJournalPanelModel(
    current: LocalJournalDiscoveryPanelModel,
    probeResult: LocalJournalDiscoveryPanelModel
) -> LocalJournalDiscoveryPanelModel {
    if case .foundRunning = current {
        return current
    }
    switch probeResult {
    case .foundRunning:
        return probeResult
    case .none:
        return current
    case .foundOnDisk:
        if case .foundOnDisk = current {
            return probeResult
        }
        return current
    }
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
    appState.beginOwnerPairingAttempt()
}

/// What re-link or confirm tells the owner when it ends, and the code diagnostics keep for it.
/// A link that landed says nothing here: the mark question follows it.
struct SameMachineLinkOutcome: Equatable {
    enum Tone: Equatable {
        case notice
        case error
    }

    let message: String?
    let tone: Tone
    /// The journal answered but would not link this way, so a pasted pairing link is the way on.
    let offersPairingLink: Bool
    let evidence: DiagnosticEvidenceCode
}

func sameMachineLinkOutcome(
    for result: SameMachineHomePairingResult,
    failedAddress: String?
) -> SameMachineLinkOutcome {
    switch result {
    case .pairingStarted:
        return SameMachineLinkOutcome(message: nil, tone: .notice, offersPairingLink: false, evidence: .pairingSameMachinePaired)
    case .notEligible:
        return SameMachineLinkOutcome(
            message: UICopy.SAME_MACHINE_LINK_ALREADY_LINKED,
            tone: .notice,
            offersPairingLink: false,
            evidence: .pairingSameMachineAlreadyLinked
        )
    case .failed(let failure):
        return sameMachineLinkFailureOutcome(failure, failedAddress: failedAddress)
    }
}

private func sameMachineLinkFailureOutcome(
    _ failure: SameMachineHomePairingFailure,
    failedAddress: String?
) -> SameMachineLinkOutcome {
    func error(_ message: String, offersPairingLink: Bool = false, _ evidence: DiagnosticEvidenceCode) -> SameMachineLinkOutcome {
        SameMachineLinkOutcome(message: message, tone: .error, offersPairingLink: offersPairingLink, evidence: evidence)
    }

    switch failure {
    case .pairStart(.transport), .pairStart(.httpStatus(503)):
        return error(UICopy.SAME_MACHINE_LINK_UNREACHABLE, .pairingSameMachineUnreachable)
    case .pairStart(.httpStatus(let status)) where (400..<500).contains(status):
        return error(UICopy.SAME_MACHINE_LINK_REFUSED, offersPairingLink: true, .pairingSameMachineRefused)
    case .pairStart, .linkShape:
        return error(UICopy.SAME_MACHINE_LINK_UNEXPECTED, offersPairingLink: true, .pairingSameMachineUnexpectedAnswer)
    case .ceremony(.failed(let pairingFailure)):
        return error(pairingFailure.message(address: failedAddress), .pairingSameMachineCeremonyFailed)
    case .ceremony(.saveFailed):
        return error(UICopy.PAIRING_SAVE_FAILED, .pairingSameMachineSaveFailed)
    case .ceremony:
        return error(UICopy.SAME_MACHINE_LINK_UNFINISHED, .pairingSameMachineCeremonyFailed)
    case .pairingUnavailable:
        return error(UICopy.SAME_MACHINE_LINK_CREDENTIALS_UNAVAILABLE, .pairingSameMachineCredentialsUnavailable)
    case .differentHomeAlreadyPaired:
        return error(UICopy.SAME_MACHINE_LINK_OTHER_JOURNAL, .pairingSameMachineOtherJournalPaired)
    }
}

/// The owner's re-link or confirm for the journal on this Mac, end to end except for what the
/// settings pane shows. The mark question is owed again, the attempt and its ending are kept for
/// diagnostics, and a Mac that turns out to be linked already re-asks a mark still unanswered.
@MainActor
func runOwnerSameMachineLink(
    appState: AppState,
    journalMarkDriver: JournalMarkConfirmationDriver,
    startPairing: @escaping @MainActor @Sendable (
        _ baseURL: String,
        _ deviceLabel: String
    ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure>
) async -> SameMachineLinkOutcome {
    resetForJournalRelink(appState: appState, journalMarkDriver: journalMarkDriver)
    appState.recordDiagnosticEvidence(.pairingSameMachineStarted)

    let result = await performSameMachineHomePairing(
        baseURL: ServiceMode.bundledServiceURL,
        existingPairing: appState.tunnelLifecycleOwner.sameMachineStoredPairingState,
        startPairing: startPairing,
        submitPairingLink: { exactPairLink in
            await appState.pairingCoordinator.submitPairingLink(exactPairLink)
            return appState.pairingCoordinator.state
        }
    )

    let outcome = sameMachineLinkOutcome(for: result, failedAddress: appState.pairingCoordinator.failedAddress)
    appState.recordDiagnosticEvidence(outcome.evidence)
    switch result {
    case .pairingStarted:
        break
    case .notEligible:
        journalMarkDriver.startIfUnconfirmed(appState: appState)
    case .failed(let failure):
        Logger.setup.notice("same-machine link did not complete: \(String(describing: failure), privacy: .public)")
    }
    return outcome
}

/// How a pasted pairing link ended, for diagnostics. A switch still waiting on the owner has
/// not ended, so it keeps no code.
func pairingLinkEvidence(for state: PairingFlowState) -> DiagnosticEvidenceCode? {
    switch state {
    case .paired, .alreadyConnected, .switched:
        return .pairingLinkPaired
    case .failed:
        return .pairingLinkFailed
    case .saveFailed:
        return .pairingLinkSaveFailed
    case .idle, .pairing, .switchConfirmPending:
        return nil
    }
}

/// Where a saved journal address sends, as host and port only, for owner copy.
func journalAddressForOwner(_ serverURL: String?) -> String? {
    guard let serverURL,
          let components = URLComponents(string: serverURL),
          let host = components.host,
          !host.isEmpty else {
        return nil
    }
    guard let port = components.port else {
        return host
    }
    return "\(host):\(port)"
}

func resolvedJournalDisplayName(
    isConfirmed: Bool,
    mark: JournalMark?
) -> String {
    guard isConfirmed else {
        return UICopy.SETTINGS_SETUP_JOURNAL_LINK_LABEL
    }
    if let mark {
        return JournalMarkSlot.join(mark.words)
    }
    return JournalMarkUnavailable.slot
}
