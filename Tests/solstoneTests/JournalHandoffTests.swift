// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import JournalMarkKit
import SolstoneCore
import Testing
@testable import solstone

@Suite("JournalHandoff", .serialized)
@MainActor
struct JournalHandoffTests {
    @Test func urlUsesInjectedApplicationSupportBase() {
        let base = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)

        let url = JournalHandoffFile.url(applicationSupportBaseURL: base)

        #expect(url.path == "/tmp/app-support/sol/journal-handoff.json")
    }

    @Test func codableRoundTripPreservesFieldsAndISO8601TimestampString() throws {
        let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-05T18:30:00Z"))
        let handoff = JournalHandoff(
            journalRootPath: "/Users/example/journal",
            observerName: "macbook",
            provenance: "solstone-macos",
            timestamp: timestamp
        )

        let data = try JSONEncoder().encode(handoff)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let timestampString = try #require(object["timestamp"] as? String)
        let decoded = try JSONDecoder().decode(JournalHandoff.self, from: data)

        #expect(object["journalRootPath"] as? String == "/Users/example/journal")
        #expect(object["observerName"] as? String == "macbook")
        #expect(object["provenance"] as? String == "solstone-macos")
        #expect(timestampString.hasPrefix("2026-07-05T18:30:00"))
        #expect(decoded == handoff)
    }

    @Test func handWrittenCamelCaseFixtureDecodes() throws {
        let fixture = """
        {
          "journalRootPath": "/Users/example/journal",
          "observerName": "studio mac",
          "provenance": "manual-test",
          "timestamp": "2026-07-05T18:30:00Z"
        }
        """

        let decoded = try JSONDecoder().decode(JournalHandoff.self, from: Data(fixture.utf8))

        #expect(decoded.journalRootPath == "/Users/example/journal")
        #expect(decoded.observerName == "studio mac")
        #expect(decoded.provenance == "manual-test")
        #expect(ISO8601DateFormatter().string(from: decoded.timestamp) == "2026-07-05T18:30:00Z")
    }

    @Test func appcastPicksMaxIntegerVersionFromUnsortedItems() throws {
        let item = try JournalAppcastParser.latestItem(from: appcast([
            appcastItem(version: 5, length: "5", url: "https://example.test/journal-5.dmg"),
            appcastItem(version: 12, length: "12", url: "https://example.test/journal-12.dmg"),
            appcastItem(version: 7, length: "7", url: "https://example.test/journal-7.dmg")
        ]))

        #expect(item.version == 12)
        #expect(item.url == URL(string: "https://example.test/journal-12.dmg"))
        #expect(item.length == 12)
    }

    @Test func appcastDuplicateVersionsDoNotRequireSortedInput() throws {
        let item = try JournalAppcastParser.latestItem(from: appcast([
            appcastItem(version: 42, length: "42", url: "https://example.test/journal-42-a.dmg"),
            appcastItem(version: 42, length: "420", url: "https://example.test/journal-42-b.dmg"),
            appcastItem(version: 41, length: "41", url: "https://example.test/journal-41.dmg")
        ]))

        #expect(item.version == 42)
        #expect(item.length == 420)
        #expect(item.url == URL(string: "https://example.test/journal-42-b.dmg"))
    }

    @Test func appcastRejectsMissingAndNonIntegerLengthBeforeDownload() async throws {
        let missing = TestWorld(appcastData: appcast([
            appcastItem(version: 1, length: nil)
        ]))
        let missingResult = await missing.run()
        #expect(missingResult == .failed(.missingLength))
        #expect(missing.downloader.calls.isEmpty)
        #expect(missing.trustVerifier.calls.isEmpty)
        try expectNoTempDebris(in: missing.tempRoot)

        let nonInteger = TestWorld(appcastData: appcast([
            appcastItem(version: 1, length: "abc")
        ]))
        let nonIntegerResult = await nonInteger.run()
        #expect(nonIntegerResult == .failed(.nonIntegerLength("abc")))
        #expect(nonInteger.downloader.calls.isEmpty)
        #expect(nonInteger.trustVerifier.calls.isEmpty)
        try expectNoTempDebris(in: nonInteger.tempRoot)
    }

    @Test func lengthCapRejectsBeforeDownloadAndLengthMismatchBeforeVerify() async throws {
        let overCapLength = JournalHandoffConstants.maxDMGBytes + 1
        let overCap = TestWorld(appcastData: appcast([
            appcastItem(version: 1, length: "\(overCapLength)")
        ]))
        let overCapResult = await overCap.run()
        #expect(overCapResult == .failed(.lengthExceedsCap(length: overCapLength, cap: JournalHandoffConstants.maxDMGBytes)))
        #expect(overCap.downloader.calls.isEmpty)
        #expect(overCap.trustVerifier.calls.isEmpty)
        try expectNoTempDebris(in: overCap.tempRoot)

        let mismatch = TestWorld(appcastData: appcast([
            appcastItem(version: 1, length: "4")
        ]))
        mismatch.downloader.bytes = Data("five!".utf8)
        let mismatchResult = await mismatch.run()
        #expect(mismatchResult == .failed(.lengthMismatch(expected: 4, actual: 5)))
        #expect(mismatch.downloader.calls.count == 1)
        #expect(mismatch.trustVerifier.calls.isEmpty)
        try expectNoTempDebris(in: mismatch.tempRoot)
    }

    @Test func edDSAVerifiesRawDMGBytesAndRejectsTamper() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let bytes = Data("real journal dmg bytes".utf8)
        let signature = try privateKey.signature(for: bytes).base64EncodedString()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        let valid = TestWorld(appcastData: appcast([
            appcastItem(version: 1, length: "\(bytes.count)", signature: signature)
        ]))
        valid.dependencies.publicEDKeyBase64 = publicKey
        valid.downloader.bytes = bytes
        valid.initProbe.replies = [.result(.incomplete), .result(.complete)]
        let validResult = await valid.run()
        #expect(validResult == .completed)
        #expect(valid.configFlipper.flipCount == 1)
        try expectNoTempDebris(in: valid.tempRoot)

        let tampered = TestWorld(appcastData: appcast([
            appcastItem(version: 1, length: "\(bytes.count)", signature: signature)
        ]))
        tampered.dependencies.publicEDKeyBase64 = publicKey
        tampered.downloader.bytes = Data("Real journal dmg bytes".utf8)
        let tamperedResult = await tampered.run()
        #expect(tamperedResult == .failed(.signatureVerificationFailed))
        #expect(tampered.trustVerifier.calls.isEmpty)
        try expectNoTempDebris(in: tampered.tempRoot)
    }

    @Test func acquireFailureBranchesLeaveNoTemporaryDebris() async throws {
        let signatureWorld = signedWorld()
        signatureWorld.downloader.bytes = Data("tampered".utf8)
        _ = await signatureWorld.run()
        try expectNoTempDebris(in: signatureWorld.tempRoot)

        let mountWorld = signedWorld()
        mountWorld.mounter.mountFailure = .mountFailed("mount failed")
        _ = await mountWorld.run()
        try expectNoTempDebris(in: mountWorld.tempRoot)

        for trustFailure in [
            "codesign verify failed",
            "team identifier mismatch",
            "bundle identifier mismatch"
        ] {
            let trustWorld = signedWorld()
            trustWorld.trustVerifier.failure = .trustFailed(trustFailure)
            _ = await trustWorld.run()
            try expectNoTempDebris(in: trustWorld.tempRoot)
        }
    }

    @Test func initCompleteAdoptionFlipsAndDrainsSync() async throws {
        let world = installedWorld()
        world.initProbe.replies = [.result(.incomplete), .result(.complete)]

        let result = await world.run()

        #expect(result == .completed)
        #expect(world.runningJournal.launches == 1)
        #expect(world.configFlipper.flipCount == 1)
        #expect(world.configFlipper.triggerSyncCount == 1)
        #expect(world.state.config.serviceMode == .external)
        #expect(world.state.config.serverKey == "observer-key")
        #expect(!world.state.journalHandoffActive)
    }

    @Test func initIncompleteWaitsUntilLaterCompletion() async throws {
        let world = installedWorld()
        world.dependencies.adoptionPollInterval = .milliseconds(1)
        world.initProbe.replies = [
            .result(.incomplete),
            .result(.incomplete),
            .result(.incomplete),
            .result(.complete)
        ]

        let result = await world.run()

        #expect(result == .completed)
        #expect(world.initProbe.calls >= 4)
        #expect(world.configFlipper.flipCount == 1)
    }

    @Test func consumedHandoffCompletesMarklessAdoption() async throws {
        let world = installedWorld()
        world.dependencies.adoptionPollInterval = .milliseconds(1)
        world.initProbe.replies = [.result(.incomplete), .result(.incomplete)]
        world.initProbe.onCall = { calls in
            if calls == 2 {
                try? FileManager.default.removeItem(at: world.dependencies.handoffFileURL)
            }
        }

        let result = await world.run()

        #expect(result == .completed)
        #expect(world.configFlipper.flipCount == 1)
    }

    @Test func authFailureAbortsBeforeFlip() async throws {
        let world = installedWorld()
        world.initProbe.replies = [.result(.incomplete), .result(.complete)]
        world.connectionTester.failure = "Invalid API key"

        let result = await world.run()

        #expect(result == .aborted(.authenticationFailed("Invalid API key")))
        #expect(world.configFlipper.flipCount == 0)
        #expect(world.configFlipper.triggerSyncCount == 0)
        #expect(world.state.config.serviceMode == .bundled)
        #expect(world.state.config.serverKey == "observer-key")
    }

    @Test func initUnauthorizedAbortsBeforeFlip() async throws {
        let world = installedWorld()
        world.initProbe.replies = [
            .result(.incomplete),
            .error(JournalInitClientError.serverError(401))
        ]

        let result = await world.run()

        #expect(result == .aborted(.authenticationFailed("Invalid API key")))
        #expect(world.configFlipper.flipCount == 0)
        #expect(world.state.config.serviceMode == .bundled)
    }

    @Test func feedNotYetPublishedUsesShipCopy() async throws {
        let world = TestWorld(appcastData: appcast([]))
        world.appcast.failure = .feedNotYetPublished

        let result = await world.run()
        let message = "the journal app isn't available yet " + "— sol is keeping everything safe on this mac"

        #expect(result == .failed(.feedNotYetPublished))
        #expect(JournalHandoffFailure.feedNotYetPublished.ownerMessage == message)
        #expect(world.downloader.calls.isEmpty)
    }

    @Test func resumeDerivationUsesOnlyLiveProbeState() {
        let journalPath = "/tmp/journal"

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .external,
            journalPath: journalPath,
            installedTrusted: true,
            running: true,
            handoffFileExists: false,
            setupComplete: true
        )) == .completed)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: nil,
            installedTrusted: true,
            running: false,
            handoffFileExists: false,
            setupComplete: false
        )) == .aborted(.missingJournalPath))

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: false,
            running: false,
            handoffFileExists: false,
            setupComplete: false
        )) == .acquiring(.fetchingAppcast))

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: false,
            handoffFileExists: true,
            setupComplete: false
        )) == .launchingJournal)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: true,
            handoffFileExists: true,
            setupComplete: false
        )) == .waitingForAdoption)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: true,
            handoffFileExists: false,
            setupComplete: false
        )) == .authGate)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: false,
            handoffFileExists: false,
            setupComplete: true,
            storedKeyAuthValid: false
        )) == .authGate)
    }

    @Test func postFlipNeverReentersMigration() async throws {
        let world = installedWorld(serviceMode: .external)

        let result = await world.run()

        #expect(result == .completed)
        #expect(world.appcast.calls == 0)
        #expect(world.downloader.calls.isEmpty)
        #expect(world.configFlipper.flipCount == 0)
    }

    @Test func keyBytesRemainIdenticalAcrossFlip() async throws {
        let world = installedWorld()
        world.initProbe.replies = [.result(.incomplete), .result(.complete)]
        let originalConfig = world.state.config
        let originalKey = try #require(world.state.config.serverKey)

        let result = await world.run()

        #expect(result == .completed)
        #expect(world.state.config.serverURL == originalConfig.serverURL)
        #expect(world.state.config.serverKey == originalKey)
        #expect(world.state.config.observerName == originalConfig.observerName)
        #expect(world.state.config.journalPath == originalConfig.journalPath)
        #expect(world.state.config.serviceMode == .external)
        #expect(Array(world.state.config.serverKey!.utf8) == Array(originalKey.utf8))
        let persistedKey = try #require(UserDefaults.standard.string(forKey: "serverKey"))
        #expect(Array(persistedKey.utf8) == Array(originalKey.utf8))
    }

    @Test func runningJournalThatWillNotQuitAbortsHonestly() async throws {
        let world = signedWorld()
        world.runningJournal.running = true
        world.runningJournal.refusesTerminate = true
        world.dependencies.runningTerminationTimeout = .milliseconds(5)
        world.dependencies.runningTerminationPollInterval = .milliseconds(1)

        let result = await world.run()

        #expect(result == .aborted(.runningJournalWouldNotQuit))
        #expect(world.configFlipper.flipCount == 0)
    }

    @Test func missingJournalPathAbortsWithoutInventingRoot() async throws {
        let world = installedWorld(journalPath: nil)

        let result = await world.run()

        #expect(result == .aborted(.missingJournalPath))
        #expect(world.configFlipper.flipCount == 0)
        #expect(world.appcast.calls == 0)
    }

    @Test func missingJournalDirectoryAbortsWithoutInventingRoot() async throws {
        let missingPath = "/tmp/missing-journal-\(UUID().uuidString)"
        let world = installedWorld(journalPath: missingPath)

        let result = await world.run()

        #expect(result == .aborted(.journalPathMissing(missingPath)))
        #expect(world.configFlipper.flipCount == 0)
    }

    @Test func sparkleExclusivityProviderTracksHandoffFlag() {
        let state = AppState.forSnapshot()
        let provider: @MainActor () -> Bool = { state.journalHandoffActive }

        #expect(!provider())
        state.journalHandoffActive = true
        #expect(provider())
        state.journalHandoffActive = false
        #expect(!provider())
    }

    private func signedWorld() -> TestWorld {
        let privateKey = Curve25519.Signing.PrivateKey()
        let bytes = Data("real journal dmg bytes".utf8)
        let signature = try! privateKey.signature(for: bytes).base64EncodedString()
        let world = TestWorld(appcastData: appcast([
            appcastItem(version: 1, length: "\(bytes.count)", signature: signature)
        ]))
        world.dependencies.publicEDKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        world.downloader.bytes = bytes
        return world
    }

    private func installedWorld(
        serviceMode: ServiceMode = .bundled,
        journalPath: String? = "default"
    ) -> TestWorld {
        let world = TestWorld(appcastData: appcast([]), serviceMode: serviceMode, journalPath: journalPath)
        world.runningJournal.installed = world.installedJournalURL
        return world
    }
}

