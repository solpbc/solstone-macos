// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Darwin
import Foundation
import os
import SolstoneCore

enum AppPlacementAlertCopy {
    static let repairTitle = "install sol in Applications"
    static let repairBody = "macOS is running sol from a temporary location, so it can't remember screen recording permission. install sol in Applications and it will reopen."
    static let repairPrimaryButton = "install and reopen"
    static let repairSecondaryButton = "quit sol"
    static let fallbackTitle = "sol couldn't move itself"
    static let fallbackBody = "move solstone.app to Applications in Finder, then open it there."
    static let fallbackPrimaryButton = "open Applications"
    static let fallbackSecondaryButton = "quit sol"
}

enum AppPlacementRepairOutcome: Equatable {
    case reopenedExisting(URL)
    case reopenedInstalled(URL)
}

enum AppPlacementRepairFailure: Error, Equatable {
    case applicationsDirectoryUnavailable
    case applicationsDirectoryUnwritable
    case runningBundleUnversionable(String)
    case existingDestinationUntrusted(String)
    case existingDestinationUnversionable(String)
    case copyFailed(String)
    case trustFailed(String)
    case quarantineClearFailed(String)
    case atomicReplaceFailed(String)
    case markerFailed(String)
    case spawnFailed(String)
}

struct AppPlacementRepairDependencies {
    var applicationsURL: URL
    var processID: () -> Int32
    var uuid: () -> UUID
    var directoryExists: (URL) -> Bool
    var isWritableDirectory: (URL) -> Bool
    var fileExists: (URL) -> Bool
    var removeItem: (URL) throws -> Void
    var moveItem: (URL, URL) throws -> Void
    var replaceItemAt: (_ originalItemURL: URL, _ replacementItemURL: URL, _ backupItemName: String) throws -> URL
    var restoreBackup: (_ backupURL: URL, _ destinationURL: URL) throws -> Void
    var copyBundle: (_ sourceURL: URL, _ destinationURL: URL) throws -> Void
    var trustVerifier: (URL) throws -> Void
    var versionReader: (URL) throws -> SolstoneBundleVersion
    var quarantineCleaner: (URL) throws -> Void
    var markerWriter: (_ reason: String, _ pid: Int32) throws -> ExpectedExitMarker
    var reopenLauncher: (_ predecessorPID: Int32, _ targetBundleURL: URL) throws -> Void
    var openApplicationsFolder: (URL) -> Void
    var logger: (String) -> Void

    static func live(applicationsURL: URL) -> AppPlacementRepairDependencies {
        let fileManager = FileManager.default
        return AppPlacementRepairDependencies(
            applicationsURL: applicationsURL,
            processID: { getpid() },
            uuid: { UUID() },
            directoryExists: { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            isWritableDirectory: { url in
                fileManager.isWritableFile(atPath: url.path)
            },
            fileExists: { url in
                fileManager.fileExists(atPath: url.path)
            },
            removeItem: { url in
                try fileManager.removeItem(at: url)
            },
            moveItem: { source, destination in
                try fileManager.moveItem(at: source, to: destination)
            },
            replaceItemAt: { originalItemURL, replacementItemURL, backupItemName in
                // Rollback after marker/spawn failure restores from this backup, so the OS must not auto-delete it.
                _ = try fileManager.replaceItemAt(
                    originalItemURL,
                    withItemAt: replacementItemURL,
                    backupItemName: backupItemName,
                    options: [.withoutDeletingBackupItem]
                )
                return originalItemURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(backupItemName, isDirectory: true)
            },
            restoreBackup: { backupURL, destinationURL in
                if fileManager.fileExists(atPath: destinationURL.path) {
                    _ = try fileManager.replaceItemAt(
                        destinationURL,
                        withItemAt: backupURL,
                        backupItemName: nil,
                        options: []
                    )
                    return
                } else {
                    try fileManager.moveItem(at: backupURL, to: destinationURL)
                }
            },
            copyBundle: { sourceURL, destinationURL in
                let result = try SolstoneProcessRunner.run(
                    executable: "/usr/bin/ditto",
                    arguments: [sourceURL.path, destinationURL.path]
                )
                try result.throwIfFailed("ditto")
            },
            trustVerifier: { url in
                try SolstoneTrustVerifier().verifySolstoneApp(at: url)
            },
            versionReader: { url in
                try SolstoneBundleVersionReader.read(fromBundleAt: url)
            },
            quarantineCleaner: { url in
                try LivePlacementQuarantineCleaner.clearRecursively(at: url, fileManager: fileManager)
            },
            markerWriter: { reason, pid in
                try ExpectedExitMarker.writeAndVerifyExpectedExit(reason: reason, pid: pid)
            },
            reopenLauncher: { predecessorPID, targetBundleURL in
                let command = PlacementReopenLauncher.command(
                    predecessorPID: predecessorPID,
                    targetBundlePath: targetBundleURL.path
                )
                try PlacementReopenLauncher.runDetached(command)
            },
            openApplicationsFolder: { url in
                NSWorkspace.shared.open(url)
            },
            logger: { message in
                Logger.setup.error("\(message, privacy: .public)")
            }
        )
    }
}

struct AppPlacementRepairService {
    static let expectedExitReason = "placement-repair"

