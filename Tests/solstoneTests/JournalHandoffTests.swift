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

    @Test func liveConfigFlipperClearsDurableLastContactBeforeExternalFlip() throws {
        let config = AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "observer-key",
            serviceMode: .bundled,
            journalPath: "/Users/example/journal"
        )
        let oldFingerprint = try #require(journalConnectionFingerprint(
            config: config,
            topology: .local,
            isTunnelManaged: false,
            tunnelPairing: nil
        ))
        let store = InMemoryLastSuccessfulJournalContactStore(readResult: .found(
            LastSuccessfulJournalContactPayload(
                date: Date(timeIntervalSince1970: 123),
                fingerprint: oldFingerprint.value
            )
        ))
        let state = AppState.forSnapshot(config: config, lastContactStore: store)
        #expect(state.uploadCoordinator.lastSuccessfulJournalContactOutcome == .synced(Date(timeIntervalSince1970: 123)))

        LiveConfigFlipper().flipToExternal(appState: state)

        #expect(store.read() == .absent)
        #expect(state.config.serviceMode == .external)
        #expect(state.uploadCoordinator.lastSuccessfulJournalContactOutcome == .noSyncYet)
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

    @Test func handoffFeedOverrideUnsetUsesProduction() throws {
        let isolated = try makeIsolatedDefaults()
        defer { isolated.remove() }

        let selection = JournalHandoffFeed.resolve(defaults: isolated.defaults)

        #expect(selection == productionFeedSelection)
    }

    @Test func handoffFeedOverrideCanonicalStagingWithWhitespaceUsesStaging() throws {
        let isolated = try makeIsolatedDefaults()
        defer { isolated.remove() }
        isolated.defaults.set(
            "\n  \(JournalHandoffConstants.stagingAppcastURLString)  \n",
            forKey: JournalHandoffConstants.handoffFeedOverrideDefaultsKey
        )

        let selection = JournalHandoffFeed.resolve(defaults: isolated.defaults)

        #expect(selection == stagingFeedSelection)
    }

    @Test func handoffFeedOverrideRejectsNonCanonicalValues() throws {
        let variants: [(name: String, value: Any)] = [
            ("empty", ""),
            ("whitespace-only", " \n\t "),
            ("non-string", 42),
            ("malformed", "not a url"),
            ("http", "http://updates.solstone.app/journal-macos/_staging/appcast.xml"),
            ("query", "\(JournalHandoffConstants.stagingAppcastURLString)?x=1"),
            ("fragment", "\(JournalHandoffConstants.stagingAppcastURLString)#frag"),
            ("userinfo", "https://u:p@updates.solstone.app/journal-macos/_staging/appcast.xml"),
            ("explicit-port", "https://updates.solstone.app:443/journal-macos/_staging/appcast.xml"),
            ("encoded-path", "https://updates.solstone.app/journal-macos/%5Fstaging/appcast.xml"),
            ("wrong-host", "https://staging.updates.solstone.app/journal-macos/_staging/appcast.xml"),
            ("wrong-path", "https://updates.solstone.app/journal-macos/staging/appcast.xml"),
        ]

        for variant in variants {
            let isolated = try makeIsolatedDefaults()
            defer { isolated.remove() }
            isolated.defaults.set(variant.value, forKey: JournalHandoffConstants.handoffFeedOverrideDefaultsKey)

            let selection = JournalHandoffFeed.resolve(defaults: isolated.defaults)

            #expect(selection == rejectedFeedSelection, "variant: \(variant.name)")
        }
    }

    @Test func liveHandoffFeedResolverUsesInjectedDefaultsAndReadsFreshly() throws {
        let isolated = try makeIsolatedDefaults()
        defer { isolated.remove() }
        isolated.defaults.set(
            JournalHandoffConstants.stagingAppcastURLString,
            forKey: JournalHandoffConstants.handoffFeedOverrideDefaultsKey
        )
        let dependencies = JournalHandoffDependencies.live(defaults: isolated.defaults)

        #expect(dependencies.appcastFeedResolver() == stagingFeedSelection)

        isolated.defaults.removeObject(forKey: JournalHandoffConstants.handoffFeedOverrideDefaultsKey)
        #expect(dependencies.appcastFeedResolver() == productionFeedSelection)

        isolated.defaults.set(
            JournalHandoffConstants.stagingAppcastURLString,
            forKey: JournalHandoffConstants.handoffFeedOverrideDefaultsKey
        )
        #expect(dependencies.appcastFeedResolver() == stagingFeedSelection)
    }

    @Test func orchestratorFetchesSelectedHandoffFeedURL() async throws {
        let staging = TestWorld(appcastData: appcast([]))
        staging.selectFeed(stagingFeedSelection)
        _ = await staging.run()

        #expect(staging.appcast.requestedURLs == [JournalHandoffConstants.stagingAppcastURL])
        #expect(staging.feedResolver.calls == 1)

        let production = TestWorld(appcastData: appcast([]))
        production.selectFeed(productionFeedSelection)
        _ = await production.run()

        #expect(production.appcast.requestedURLs == [JournalHandoffConstants.appcastURL])
        #expect(production.feedResolver.calls == 1)
    }

    @Test func stagingHandoffFeedFailureDoesNotFallbackToProduction() async throws {
        let world = TestWorld(appcastData: appcast([]))
        world.selectFeed(stagingFeedSelection)
        world.appcast.failure = .appcastUnavailable("boom")

        let result = await world.run()

        #expect(result == .failed(.appcastUnavailable("boom")))
        #expect(world.appcast.requestedURLs == [JournalHandoffConstants.stagingAppcastURL])
        #expect(world.downloader.calls.isEmpty)
    }

    @Test func sparkleFeedOverrideDoesNotAffectJournalHandoffFeedResolution() throws {
        let isolated = try makeIsolatedDefaults()
        defer { isolated.remove() }
        isolated.defaults.set(
            JournalHandoffConstants.stagingAppcastURLString,
            forKey: "solstone.updates.feedURLOverride"
        )

        let selection = JournalHandoffFeed.resolve(defaults: isolated.defaults)

        #expect(selection == productionFeedSelection)
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

    @Test func recordsSuccessfulFreshAcquireStepSequence() async throws {
        let world = signedWorld()
        world.initProbe.replies = [.result(.incomplete), .result(.complete)]
        var recorded: [JournalHandoffStep] = [.idle]
        let orchestrator = JournalHandoffOrchestrator(dependencies: world.dependencies)
        orchestrator.onStepTransition = { step in
            recorded.append(step)
        }

        let result = await orchestrator.run(
            appState: world.state,
            markDriver: world.driver,
            markFetch: { _ in nil }
        )
        world.driver.cancel()

        #expect(result == .completed)
        #expect(recorded == [
            .idle,
            .acquiring(.fetchingAppcast),
            .acquiring(.selectingLatestSparkleVersion),
            .acquiring(.validatingLength),
            .acquiring(.downloadingDMG),
            .acquiring(.verifyingEdDSA),
            .acquiring(.mountingDMG),
            .acquiring(.verifyingJournalAppTrust),
            .acquiring(.installingToApplications),
            .acquiring(.clearingQuarantine),
            .acquiring(.cleaningTemporaryFiles),
            .checkingRunningJournal,
            .writingHandoff,
            .launchingJournal,
            .waitingForAdoption,
            .authGate,
            .flippingToExternal,
            .triggeringSyncDrain,
            .confirmingMarkBestEffort,
            .completed
        ])
    }

    @Test func migrationWriterWritesWhenNoHandoffExists() async throws {
        let world = installedWorld()
        world.initProbe.replies = [.result(.incomplete), .result(.complete)]

        let result = await world.run()
        let handoff = try readHandoff(at: world.dependencies.handoffFileURL)

        #expect(result == .completed)
        #expect(handoff.journalRootPath == world.journalRoot.path)
        #expect(handoff.provenance == JournalHandoffProvenance.bundledMigration)
    }

    @Test func migrationWriterOverwritesDiscoveryProvenanceHandoff() async throws {
        let world = installedWorld()
        world.initProbe.replies = [.result(.incomplete), .result(.complete)]
        try writeHandoff(
            at: world.dependencies.handoffFileURL,
            journalRootPath: "/leftover-discovery",
            provenance: JournalHandoffProvenance.observerDiscovery
        )

        let result = await world.run()
        let handoff = try readHandoff(at: world.dependencies.handoffFileURL)

        #expect(result == .completed)
        #expect(handoff.journalRootPath == world.journalRoot.path)
        #expect(handoff.provenance == JournalHandoffProvenance.bundledMigration)
    }

    @Test func migrationResumeOverwritesPreexistingDiscoveryProvenanceHandoff() async throws {
        let world = installedWorld()
        world.initProbe.replies = [.result(.incomplete), .result(.incomplete), .result(.complete)]
        try writeHandoff(
            at: world.dependencies.handoffFileURL,
            journalRootPath: "/leftover-discovery",
            provenance: JournalHandoffProvenance.observerDiscovery
        )
        let probeOrchestrator = JournalHandoffOrchestrator(dependencies: world.dependencies)

        let derivedStep = await probeOrchestrator.deriveResumeStep(appState: world.state)
        let result = await world.run()
        let handoff = try readHandoff(at: world.dependencies.handoffFileURL)

        #expect(derivedStep == .writingHandoff)
        #expect(result == .completed)
        #expect(handoff.journalRootPath == world.journalRoot.path)
        #expect(handoff.provenance == JournalHandoffProvenance.bundledMigration)
    }

    @Test func migrationWriterKeepsExistingMigrationProvenanceHandoff() async throws {
        let world = installedWorld()
        world.initProbe.replies = [.result(.incomplete), .result(.complete)]
        try writeHandoff(
            at: world.dependencies.handoffFileURL,
            journalRootPath: "/existing-migration",
            provenance: JournalHandoffProvenance.bundledMigration
        )

        let result = await world.run()
        let handoff = try readHandoff(at: world.dependencies.handoffFileURL)

        #expect(result == .completed)
        #expect(handoff.journalRootPath == "/existing-migration")
        #expect(handoff.provenance == JournalHandoffProvenance.bundledMigration)
    }

    @Test func freshFlowInstalledTrustedLaunchesActivatedWithoutAcquire() async throws {
        let world = installedWorld()
        let flow = freshFlow(world: world)

        flow.start()
        try await waitUntil("fresh flow waiting for installed journal") {
            flow.state == .waitingForJournal
        }

        #expect(world.trustVerifier.calls == [world.installedJournalURL])
        #expect(world.appcast.requestedURLs.isEmpty)
        #expect(world.downloader.calls.isEmpty)
        #expect(world.runningJournal.launches == 0)
        #expect(world.runningJournal.activatingLaunches == 1)
    }

    @Test func freshFlowAbsentAppAcquiresThenLaunchesActivated() async throws {
        let world = signedWorld()
        let flow = freshFlow(world: world)

        flow.start()
        try await waitUntil("fresh flow waiting after acquire") {
            flow.state == .waitingForJournal
        }

        #expect(world.appcast.requestedURLs == [JournalHandoffConstants.appcastURL])
        #expect(world.downloader.calls.count == 1)
        #expect(world.mounter.mounts == 1)
        #expect(world.mounter.detaches == 1)
        #expect(world.runningJournal.launches == 0)
        #expect(world.runningJournal.activatingLaunches == 1)
        #expect(FileManager.default.fileExists(atPath: world.installedJournalURL.path))
    }

    @Test func freshFlowAbsentAppLeavesNoStagingLitter() async throws {
        let world = signedWorld()
        let flow = freshFlow(world: world)

        flow.start()
        try await waitUntil("fresh flow waiting after acquire with no staging litter") {
            flow.state == .waitingForJournal
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: world.dependencies.applicationsURL.path)
        #expect(names == ["journal.app"])
    }

    @Test func freshFlowVerificationFailuresFailWithoutInstall() async throws {
        let lengthMismatch = TestWorld(appcastData: appcast([
            appcastItem(version: 1, length: "4")
        ]))
        lengthMismatch.downloader.bytes = Data("five!".utf8)
        try await expectFreshFlowFailure(
            world: lengthMismatch,
            .lengthMismatch(expected: 4, actual: 5)
        )

        let edDSAMismatch = signedWorld()
        edDSAMismatch.downloader.bytes = Data("Real journal dmg bytes".utf8)
        try await expectFreshFlowFailure(
            world: edDSAMismatch,
            .signatureVerificationFailed
        )

        let bundleMismatch = signedWorld()
        bundleMismatch.trustVerifier.failure = .trustFailed("bundle identifier mismatch")
        try await expectFreshFlowFailure(
            world: bundleMismatch,
            .trustFailed("bundle identifier mismatch")
        )

        let teamMismatch = signedWorld()
        teamMismatch.trustVerifier.failure = .trustFailed("team identifier mismatch")
        try await expectFreshFlowFailure(
            world: teamMismatch,
            .trustFailed("team identifier mismatch")
        )
    }

    @Test func freshFlowDoubleStartWhileInFlightIsNoOp() async throws {
        let world = signedWorld()
        world.appcast.beforeReturn = {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let flow = freshFlow(world: world)

        flow.start()
        flow.start()
        try await waitUntil("fresh flow waiting after double start") {
            flow.state == .waitingForJournal
        }

        #expect(world.appcast.requestedURLs.count == 1)
        #expect(world.downloader.calls.count == 1)
        #expect(world.runningJournal.activatingLaunches == 1)
    }

    @Test func freshFlowUsesSelectedFeedResolver() async throws {
        let staging = signedWorld()
        staging.selectFeed(stagingFeedSelection)
        let stagingFlow = freshFlow(world: staging)

        stagingFlow.start()
        try await waitUntil("fresh flow staging acquire") {
            stagingFlow.state == .waitingForJournal
        }

        #expect(staging.appcast.requestedURLs == [JournalHandoffConstants.stagingAppcastURL])
        #expect(staging.feedResolver.calls == 1)

        let rejected = signedWorld()
        rejected.selectFeed(rejectedFeedSelection)
        let rejectedFlow = freshFlow(world: rejected)

        rejectedFlow.start()
        try await waitUntil("fresh flow rejected override acquire") {
            rejectedFlow.state == .waitingForJournal
        }

        #expect(rejected.appcast.requestedURLs == [JournalHandoffConstants.appcastURL])
        #expect(rejected.feedResolver.calls == 1)
    }

    @Test func onDiskAdoptionAbsentAppAcquiresWritesDiscoveryHandoffAndLaunches() async throws {
        let world = signedWorld()
        let flow = onDiskAdoptionFlow(world: world)

        flow.start(discoveredPath: world.journalRoot.path, observerName: world.state.config.observerName)
        try await waitUntil("on-disk adoption waiting after acquire") {
            flow.state == .waitingForJournal
        }

        let handoff = try readHandoff(at: world.dependencies.handoffFileURL)
        #expect(handoff.journalRootPath == world.journalRoot.path)
        #expect(handoff.observerName == "observer-name")
        #expect(handoff.provenance == JournalHandoffProvenance.observerDiscovery)
        #expect(world.appcast.requestedURLs == [JournalHandoffConstants.appcastURL])
        #expect(world.downloader.calls.count == 1)
        #expect(world.runningJournal.activatingLaunches == 1)
    }

    @Test func onDiskAdoptionAcquireFailureDoesNotWriteHandoff() async throws {
        let world = TestWorld(appcastData: appcast([]))
        let flow = onDiskAdoptionFlow(world: world)

        flow.start(discoveredPath: world.journalRoot.path, observerName: world.state.config.observerName)
        try await waitUntil("on-disk adoption failure") {
            if case .failed = flow.state {
                return true
            }
            return false
        }

        #expect(flow.state == .failed(.invalidAppcast("missing appcast item")))
        #expect(!FileManager.default.fileExists(atPath: world.dependencies.handoffFileURL.path))
        #expect(world.runningJournal.activatingLaunches == 0)
    }

    @Test func onDiskAdoptionInstalledTrustedCapableWritesHandoffAndSkipsDownload() async throws {
        let world = installedWorld()
        try writeJournalInfoPlist(at: world.installedJournalURL, build: 9)
        let flow = onDiskAdoptionFlow(world: world)
        let action = await flow.resolveOfferAction()

        flow.start(
            discoveredPath: world.journalRoot.path,
            observerName: world.state.config.observerName,
            action: action
        )
        try await waitUntil("on-disk adoption waiting for installed journal") {
            flow.state == .waitingForJournal
        }

        let handoff = try readHandoff(at: world.dependencies.handoffFileURL)
        #expect(action == .open(world.installedJournalURL))
        #expect(handoff.journalRootPath == world.journalRoot.path)
        #expect(handoff.provenance == JournalHandoffProvenance.observerDiscovery)
        #expect(world.appcast.requestedURLs.isEmpty)
        #expect(world.downloader.calls.isEmpty)
        #expect(world.runningJournal.activatedURLs == [world.installedJournalURL])
    }

    @Test func onDiskAdoptionInstalledTrustedOldBuildAcquiresAndDoesNotLaunchOldBuild() async throws {
        let world = signedWorld()
        world.runningJournal.installed = world.installedJournalURL
        try writeJournalInfoPlist(at: world.installedJournalURL, build: 8)
        let flow = onDiskAdoptionFlow(world: world)
        let action = await flow.resolveOfferAction()

        flow.start(
            discoveredPath: world.journalRoot.path,
            observerName: world.state.config.observerName,
            action: action
        )
        try await waitUntil("on-disk adoption waiting after replacing old journal") {
            flow.state == .waitingForJournal
        }

        #expect(action == .install)
        #expect(world.appcast.requestedURLs == [JournalHandoffConstants.appcastURL])
        #expect(world.downloader.calls.count == 1)
        #expect(world.runningJournal.activatedURLs == [world.installedJournalURL])
        #expect(journalBuild(at: world.installedJournalURL) == 9)
        #expect(world.runningJournal.terminateCalls == 0)
    }

    @Test func onDiskAdoptionQuiescesRunningJournalThenReplacesOldBuild() async throws {
        let world = signedWorld()
        world.runningJournal.installed = world.installedJournalURL
        world.runningJournal.running = true
        try writeJournalInfoPlist(at: world.installedJournalURL, build: 8)
        let flow = onDiskAdoptionFlow(world: world)
        let action = await flow.resolveOfferAction()

        flow.start(
            discoveredPath: world.journalRoot.path,
            observerName: world.state.config.observerName,
            action: action
        )
        try await waitUntil("on-disk adoption waiting after quiescing running journal") {
            flow.state == .waitingForJournal
        }

        #expect(action == .install)
        #expect(world.runningJournal.terminateCalls >= 1)
        #expect(journalBuild(at: world.installedJournalURL) == 9)
    }

    @Test func onDiskAdoptionQuiesceFailureLeavesOldBuildUntouched() async throws {
        let world = signedWorld()
        world.runningJournal.installed = world.installedJournalURL
        world.runningJournal.running = true
        world.runningJournal.refusesTerminate = true
        world.dependencies.runningTerminationTimeout = .milliseconds(5)
        world.dependencies.runningTerminationPollInterval = .milliseconds(1)
        try writeJournalInfoPlist(at: world.installedJournalURL, build: 8)
        let flow = onDiskAdoptionFlow(world: world)
        let action = await flow.resolveOfferAction()

        flow.start(
            discoveredPath: world.journalRoot.path,
            observerName: world.state.config.observerName,
            action: action
        )
        try await waitUntil("on-disk adoption quiesce abort") {
            flow.state == .failed(.runningJournalWouldNotQuit)
        }

        #expect(action == .install)
        #expect(journalBuild(at: world.installedJournalURL) == 8)
    }

    @Test func onDiskAdoptionDittoFailureLeavesOldBuildAndNoStagingLitter() async throws {
        let world = signedWorld()
        world.runningJournal.installed = world.installedJournalURL
        world.mounter.removeAppAfterMount = true
        try writeJournalInfoPlist(at: world.installedJournalURL, build: 8)
        let flow = onDiskAdoptionFlow(world: world)
        let action = await flow.resolveOfferAction()

        flow.start(
            discoveredPath: world.journalRoot.path,
            observerName: world.state.config.observerName,
            action: action
        )
        try await waitUntil("on-disk adoption ditto failure") {
            if case .failed = flow.state {
                return true
            }
            return false
        }

        #expect(action == .install)
        #expect(journalBuild(at: world.installedJournalURL) == 8)
        let names = try FileManager.default.contentsOfDirectory(atPath: world.dependencies.applicationsURL.path)
        #expect(!names.contains { $0.hasPrefix(".journal.app.staging-") })
    }

    @Test func onDiskAdoptionReplaceLeavesNoStagingLitter() async throws {
        let world = signedWorld()
        world.runningJournal.installed = world.installedJournalURL
        world.runningJournal.running = true
        try writeJournalInfoPlist(at: world.installedJournalURL, build: 8)
        let flow = onDiskAdoptionFlow(world: world)
        let action = await flow.resolveOfferAction()

        flow.start(
            discoveredPath: world.journalRoot.path,
            observerName: world.state.config.observerName,
            action: action
        )
        try await waitUntil("on-disk adoption waiting after replacing old journal without litter") {
            flow.state == .waitingForJournal
        }

        #expect(journalBuild(at: world.installedJournalURL) == 9)
        let names = try FileManager.default.contentsOfDirectory(atPath: world.dependencies.applicationsURL.path)
        #expect(names == ["journal.app"])
    }

    @Test func freshFlowWaitingProbeStoresDiscoveredMarkAndStops() async throws {
        let world = installedWorld()
        var calls = 0
        let flow = freshFlow(
            world: world,
            fetchIdentity: { _ in
                calls += 1
                return calls == 1 ? nil : .uiTestSample
            },
            sleep: { _ in }
        )

        flow.start()
        try await waitUntil("fresh flow waiting before probe") {
            flow.state == .waitingForJournal
        }
        flow.armWaitingProbe()
        try await waitUntil("fresh flow discovered journal mark") {
            flow.discoveredJournalMark == .uiTestSample
        }
        await Task.yield()

        #expect(calls == 2)
    }

    @Test func freshFlowCancelWaitingProbeStopsProbing() async throws {
        let world = installedWorld()
        var calls = 0
        let flow = freshFlow(
            world: world,
            fetchIdentity: { _ in
                calls += 1
                return nil
            },
            waitingPollInterval: .milliseconds(5)
        )

        flow.start()
        try await waitUntil("fresh flow waiting before cancel probe") {
            flow.state == .waitingForJournal
        }
        flow.armWaitingProbe()
        try await waitUntil("fresh flow probe made first call") {
            calls > 0
        }
        flow.cancelWaitingProbe()
        let callsAfterCancel = calls
        try await Task.sleep(for: .milliseconds(20))

        #expect(calls == callsAfterCancel)
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
        let message = "the journal app isn't available yet. " + "sol is keeping everything safe on this mac"

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
            existingHandoff: .none,
            setupComplete: true
        )) == .completed)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: nil,
            installedTrusted: true,
            running: false,
            existingHandoff: .none,
            setupComplete: false
        )) == .aborted(.missingJournalPath))

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: false,
            running: false,
            existingHandoff: .none,
            setupComplete: false
        )) == .acquiring(.fetchingAppcast))

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: false,
            existingHandoff: .migration,
            setupComplete: false
        )) == .launchingJournal)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: true,
            existingHandoff: .migration,
            setupComplete: false
        )) == .waitingForAdoption)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: true,
            existingHandoff: .none,
            setupComplete: false
        )) == .authGate)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: false,
            existingHandoff: .none,
            setupComplete: true
        )) == .authGate)
    }

    @Test func resumeDerivationRoutesForeignHandoffsToWriter() {
        let journalPath = "/tmp/journal"

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: false,
            existingHandoff: .foreign,
            setupComplete: false
        )) == .writingHandoff)

        #expect(deriveResumeState(probes: JournalHandoffResumeProbes(
            serviceMode: .bundled,
            journalPath: journalPath,
            installedTrusted: true,
            running: true,
            existingHandoff: .foreign,
            setupComplete: false
        )) == .writingHandoff)
    }

    @Test func postFlipNeverReentersMigration() async throws {
        let world = installedWorld(serviceMode: .external)

        let result = await world.run()

        #expect(result == .completed)
        #expect(world.appcast.requestedURLs.count == 0)
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
        #expect(world.appcast.requestedURLs.count == 0)
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

    private func freshFlow(
        world: TestWorld,
        fetchIdentity: @escaping @MainActor @Sendable (String) async -> JournalMark? = { _ in nil },
        waitingPollInterval: Duration = .milliseconds(1),
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) -> FreshJournalFlow {
        FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: world.dependencies.makeAcquirer(),
            runningJournal: world.runningJournal,
            trustVerifier: world.trustVerifier,
            fetchIdentity: fetchIdentity,
            waitingPollInterval: waitingPollInterval,
            sleep: sleep
        ))
    }

    private func onDiskAdoptionFlow(world: TestWorld) -> OnDiskJournalAdoptionFlow {
        OnDiskJournalAdoptionFlow(dependencies: OnDiskJournalAdoptionFlowDependencies(
            acquirer: world.dependencies.makeAcquirer(),
            runningJournal: world.runningJournal,
            trustVerifier: world.trustVerifier,
            handoffFileURL: world.dependencies.handoffFileURL,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 1_234) },
            discoveryCapableBuild: JournalHandoffConstants.discoveryCapableJournalBuild
        ))
    }

    private func waitUntil(
        _ description: String,
        attempts: Int = 200,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(description)")
    }

    private func expectFreshFlowFailure(
        world: TestWorld,
        _ expectedFailure: JournalHandoffFailure
    ) async throws {
        let flow = freshFlow(world: world)

        flow.start()
        try await waitUntil("fresh flow failure") {
            if case .failed = flow.state {
                return true
            }
            return false
        }

        #expect(flow.state == .failed(expectedFailure))
        #expect(!FileManager.default.fileExists(atPath: world.installedJournalURL.path))
        #expect(world.runningJournal.activatingLaunches == 0)
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
    let feedResolver: FakeAppcastFeedResolver
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
        let feedResolver = FakeAppcastFeedResolver()
        self.feedResolver = feedResolver
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
            appcastFeedResolver: { feedResolver.resolve() },
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

    func selectFeed(_ selection: JournalHandoffFeedSelection) {
        feedResolver.selection = selection
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
private final class FakeAppcastFeedResolver {
    var selection = productionFeedSelection
    var calls = 0

    func resolve() -> JournalHandoffFeedSelection {
        calls += 1
        return selection
    }
}

@MainActor
private final class FakeAppcastClient: AppcastClient {
    let data: Data
    var failure: JournalHandoffFailure?
    var beforeReturn: (@MainActor () async -> Void)?
    var requestedURLs: [URL] = []

    init(data: Data) {
        self.data = data
    }

    func fetchAppcast(from url: URL) async throws -> Data {
        requestedURLs.append(url)
        if let beforeReturn {
            await beforeReturn()
        }
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
    var removeAppAfterMount = false
    var mounts = 0
    var detaches = 0

    func mount(dmgURL: URL) async throws -> MountedDiskImage {
        mounts += 1
        let mountPoint = tempRoot.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let appURL = mountPoint.appendingPathComponent("journal.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try writeJournalInfoPlist(at: appURL, build: 9)
        try Data("app".utf8).write(to: appURL.appendingPathComponent("marker"))
        if removeAppAfterMount {
            try? FileManager.default.removeItem(at: appURL)
        }
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
    var calls = 0
    var onCall: (() -> Void)?

    func testPairedIngestConnection(appState _: AppState) async -> String? {
        calls += 1
        onCall?()
        return failure
    }
}

@MainActor
private final class FakeRunningJournalController: RunningJournalController {
    var installed: URL?
    var running = false
    var refusesTerminate = false
    var launches = 0
    var activatingLaunches = 0
    var terminateCalls = 0
    var launchedURLs: [URL] = []
    var activatedURLs: [URL] = []

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
        launchedURLs.append(url)
        running = true
    }

    func launchJournalActivating(at url: URL) throws {
        activatingLaunches += 1
        activatedURLs.append(url)
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
        appState.clearLastSuccessfulJournalContact()
        appState.updateConfig(config)
    }

    func triggerSync(appState: AppState) {
        triggerSyncCount += 1
    }
}

private func readHandoff(at url: URL) throws -> JournalHandoff {
    try JSONDecoder().decode(JournalHandoff.self, from: Data(contentsOf: url))
}

private func writeHandoff(
    at url: URL,
    journalRootPath: String,
    provenance: String
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let handoff = JournalHandoff(
        journalRootPath: journalRootPath,
        observerName: "existing-observer",
        provenance: provenance,
        timestamp: Date(timeIntervalSince1970: 999)
    )
    try JSONEncoder().encode(handoff).write(to: url, options: .atomic)
}

private func writeJournalInfoPlist(at appURL: URL, build: Int) throws {
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": JournalHandoffConstants.journalBundleIdentifier,
        "CFBundleName": "journal",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0.\(build - 1)",
        "CFBundleVersion": "\(build)",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
}

private func journalBuild(at appURL: URL) -> Int? {
    let plistURL = appURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let raw = plist["CFBundleVersion"]
    else {
        return nil
    }
    if let value = raw as? String {
        return Int(value)
    }
    if let value = raw as? NSNumber {
        return value.intValue
    }
    return nil
}

private var productionFeedSelection: JournalHandoffFeedSelection {
    JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production)
}

private var stagingFeedSelection: JournalHandoffFeedSelection {
    JournalHandoffFeedSelection(url: JournalHandoffConstants.stagingAppcastURL, feed: .staging)
}

private var rejectedFeedSelection: JournalHandoffFeedSelection {
    JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .rejectedOverride)
}

private struct IsolatedDefaults {
    let suiteName: String
    let defaults: UserDefaults

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func makeIsolatedDefaults() throws -> IsolatedDefaults {
    let suiteName = "app.solstone.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return IsolatedDefaults(suiteName: suiteName, defaults: defaults)
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