@MainActor
private final class TestWorld {
    let tempRoot: URL
    let journalRoot: URL
    let installedJournalURL: URL
    let appcast: FakeAppcastClient
    let downloader = FakeDMGDownloader()
    let mounter = FakeDiskImageMounter()
    let trustVerifier = FakeTrustVerifier()
    let initProbe = FakeInitProbe()
    let connectionTester = FakeConnectionTester()
    let runningJournal = FakeRunningJournalController()
    let configFlipper = FakeConfigFlipper()
    var dependencies: JournalHandoffDependencies
    let state: AppState
    let driver = JournalMarkConfirmationDriver(
        deadlineSeconds: 0.05,
        heldPollInterval: .milliseconds(1),
        fetchRetryInterval: .milliseconds(1)
    )

    init(appcastData: Data, serviceMode: ServiceMode = .bundled, journalPath: String? = "default") {
        tempRoot = try! makeTempDirectory("journal-handoff")
        journalRoot = tempRoot.appendingPathComponent("journal-root", isDirectory: true)
        try! FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        installedJournalURL = tempRoot
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("journal.app", isDirectory: true)

        appcast = FakeAppcastClient(data: appcastData)
        let applicationsURL = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        try! FileManager.default.createDirectory(at: applicationsURL, withIntermediateDirectories: true)

        let configuredJournalPath: String?
        if journalPath == "default" {
            configuredJournalPath = journalRoot.path
        } else {
            configuredJournalPath = journalPath
        }
        state = AppState.forSnapshot(config: AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "observer-key",
            serviceMode: serviceMode,
            journalPath: configuredJournalPath,
            observerName: "observer-name"
        ))