    let dependencies: AppPlacementRepairDependencies

    func repair(context: AppPlacementContext) throws -> AppPlacementRepairOutcome {
        guard dependencies.directoryExists(dependencies.applicationsURL) else {
            throw AppPlacementRepairFailure.applicationsDirectoryUnavailable
        }

        let runningVersion: SolstoneBundleVersion
        do {
            runningVersion = try dependencies.versionReader(context.runningBundleURL)
        } catch {
            throw AppPlacementRepairFailure.runningBundleUnversionable(describe(error))
        }

        if dependencies.fileExists(context.canonicalBundleURL) {
            do {
                try dependencies.trustVerifier(context.canonicalBundleURL)
            } catch {
                throw AppPlacementRepairFailure.existingDestinationUntrusted(describe(error))
            }

            let installedVersion: SolstoneBundleVersion
            do {
                installedVersion = try dependencies.versionReader(context.canonicalBundleURL)
            } catch {
                throw AppPlacementRepairFailure.existingDestinationUnversionable(describe(error))
            }

            if installedVersion >= runningVersion {
                try writeMarkerThenLaunch(targetBundleURL: context.canonicalBundleURL)
                return .reopenedExisting(context.canonicalBundleURL)
            }

            guard dependencies.isWritableDirectory(dependencies.applicationsURL) else {
                throw AppPlacementRepairFailure.applicationsDirectoryUnwritable
            }
            try installRunningBundleReplacingCanonical(context: context)
            return .reopenedInstalled(context.canonicalBundleURL)
        }

        guard dependencies.isWritableDirectory(dependencies.applicationsURL) else {
            throw AppPlacementRepairFailure.applicationsDirectoryUnwritable
        }
        try installRunningBundleAtEmptyCanonical(context: context)
        return .reopenedInstalled(context.canonicalBundleURL)
    }

    private func installRunningBundleAtEmptyCanonical(context: AppPlacementContext) throws {
        let stageURL = try nextStageURL(in: context.applicationsURL)

        do {
            try copyTrustAndClearQuarantine(sourceURL: context.runningBundleURL, stageURL: stageURL)
            try dependencies.moveItem(stageURL, context.canonicalBundleURL)
        } catch let failure as AppPlacementRepairFailure {
            removeIfExists(stageURL)
            throw failure
        } catch {
            removeIfExists(stageURL)
            throw AppPlacementRepairFailure.atomicReplaceFailed(describe(error))
        }

        do {
            try writeMarkerThenLaunch(targetBundleURL: context.canonicalBundleURL)
        } catch let failure as AppPlacementRepairFailure {
            removeIfExists(context.canonicalBundleURL)
            throw failure
        } catch {
            removeIfExists(context.canonicalBundleURL)
            throw AppPlacementRepairFailure.spawnFailed(describe(error))
        }
    }

    private func installRunningBundleReplacingCanonical(context: AppPlacementContext) throws {
        let stageURL = try nextStageURL(in: context.applicationsURL)

        do {
            try copyTrustAndClearQuarantine(sourceURL: context.runningBundleURL, stageURL: stageURL)
        } catch let failure as AppPlacementRepairFailure {
            removeIfExists(stageURL)
            throw failure
        } catch {
            removeIfExists(stageURL)
            throw AppPlacementRepairFailure.copyFailed(describe(error))
        }

        let backupName = ".solstone-placement-backup-\(dependencies.uuid().uuidString).app"
        let backupURL: URL
        do {
            backupURL = try dependencies.replaceItemAt(context.canonicalBundleURL, stageURL, backupName)
        } catch {
            removeIfExists(stageURL)
            throw AppPlacementRepairFailure.atomicReplaceFailed(describe(error))
        }

        do {
            try writeMarkerThenLaunch(targetBundleURL: context.canonicalBundleURL)
        } catch let failure as AppPlacementRepairFailure {
            rollbackReplacement(backupURL: backupURL, destinationURL: context.canonicalBundleURL)
            throw failure
        } catch {
            rollbackReplacement(backupURL: backupURL, destinationURL: context.canonicalBundleURL)
            throw AppPlacementRepairFailure.spawnFailed(describe(error))
        }

        removeIfExists(backupURL)
    }

    private func copyTrustAndClearQuarantine(sourceURL: URL, stageURL: URL) throws {
        do {
            try dependencies.copyBundle(sourceURL, stageURL)
        } catch {
            throw AppPlacementRepairFailure.copyFailed(describe(error))
        }

        do {
            try dependencies.trustVerifier(stageURL)
        } catch {
            throw AppPlacementRepairFailure.trustFailed(describe(error))
        }

        do {
            try dependencies.quarantineCleaner(stageURL)
        } catch {
            throw AppPlacementRepairFailure.quarantineClearFailed(describe(error))
        }
    }

