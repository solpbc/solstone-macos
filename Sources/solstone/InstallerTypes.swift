// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum MainState: Sendable, Equatable {
    case detecting
    case awaitingChoice(existingInstall: Bool)
    case installingSolstone(SubprocessProgress)
    case runningSolSetup(SubprocessProgress)
    case registering(SubprocessProgress)
    case done
    case failed(FailedState)
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
    case installSolstone(message: String)
    case solSetup(errorCode: String?, message: String)
    case installModels(message: String)
    case registering(message: String)
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