        dependencies = JournalHandoffDependencies(
            appcastClient: appcast,
            downloader: downloader,
            mounter: mounter,
            trustVerifier: trustVerifier,
            initProbe: initProbe,
            connectionTester: connectionTester,
            runningJournal: runningJournal,
            configFlipper: configFlipper,
            handoffFileURL: tempRoot
                .appendingPathComponent("sol", isDirectory: true)
                .appendingPathComponent("journal-handoff.json"),
            applicationsURL: applicationsURL,
            publicEDKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            maxDMGBytes: JournalHandoffConstants.maxDMGBytes,
            adoptionTimeout: .milliseconds(50),
            adoptionPollInterval: .milliseconds(1),
            runningTerminationTimeout: .milliseconds(50),
            runningTerminationPollInterval: .milliseconds(1),
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_234) }
        )
        downloader.tempRoot = tempRoot
        mounter.tempRoot = tempRoot
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func run() async -> JournalHandoffStep {
        let orchestrator = JournalHandoffOrchestrator(dependencies: dependencies)
        let result = await orchestrator.run(
            appState: state,
            markDriver: driver,
            markFetch: { _ in nil }
        )
        driver.cancel()
        return result
    }
}

@MainActor
private final class FakeAppcastClient: AppcastClient {
    let data: Data
    var failure: JournalHandoffFailure?
    var calls = 0

