// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum MainState: Sendable, Equatable {
    case detecting
    case awaitingChoice(existingInstall: Bool)
    case cleaningUp(SubprocessProgress)
    case installingSolstone(SubprocessProgress)
    case runningSolSetup(SubprocessProgress)
    case registering(SubprocessProgress)
    case externallyManaged(solPath: String)
    case done
    case failed(FailedState)
}

public enum CleanupStep: String, Sendable, Equatable, CaseIterable {
    case resolveJournal = "resolve-journal"
    case serviceUninstall = "service-uninstall"
    case waitForDeath = "wait-for-death"
    case orphanSweep = "orphan-sweep"
    case ports

    public var displayName: String {
        switch self {
        case .resolveJournal:
            return "resolve journal"
        case .serviceUninstall:
            return "stop journal"
        case .waitForDeath:
            return "wait for journal to stop"
        case .orphanSweep:
            return "clear leftover processes"
        case .ports:
            return "check ports"
        }
    }
}

public enum ModelsProgress: Sendable, Equatable {
    case idle
    case running(SubprocessProgress)
    case done
    case failed(message: String)
}

public struct SubprocessProgress: Sendable, Equatable {
    public var phase: String
    public var renderedLog: String
    public var stdoutTail: String
    public var currentStep: String?
    public var stepIndex: Int?
    public var stepTotal: Int?

    public init(
        phase: String,
        renderedLog: String = "",
        stdoutTail: String = "",
        currentStep: String? = nil,
        stepIndex: Int? = nil,
        stepTotal: Int? = nil
    ) {
        self.phase = phase
        self.renderedLog = renderedLog
        self.stdoutTail = stdoutTail
        self.currentStep = currentStep
        self.stepIndex = stepIndex
        self.stepTotal = stepTotal
    }
}

public enum FailedState: Sendable, Equatable {
    case cleanup(step: CleanupStep, message: String)
    case installSolstone(message: String)
    case solSetup(errorCode: String?, message: String)
    case installModels(message: String)
    case registering(message: String)
    case upgradeCutoverFailed(message: String)
}

public enum ErrorCategory: Sendable, Equatable {
    case network
    case disk
    case permission
    case subprocessLaunch
    case unknown
}

public enum ExistingInstallChoice: Sendable, Equatable {
    case createFresh
    case acceptExisting
}

public struct UpgradeFailureRecord: Codable, Equatable, Sendable {
    public let installed: String?
    public let pinned: String
    public let errorDetails: String

    public init(installed: String?, pinned: String, errorDetails: String) {
        self.installed = installed
        self.pinned = pinned
        self.errorDetails = errorDetails
    }
}
