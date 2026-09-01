// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import os

@MainActor
struct JournalAppAcquirer {
    var appcastFeedResolver: @MainActor @Sendable () -> JournalHandoffFeedSelection
    var appcastClient: any AppcastClient
    var downloader: any DMGDownloader
    var mounter: any DiskImageMounter
    var trustVerifier: any TrustVerifier
    var publicEDKeyBase64: String
    var maxDMGBytes: Int64
    var applicationsURL: URL
    var fileManager: FileManager
    var runningJournal: any RunningJournalController
    var runningTerminationTimeout: Duration
    var runningTerminationPollInterval: Duration

    static func live(
        defaults: UserDefaults = .standard,
        trustVerifier: any TrustVerifier = LiveTrustVerifier(),
        runningJournal: any RunningJournalController = LiveRunningJournalController()
    ) -> JournalAppAcquirer {
        JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeed.resolve(defaults: defaults) },
            appcastClient: LiveAppcastClient(),
            downloader: LiveDMGDownloader(),
            mounter: LiveDiskImageMounter(),
            trustVerifier: trustVerifier,
            publicEDKeyBase64: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
                ?? JournalHandoffConstants.productionPublicEDKeyBase64,
            maxDMGBytes: JournalHandoffConstants.maxDMGBytes,
            applicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager: .default,
            runningJournal: runningJournal,
            runningTerminationTimeout: .seconds(15),
            runningTerminationPollInterval: .milliseconds(250)
        )
    }

    func acquire(progress: @MainActor (AcquirePhase) -> Void) async throws -> URL {
        progress(.fetchingAppcast)
        let selection = appcastFeedResolver()
        Logger.setup.notice("journal handoff feed: \(selection.feed.logDescription, privacy: .public)")
        Logger.setup.info("journal handoff: fetching journal appcast")
        let appcastData: Data
        do {
            appcastData = try await appcastClient.fetchAppcast(from: selection.url)
        } catch let failure as JournalHandoffFailure {
            throw failure
        } catch {
            throw JournalHandoffFailure.appcastUnavailable(String(describing: error))
        }

        progress(.selectingLatestSparkleVersion)
        let item = try JournalAppcastParser.latestItem(from: appcastData)

        progress(.validatingLength)
        try validateLength(item.length, maxBytes: maxDMGBytes)

        progress(.downloadingDMG)
        let dmgURL = try await downloader.downloadDMG(
            from: item.url,
            expectedLength: item.length,
            maxBytes: maxDMGBytes
        )
        defer { try? fileManager.removeItem(at: dmgURL) }

        do {
            try validateDownloadedLength(fileURL: dmgURL, expectedLength: item.length)

            progress(.verifyingEdDSA)
            try verifyEdDSASignature(
                fileURL: dmgURL,
                signatureBase64: item.edSignature,
                publicKeyBase64: publicEDKeyBase64
            )

            progress(.mountingDMG)
            let mounted = try await mounter.mount(dmgURL: dmgURL)
            do {
                progress(.verifyingJournalAppTrust)
                try await trustVerifier.verifyJournalApp(at: mounted.journalAppURL)

                progress(.installingToApplications)
                let installedURL = try await installJournalApp(from: mounted.journalAppURL)

                progress(.clearingQuarantine)
                try? await clearQuarantine(at: installedURL)

                progress(.cleaningTemporaryFiles)
                await mounter.detach(mounted)
                return installedURL
            } catch {
                await mounter.detach(mounted)
                throw error
            }
        } catch {
            progress(.cleaningTemporaryFiles)
            throw error
        }
    }

    private func validateLength(_ length: Int64, maxBytes: Int64) throws {
        guard length <= maxBytes else {
            throw JournalHandoffFailure.lengthExceedsCap(length: length, cap: maxBytes)
        }
    }

    private func validateDownloadedLength(fileURL: URL, expectedLength: Int64) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let actualLength = Int64(values.fileSize ?? -1)
        guard actualLength == expectedLength else {
            throw JournalHandoffFailure.lengthMismatch(expected: expectedLength, actual: actualLength)
        }
    }

    private func verifyEdDSASignature(fileURL: URL, signatureBase64: String, publicKeyBase64: String) throws {
        guard let signature = Data(base64Encoded: signatureBase64),
              signature.count == 64,
              let publicKeyBytes = Data(base64Encoded: publicKeyBase64),
              publicKeyBytes.count == 32
        else {
            throw JournalHandoffFailure.invalidSignature
        }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
        let rawDMGBytes = try Data(contentsOf: fileURL)
        guard publicKey.isValidSignature(signature, for: rawDMGBytes) else {
            throw JournalHandoffFailure.signatureVerificationFailed
        }
    }

    private func installJournalApp(from sourceURL: URL) async throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: applicationsURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw JournalHandoffFailure.applicationsDirectoryUnavailable
        }

        guard fileManager.isWritableFile(atPath: applicationsURL.path) else {
            throw JournalHandoffFailure.applicationsDirectoryUnwritable
        }

        try await quiesceRunningJournalBeforeInstall()

        let destinationURL = applicationsURL.appendingPathComponent("journal.app", isDirectory: true)
        let stageURL = applicationsURL.appendingPathComponent(
            ".journal.app.staging-\(UUID().uuidString)", isDirectory: true
        )

        do {
            try await JournalHandoffProcessRunner.run(
                executable: "/usr/bin/ditto",
                arguments: [sourceURL.path, stageURL.path]
            ).throwIfFailed("ditto")

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stageURL, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: stageURL, to: destinationURL)
            }
            return destinationURL
        } catch let failure as JournalHandoffFailure {
            try? fileManager.removeItem(at: stageURL)
            throw failure
        } catch {
            try? fileManager.removeItem(at: stageURL)
            throw JournalHandoffFailure.installFailed(String(describing: error))
        }
    }

    private func quiesceRunningJournalBeforeInstall() async throws {
        guard runningJournal.runningPID() != nil else {
            return
        }

        Logger.setup.info("journal install: asking running journal to quit before install")
        _ = runningJournal.terminateRunningJournal()
        let deadline = ContinuousClock.now.advanced(by: runningTerminationTimeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if runningJournal.runningPID() == nil {
                return
            }
            try await Task.sleep(for: runningTerminationPollInterval)
        }

        Logger.setup.error("journal install: running journal did not quit before timeout")
        throw JournalHandoffFailure.runningJournalWouldNotQuit
    }

    private func clearQuarantine(at url: URL) async throws {
        _ = try? await JournalHandoffProcessRunner.run(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", url.path]
        )
    }
}