    init(data: Data) {
        self.data = data
    }

    func fetchAppcast() async throws -> Data {
        calls += 1
        if let failure {
            throw failure
        }
        return data
    }
}

@MainActor
private final class FakeDMGDownloader: DMGDownloader {
    var tempRoot: URL!
    var bytes = Data("dmg".utf8)
    var calls: [(url: URL, expectedLength: Int64, maxBytes: Int64)] = []

    func downloadDMG(from url: URL, expectedLength: Int64, maxBytes: Int64) async throws -> URL {
        calls.append((url, expectedLength, maxBytes))
        let fileURL = tempRoot.appendingPathComponent("download-\(UUID().uuidString).dmg")
        try bytes.write(to: fileURL)
        return fileURL
    }
}

@MainActor
private final class FakeDiskImageMounter: DiskImageMounter {
    var tempRoot: URL!
    var mountFailure: JournalHandoffFailure?
    var mounts = 0
    var detaches = 0

    func mount(dmgURL: URL) async throws -> MountedDiskImage {
        mounts += 1
        let mountPoint = tempRoot.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let appURL = mountPoint.appendingPathComponent("journal.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try Data("app".utf8).write(to: appURL.appendingPathComponent("marker"))
        if let mountFailure {
            try? FileManager.default.removeItem(at: mountPoint)
            throw mountFailure
        }
        return MountedDiskImage(mountPoint: mountPoint, journalAppURL: appURL)
    }

    func detach(_ image: MountedDiskImage) async {
        detaches += 1
        try? FileManager.default.removeItem(at: image.mountPoint)
    }
}

@MainActor
private final class FakeTrustVerifier: TrustVerifier {
    var calls: [URL] = []
    var failure: JournalHandoffFailure?

