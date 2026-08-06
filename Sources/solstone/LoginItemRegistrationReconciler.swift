// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import os

internal struct LoginItemRegistrationReceipt: Codable, Equatable, Sendable {
    let bundlePath: String
    let build: Int
}

internal enum LoginItemRegistrationReceiptRead: Equatable, Sendable {
    case found(LoginItemRegistrationReceipt)
    case absent
    case failed
}

internal protocol LoginItemRegistrationReceiptStoring: Sendable {
    func read() -> LoginItemRegistrationReceiptRead
    func write(_ receipt: LoginItemRegistrationReceipt)
    func clear()
}

internal final class UserDefaultsLoginItemRegistrationReceiptStore: LoginItemRegistrationReceiptStoring, @unchecked Sendable {
    static let storageKey = "loginItemRegistrationReceipt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read() -> LoginItemRegistrationReceiptRead {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return .absent
        }
        do {
            return .found(try JSONDecoder().decode(LoginItemRegistrationReceipt.self, from: data))
        } catch {
            return .failed
        }
    }

    func write(_ receipt: LoginItemRegistrationReceipt) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

internal final class InMemoryLoginItemRegistrationReceiptStore: LoginItemRegistrationReceiptStoring, @unchecked Sendable {
    private var readResult: LoginItemRegistrationReceiptRead

    init(readResult: LoginItemRegistrationReceiptRead = .absent) {
        self.readResult = readResult
    }

    func read() -> LoginItemRegistrationReceiptRead {
        readResult
    }

    func write(_ receipt: LoginItemRegistrationReceipt) {
        readResult = .found(receipt)
    }

    func clear() {
        readResult = .absent
    }
}

internal enum LoginItemRegistrationPresence: String, Codable, Equatable, Sendable {
    case present
    case absent
    case unknown
}

internal enum LoginItemRegistrationReconciliationCause: String, Codable, Equatable, Sendable {
    case reconciled
    case adoptedExistingReceiptAbsent
    case receiptMatches
    case skippedDeveloperBypass
    case skippedPlacementRepair
    case skippedRequiresApproval
    case skippedNotRegistered
    case skippedNotFound
    case skippedUnrecognizedStatus
    case skippedRunningBundleUnversionable
    case skippedReceiptUnreadable
    case unregisterFailed
    case unregisterTimedOut
    case registerFailed
    case registerDidNotBecomeEnabled
}

internal struct LoginItemRegistrationReconciliationState: Codable, Equatable, Sendable {
    let cause: LoginItemRegistrationReconciliationCause
    let receiptBundlePath: String?
    let receiptBuild: Int?
    let runningBundlePath: String?
    let runningBuild: Int?
    let registrationPresence: LoginItemRegistrationPresence
}

internal enum LoginItemRegistrationReconciliationStateRead: Equatable, Sendable {
    case found(LoginItemRegistrationReconciliationState)
    case absent
    case failed
}

internal protocol LoginItemRegistrationReconciliationStateStoring: Sendable {
    func read() -> LoginItemRegistrationReconciliationStateRead
    func write(_ state: LoginItemRegistrationReconciliationState)
    func clear()
}

internal final class UserDefaultsLoginItemRegistrationReconciliationStateStore: LoginItemRegistrationReconciliationStateStoring, @unchecked Sendable {
    static let storageKey = "loginItemRegistrationReconciliationState"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func read() -> LoginItemRegistrationReconciliationStateRead {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return .absent
        }
        do {
            return .found(try JSONDecoder().decode(LoginItemRegistrationReconciliationState.self, from: data))
        } catch {
            return .failed
        }
    }

    func write(_ state: LoginItemRegistrationReconciliationState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}

internal final class InMemoryLoginItemRegistrationReconciliationStateStore: LoginItemRegistrationReconciliationStateStoring, @unchecked Sendable {
    private var readResult: LoginItemRegistrationReconciliationStateRead

    init(readResult: LoginItemRegistrationReconciliationStateRead = .absent) {
        self.readResult = readResult
    }

    func read() -> LoginItemRegistrationReconciliationStateRead {
        readResult
    }

    func write(_ state: LoginItemRegistrationReconciliationState) {
        readResult = .found(state)
    }

    func clear() {
        readResult = .absent
    }
}

@MainActor
internal final class LoginItemRegistrationReconciler {
    static let unregisterTimeoutSeconds: TimeInterval = 10

    private let loginService: any LoginItemService
    private let receiptStore: any LoginItemRegistrationReceiptStoring
    private let stateStore: any LoginItemRegistrationReconciliationStateStoring
    private let placementDecision: AppPlacementDecision
    private let runningBundleURL: URL
    private let versionReader: (URL) throws -> SolstoneBundleVersion
    private let unregisterTimeoutSeconds: TimeInterval
    private var hasReconciled = false

    init(
        loginService: any LoginItemService,
        receiptStore: any LoginItemRegistrationReceiptStoring,
        stateStore: any LoginItemRegistrationReconciliationStateStoring,
        placementDecision: AppPlacementDecision,
        runningBundleURL: URL,
        versionReader: @escaping (URL) throws -> SolstoneBundleVersion,
        unregisterTimeoutSeconds: TimeInterval = LoginItemRegistrationReconciler.unregisterTimeoutSeconds
    ) {
        self.loginService = loginService
        self.receiptStore = receiptStore
        self.stateStore = stateStore
        self.placementDecision = placementDecision
        self.runningBundleURL = runningBundleURL
        self.versionReader = versionReader
        self.unregisterTimeoutSeconds = unregisterTimeoutSeconds
    }