    private func writeMarkerThenLaunch(targetBundleURL: URL) throws {
        let pid = dependencies.processID()
        do {
            _ = try dependencies.markerWriter(Self.expectedExitReason, pid)
        } catch {
            throw AppPlacementRepairFailure.markerFailed(describe(error))
        }

        do {
            try dependencies.reopenLauncher(pid, targetBundleURL)
        } catch {
            throw AppPlacementRepairFailure.spawnFailed(describe(error))
        }
    }

    private func nextStageURL(in applicationsURL: URL) throws -> URL {
        for _ in 0..<20 {
            let candidate = applicationsURL
                .appendingPathComponent(".solstone-placement-\(dependencies.uuid().uuidString).app", isDirectory: true)
            if !dependencies.fileExists(candidate) {
                return candidate
            }
        }
        throw AppPlacementRepairFailure.copyFailed("could not allocate unique staging path")
    }

    private func rollbackReplacement(backupURL: URL, destinationURL: URL) {
        do {
            try dependencies.restoreBackup(backupURL, destinationURL)
        } catch {
            dependencies.logger("placement repair rollback failed: \(describe(error))")
        }
    }

    private func removeIfExists(_ url: URL) {
        guard dependencies.fileExists(url) else { return }
        do {
            try dependencies.removeItem(url)
        } catch {
            dependencies.logger("placement repair cleanup failed: \(url.path) \(describe(error))")
        }
    }

    private func describe(_ error: Error) -> String {
        String(describing: error)
    }
}

enum AppPlacementTerminalAction: Equatable {
    case exitSuccess
    case quitWithoutRepair
    case presentFallback
}

@MainActor
enum AppPlacementRepairTerminal {
    nonisolated static func plan(
        userChoseInstall: Bool,
        repairSucceeded: Bool
    ) -> AppPlacementTerminalAction {
        guard userChoseInstall else { return .quitWithoutRepair }
        return repairSucceeded ? .exitSuccess : .presentFallback
    }

    static func run(context: AppPlacementContext) -> Never {
        run(
            context: context,
            dependencies: AppPlacementRepairDependencies.live(applicationsURL: context.applicationsURL)
        )
    }

    static func run(
        context: AppPlacementContext,
        dependencies: AppPlacementRepairDependencies
    ) -> Never {
        NSApp.activate(ignoringOtherApps: true)

        let repairResponse = presentRepairAlert()
        let userChoseInstall = repairResponse == .alertFirstButtonReturn
        let repairSucceeded: Bool
        if userChoseInstall {
            do {
                _ = try AppPlacementRepairService(dependencies: dependencies).repair(context: context)
                repairSucceeded = true
            } catch {
                dependencies.logger("placement repair failed: \(String(describing: error))")
                repairSucceeded = false
            }
        } else {
            repairSucceeded = false
        }

        switch plan(userChoseInstall: userChoseInstall, repairSucceeded: repairSucceeded) {
        case .exitSuccess:
            Darwin.exit(EXIT_SUCCESS)
        case .quitWithoutRepair:
            markFallbackExit()
            Darwin.exit(EXIT_SUCCESS)
        case .presentFallback:
            let fallbackResponse = presentFallbackAlert()
            if fallbackResponse == .alertFirstButtonReturn {
                dependencies.openApplicationsFolder(context.applicationsURL)
            }
            markFallbackExit()
            Darwin.exit(EXIT_SUCCESS)
        }
    }

    private static func presentRepairAlert() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppPlacementAlertCopy.repairTitle
        alert.informativeText = AppPlacementAlertCopy.repairBody
        alert.addButton(withTitle: AppPlacementAlertCopy.repairPrimaryButton)
        alert.addButton(withTitle: AppPlacementAlertCopy.repairSecondaryButton)
        return alert.runModal()
    }

    private static func presentFallbackAlert() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppPlacementAlertCopy.fallbackTitle
        alert.informativeText = AppPlacementAlertCopy.fallbackBody
        alert.addButton(withTitle: AppPlacementAlertCopy.fallbackPrimaryButton)
        alert.addButton(withTitle: AppPlacementAlertCopy.fallbackSecondaryButton)
        return alert.runModal()
    }

    private static func markFallbackExit() {
        ExpectedExitMarker.markExpectedExit(reason: AppPlacementRepairService.expectedExitReason)
    }
}

private enum LivePlacementQuarantineCleaner {
    static func clearRecursively(at url: URL, fileManager: FileManager) throws {
        try clearQuarantine(at: url)

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.quarantinePropertiesKey]
        ) else {
            return
        }

        for case let childURL as URL in enumerator {
            try clearQuarantine(at: childURL)
        }
    }

    private static func clearQuarantine(at url: URL) throws {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.quarantineProperties = nil
        try mutableURL.setResourceValues(resourceValues)
    }
}