    func verifyJournalApp(at url: URL) async throws {
        calls.append(url)
        if let failure {
            throw failure
        }
    }
}

@MainActor
private final class FakeInitProbe: InitProbe {
    enum Reply {
        case result(JournalInitSetupProbe)
        case error(Error)
    }

    var replies: [Reply] = [.result(.incomplete)]
    var calls = 0
    var onCall: ((Int) -> Void)?

    func probeSetupComplete() async throws -> JournalInitSetupProbe {
        calls += 1
        onCall?(calls)
        let reply = replies.isEmpty ? .result(.incomplete) : replies.removeFirst()
        switch reply {
        case .result(let result):
            return result
        case .error(let error):
            throw error
        }
    }
}

@MainActor
private final class FakeConnectionTester: ConnectionTester {
    var failure: String?
    var calls: [(url: String, key: String)] = []

    func testConnection(serverURL: String, serverKey: String) async -> String? {
        calls.append((serverURL, serverKey))
        return failure
    }
}

@MainActor
private final class FakeRunningJournalController: RunningJournalController {
    var installed: URL?
    var running = false
    var refusesTerminate = false
    var launches = 0
    var terminateCalls = 0

    func installedURL() -> URL? {
        installed
    }

    func runningPID() -> pid_t? {
        running ? 1234 : nil
    }

    func terminateRunningJournal() -> Bool {
        terminateCalls += 1
        if refusesTerminate {
            return false
        }
        running = false
        return true
    }

    func launchJournal(at url: URL) throws {
        launches += 1
        running = true
    }
}

@MainActor
private final class FakeConfigFlipper: ConfigFlipper {
    var flipCount = 0
    var triggerSyncCount = 0

    func flipToExternal(appState: AppState) {
        flipCount += 1
        var config = appState.config
        config.serviceMode = .external
        appState.updateConfig(config)
    }

    func triggerSync(appState: AppState) {
        triggerSyncCount += 1
    }
}

private func appcast(_ items: [String]) -> Data {
    Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        \(items.joined(separator: "\n"))
      </channel>
    </rss>
    """.utf8)
}

private func appcastItem(
    version: Int,
    length: String?,
    url: String = "https://example.test/journal.dmg",
    signature: String = Data(repeating: 1, count: 64).base64EncodedString()
) -> String {
    let lengthAttribute = length.map { #" length="\#($0)""# } ?? ""
    return """
    <item>
      <title>journal \(version)</title>
      <sparkle:version>\(version)</sparkle:version>
      <sparkle:shortVersionString>1.0.\(version)</sparkle:shortVersionString>
      <enclosure url="\(url)"\(lengthAttribute) type="application/x-apple-diskimage" sparkle:edSignature="\(signature)" />
    </item>
    """
}

private func expectNoTempDebris(in root: URL) throws {
    let contents = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    )
    let debris = contents.filter { url in
        url.lastPathComponent.hasPrefix("download-") || url.lastPathComponent.hasPrefix("mount-")
    }
    #expect(debris.isEmpty)
}