    func reconcileIfNeeded() async {
        guard !hasReconciled else { return }
        hasReconciled = true

        switch placementDecision {
        case .allowed(.developerBypass):
            recordPlacementSkip(cause: .skippedDeveloperBypass)
            return
        case .repair:
            recordPlacementSkip(cause: .skippedPlacementRepair)
            return
        case .allowed(.canonical):
            break
        }

        let runningBundlePath = runningBundleURL.path
        let runningVersion: SolstoneBundleVersion
        do {
            runningVersion = try versionReader(runningBundleURL)
        } catch {
            Logger.setup.error("Login item registration reconciliation skipped: running bundle version unavailable: \(String(describing: error), privacy: .public)")
            record(
                cause: .skippedRunningBundleUnversionable,
                receipt: nil,
                runningBundlePath: runningBundlePath,
                runningVersion: nil,
                presence: .unknown
            )
            return
        }

        let receipt: LoginItemRegistrationReceipt
        switch receiptStore.read() {
        case .found(let found):
            receipt = found
        case .absent:
            await reconcileEnabledRegistration(
                receipt: nil,
                runningBundlePath: runningBundlePath,
                runningVersion: runningVersion
            )
            return
        case .failed:
            Logger.setup.error("Login item registration reconciliation skipped: stored receipt unreadable")
            record(
                cause: .skippedReceiptUnreadable,
                receipt: nil,
                runningBundlePath: runningBundlePath,
                runningVersion: runningVersion,
                presence: .unknown
            )
            return
        }

        await reconcileEnabledRegistration(
            receipt: receipt,
            runningBundlePath: runningBundlePath,
            runningVersion: runningVersion
        )
    }

    private func reconcileEnabledRegistration(
        receipt: LoginItemRegistrationReceipt?,
        runningBundlePath: String,
        runningVersion: SolstoneBundleVersion
    ) async {
        let status = loginService.watchdogStatus
        switch status {
        case .requiresApproval:
            record(cause: .skippedRequiresApproval, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .present)
        case .notRegistered:
            record(cause: .skippedNotRegistered, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .absent)
        case .notFound:
            record(cause: .skippedNotFound, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .absent)
        case .enabled:
            guard let receipt else {
                let adopted = currentReceipt(bundlePath: runningBundlePath, version: runningVersion)
                receiptStore.write(adopted)
                record(cause: .adoptedExistingReceiptAbsent, receipt: adopted, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .present)
                return
            }
            guard receipt.bundlePath != runningBundlePath || receipt.build != runningVersion.build else {
                record(cause: .receiptMatches, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .present)
                return
            }
            await reregister(receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion)
        @unknown default:
            record(cause: .skippedUnrecognizedStatus, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .unknown)
        }
    }

    private func reregister(
        receipt: LoginItemRegistrationReceipt,
        runningBundlePath: String,
        runningVersion: SolstoneBundleVersion
    ) async {
        do {
            try await withTimeout(seconds: unregisterTimeoutSeconds) { @MainActor [loginService] in
                try await loginService.unregisterWatchdogAwaitingCompletion()
            }
        } catch is TimeoutError {
            Logger.setup.error("Login item registration reconciliation timed out waiting for watchdog unregister")
            record(cause: .unregisterTimedOut, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .unknown)
            return
        } catch {
            Logger.setup.error("Login item registration reconciliation failed to unregister watchdog: \(String(describing: error), privacy: .public)")
            record(cause: .unregisterFailed, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .present)
            return
        }

        do {
            try loginService.registerWatchdog()
        } catch {
            Logger.setup.error("Login item registration reconciliation failed to register watchdog: \(String(describing: error), privacy: .public)")
            record(cause: .registerFailed, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .absent)
            return
        }

        guard loginService.watchdogStatus == .enabled else {
            Logger.setup.error("Login item registration reconciliation failed: watchdog did not become enabled")
            record(cause: .registerDidNotBecomeEnabled, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .unknown)
            return
        }

        let updatedReceipt = currentReceipt(bundlePath: runningBundlePath, version: runningVersion)
        receiptStore.write(updatedReceipt)
        record(cause: .reconciled, receipt: updatedReceipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .present)
    }

    private func recordPlacementSkip(cause: LoginItemRegistrationReconciliationCause) {
        let runningBundlePath = runningBundleURL.path
        let runningVersion = try? versionReader(runningBundleURL)
        let receipt: LoginItemRegistrationReceipt?
        if case .found(let found) = receiptStore.read() {
            receipt = found
        } else {
            receipt = nil
        }
        record(cause: cause, receipt: receipt, runningBundlePath: runningBundlePath, runningVersion: runningVersion, presence: .unknown)
    }

    private func currentReceipt(bundlePath: String, version: SolstoneBundleVersion) -> LoginItemRegistrationReceipt {
        LoginItemRegistrationReceipt(bundlePath: bundlePath, build: version.build)
    }

    private func record(
        cause: LoginItemRegistrationReconciliationCause,
        receipt: LoginItemRegistrationReceipt?,
        runningBundlePath: String?,
        runningVersion: SolstoneBundleVersion?,
        presence: LoginItemRegistrationPresence
    ) {
        stateStore.write(LoginItemRegistrationReconciliationState(
            cause: cause,
            receiptBundlePath: receipt?.bundlePath,
            receiptBuild: receipt?.build,
            runningBundlePath: runningBundlePath,
            runningBuild: runningVersion?.build,
            registrationPresence: presence
        ))
    }
}
