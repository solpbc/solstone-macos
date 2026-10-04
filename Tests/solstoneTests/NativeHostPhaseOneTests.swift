// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import Testing
@testable import solstone

private enum NativeHostTestError: Error { case unexpected }

private func nativeHostVendorRoot(filePath: String = #filePath) -> URL {
    let file = URL(fileURLWithPath: filePath)
    return file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("vendor", isDirectory: true)
}

private func nativeHostProjection() throws -> BrowserContractProjection {
    try BrowserContractProjection(rootURL: nativeHostVendorRoot())
}

@Suite("NativeHostFrame")
struct NativeHostFrameTests {
    @Test func helperFallbackMatchesTheVendoredProjection() throws {
        let projection = try nativeHostProjection()
        #expect(BrowserHostLimits(projection: projection) == .helperFallback)
        #expect(projection.caps.extensionToHost == 33_554_432)
        #expect(projection.caps.hostToExtension == 65_536)
        #expect(projection.caps.control == 65_536)
        #expect(projection.policy.partialFrameMs == 30_000)
    }

    @Test func fragmentedLargeFrameCompletesAndDecodesAsAProtocolHello() throws {
        let limits = BrowserHostLimits(extensionToHost: 1_000_000, hostToExtension: 65_536, control: 65_536, partialFrameMs: 30_000)
        let body = Data(repeating: 0x61, count: 256 * 1024)
        let encoded = try NativeHostFrameCodec.encode(body, direction: .extensionToHost, limits: limits)
        var decoder = NativeHostFrameDecoder(direction: .extensionToHost, limits: limits)
        var output: [Data] = []
        var offset = 0
        while offset < encoded.count {
            let end = min(encoded.count, offset + 4093)
            output += try decoder.append(Data(encoded[offset..<end]))
            offset = end
        }
        #expect(output == [body])
        #expect(decoder.retainedByteCount == 0)

        let projection = try nativeHostProjection()
        let hello = Data("{\"type\":\"hello\",\"protocol\":1,\"version\":\"1.2.0\",\"brand\":\"chrome\",\"inst\":\"instance-one\"}".utf8)
        let framed = try NativeHostFrameCodec.encode(hello, direction: .extensionToHost, limits: BrowserHostLimits(projection: projection))
        var helloDecoder = NativeHostFrameDecoder(direction: .extensionToHost, limits: BrowserHostLimits(projection: projection))
        let payload = try #require(try helloDecoder.append(framed).first)
        let result = BrowserPayloadDecoder.decode(bytes: payload, direction: "extension_to_host", projection: projection)
        guard case .accept(.hello) = result else {
            Issue.record("valid framed hello did not reach the payload decoder")
            return
        }
    }

    @Test func oversizedDeclaredLengthIsRejectedBeforeBodyRetention() {
        let limits = BrowserHostLimits(extensionToHost: 100, hostToExtension: 64, control: 64, partialFrameMs: 30_000)
        var decoder = NativeHostFrameDecoder(direction: .extensionToHost, limits: limits)
        #expect(throws: NativeHostFrameError.oversized) {
            try decoder.append(Data([101, 0, 0, 0]))
        }
        #expect(decoder.retainedByteCount == 0)
        #expect(decoder.declaredLength == nil)
    }

    @Test func truncationInvalidUTF8AndResetDoNotInventAFrame() throws {
        var prefixDecoder = NativeHostFrameDecoder(direction: .extensionToHost)
        _ = try prefixDecoder.append(Data([4, 0]))
        #expect(throws: NativeHostFrameError.truncatedPrefix) { try prefixDecoder.disconnect() }

        var bodyDecoder = NativeHostFrameDecoder(direction: .extensionToHost)
        _ = try bodyDecoder.append(Data([5, 0, 0, 0, 0x61, 0x62]))
        #expect(throws: NativeHostFrameError.truncatedBody) { try bodyDecoder.disconnect() }

        var invalidDecoder = NativeHostFrameDecoder(direction: .extensionToHost)
        #expect(throws: NativeHostFrameError.invalidUTF8) {
            try invalidDecoder.append(Data([1, 0, 0, 0, 0xff]))
        }

        var resetDecoder = NativeHostFrameDecoder(direction: .extensionToHost)
        _ = try resetDecoder.append(Data([4, 0, 0]))
        resetDecoder.reset()
        let valid = try NativeHostFrameCodec.encode(Data("test".utf8), direction: .extensionToHost)
        #expect(try resetDecoder.append(valid) == [Data("test".utf8)])
    }

    @Test func repliesAreCappedAtTheHostControlLimit() throws {
        let limits = BrowserHostLimits.helperFallback
        let allowed = Data(repeating: 0x61, count: limits.hostToExtension)
        #expect(try NativeHostFrameCodec.encode(allowed, direction: .hostToExtension, limits: limits).count == limits.hostToExtension + 4)
        #expect(throws: NativeHostFrameError.oversized) {
            try NativeHostFrameCodec.encode(Data(repeating: 0x61, count: limits.hostToExtension + 1), direction: .hostToExtension, limits: limits)
        }
        #expect(!NativeHostSocketPath.fits(String(repeating: "a", count: NativeHostSocketPath.sunPathBytes)))
    }
}

@Suite("NativeHostArgv")
struct NativeHostArgvTests {
    @Test func chromeEdgeAndFirefoxIdentifyProductionAndDevelopment() throws {
        let allowlist = try NativeHostAllowlist(authorityJSON: nativeHostProjection().authorityJsonData)
        for id in [allowlist.production.chrome, allowlist.production.edge] {
            #expect(try NativeHostArgv.parse(["chrome-extension://\(id)/"], allowlist: allowlist).mode == .production)
        }
        for id in [allowlist.development.chrome, allowlist.development.edge] {
#if SOLSTONE_BROWSER_DEVELOPMENT_HOST
            #expect(try NativeHostArgv.parse(["chrome-extension://\(id)/"], allowlist: allowlist).mode == .development)
#else
            #expect(throws: NativeHostArgvError.rejected) {
                try NativeHostArgv.parse(["chrome-extension://\(id)/"], allowlist: allowlist)
            }
#endif
        }
        #expect(try NativeHostArgv.parse(["/manifest with spaces.json", allowlist.production.firefox], allowlist: allowlist) ==
            NativeHostIdentity(brandHint: .firefox, mode: .production))
#if SOLSTONE_BROWSER_DEVELOPMENT_HOST
        #expect(try NativeHostArgv.parse(["/manifest.json", allowlist.development.firefox], allowlist: allowlist) ==
            NativeHostIdentity(brandHint: .firefox, mode: .development))
#else
        #expect(throws: NativeHostArgvError.rejected) {
            try NativeHostArgv.parse(["/manifest.json", allowlist.development.firefox], allowlist: allowlist)
        }
#endif
    }

    @Test func allowlistIsReadFromAuthorityHostsAndIds() throws {
        let projection = try nativeHostProjection()
        let allowlist = try NativeHostAllowlist(authorityJSON: projection.authorityJsonData)
        #expect(allowlist.production.chrome == projection.prodHosts.chromeId)
        #expect(allowlist.production.edge == projection.prodHosts.edgeId)
        #expect(allowlist.production.firefox == projection.prodHosts.firefoxId)
        #expect(allowlist.development.chrome == projection.devHosts.chromeId)
        #expect(allowlist.development.edge == projection.devHosts.edgeId)
        #expect(allowlist.development.firefox == projection.devHosts.firefoxId)
    }

    @Test func malformedMixedAndUnknownArgumentsFailClosed() throws {
        let allowlist = try NativeHostAllowlist(authorityJSON: nativeHostProjection().authorityJsonData)
        let validChrome = "chrome-extension://\(allowlist.production.chrome)/"
        #expect(throws: NativeHostArgvError.rejected) { try NativeHostArgv.parse([], allowlist: allowlist) }
        #expect(throws: NativeHostArgvError.rejected) { try NativeHostArgv.parse([validChrome, "parent_window"], allowlist: allowlist) }
        #expect(throws: NativeHostArgvError.rejected) { try NativeHostArgv.parse([validChrome, allowlist.production.firefox], allowlist: allowlist) }
        #expect(throws: NativeHostArgvError.rejected) { try NativeHostArgv.parse(["/manifest.json"], allowlist: allowlist) }
        #expect(throws: NativeHostArgvError.rejected) { try NativeHostArgv.parse(["/manifest.json", "unknown@example.invalid"], allowlist: allowlist) }
        #expect(throws: NativeHostArgvError.rejected) { try NativeHostArgv.parse(["chrome-extension://unknown/"], allowlist: allowlist) }
    }

    @Test func terminalReducerCannotInventAcceptance() {
        var failed = NativeHostRelayReducer()
        let forwarded = failed.reduce(.extensionFrame)
        let stopped = failed.reduce(.forwardFailure)
        let afterStop = failed.reduce(.hostAccepted)
        #expect(forwarded == .forwardToApp)
        #expect(stopped == .stop)
        #expect(afterStop == .stop)
        #expect(!failed.forwardedAcceptance)

        for event in [NativeHostRelayEvent.stdinEOF, .sigterm, .hostBye, .hostUnsupported, .appLoss] {
            var reducer = NativeHostRelayReducer()
            let first = reducer.reduce(event)
            let second = reducer.reduce(.hostAccepted)
            #expect(first == .stop)
            #expect(second == .stop)
            #expect(!reducer.forwardedAcceptance)
        }
    }
}

@Suite("NativeHostSessions")
struct NativeHostSessionsTests {
    @Test func budgetsRefuseBeforeOverReservationWithoutDisturbingExistingSessions() {
        let limits = BrowserHostLimits(
            extensionToHost: 100,
            hostToExtension: 64,
            control: 64,
            partialFrameMs: 30_000,
            sessions: 2,
            simultaneousLargeAssemblies: 1,
            retainedInputBytes: 100,
            pendingReplyPerSession: 64,
            pendingReplyTotal: 96
        )
        let budget = BrowserHostSessionBudget(limits: limits)
        let first = UUID()
        let second = UUID()
        #expect(budget.open(first))
        #expect(budget.open(second))
        #expect(!budget.open(UUID()))
        #expect(budget.reserveInput(80, large: true))
        #expect(!budget.reserveInput(21, large: false))
        #expect(!budget.reserveInput(1, large: true))
        budget.releaseInput(80, large: true)
        #expect(budget.reserveInput(100, large: false))
        #expect(budget.reserveReply(64, for: first))
        #expect(!budget.reserveReply(33, for: second))
        budget.releaseReply(64, for: first)
        #expect(budget.reserveReply(32, for: second))
    }

    @Test func updateEligibilityRequiresFreshFirstAppBehindHello() {
        let appBehind = BrowserDecodeResult.unsupported(protocol: 1, behind: "app")
        let extensionBehind = BrowserDecodeResult.unsupported(protocol: 1, behind: "extension")
        #expect(BrowserHostUpdateEligibility.shouldRequest(decoded: appBehind, firstMessage: true, fresh: true, allowlisted: true, modeMatches: true, obsolete: false))
        #expect(!BrowserHostUpdateEligibility.shouldRequest(decoded: extensionBehind, firstMessage: true, fresh: true, allowlisted: true, modeMatches: true, obsolete: false))
        #expect(!BrowserHostUpdateEligibility.shouldRequest(decoded: appBehind, firstMessage: false, fresh: true, allowlisted: true, modeMatches: true, obsolete: false))
        #expect(!BrowserHostUpdateEligibility.shouldRequest(decoded: appBehind, firstMessage: true, fresh: false, allowlisted: true, modeMatches: true, obsolete: false))
        #expect(!BrowserHostUpdateEligibility.shouldRequest(decoded: appBehind, firstMessage: true, fresh: true, allowlisted: false, modeMatches: true, obsolete: false))
        #expect(!BrowserHostUpdateEligibility.shouldRequest(decoded: appBehind, firstMessage: true, fresh: true, allowlisted: true, modeMatches: false, obsolete: false))
        #expect(!BrowserHostUpdateEligibility.shouldRequest(decoded: appBehind, firstMessage: true, fresh: true, allowlisted: true, modeMatches: true, obsolete: true))
    }

    @Test func updateRequestsCoalesceForFiveMinutesAndStampBeforeTheCheck() async {
        let clock = NativeHostLockedDate(Date(timeIntervalSince1970: 100))
        let checks = NativeHostLockedCounter()
        let gate = BrowserHostUpdateGate(clock: { clock.value }) {
            checks.increment()
        }
        #expect(await gate.requestForAppBehindHello())
        #expect(checks.value == 1)
        #expect(await gate.lastRequestedAt == Date(timeIntervalSince1970: 100))
        clock.advance(299)
        #expect(!(await gate.requestForAppBehindHello()))
        #expect(checks.value == 1)
        clock.advance(1)
        #expect(await gate.requestForAppBehindHello())
        #expect(checks.value == 2)
    }

    @Test func reconnectCountsOnlyConnectedProfiles() {
        var table = BrowserHostProfileTable()
        let connected = BrowserHostProfile(
            lastSeen: Date(timeIntervalSince1970: 10),
            handshake: .compatible,
            byeReason: nil,
            leaseExpiry: Date(timeIntervalSince1970: 15)
        )
        let chrome = UUID()
        table.record(sessionID: chrome, brand: .chrome, inst: "chrome-1", profile: connected)
        table.record(sessionID: UUID(), brand: .firefox, inst: "firefox-1", profile: connected)
        table.disconnect(sessionID: chrome)
        #expect(table.count(.chrome) == 0)
        #expect(table.count(.firefox) == 1)
        table.record(sessionID: UUID(), brand: .chrome, inst: "chrome-2", profile: connected)
        #expect(table.count(.chrome) == 1)
        #expect(table.count(.edge) == 0)
    }
}

@Suite("NativeHostRegistration")
struct NativeHostRegistrationTests {
    @Test func repairEscapesPathsSeparatesModesAndIsIdempotent() throws {
        let home = URL(fileURLWithPath: "/fake-home", isDirectory: true)
        let helper = home.appendingPathComponent("Apps/A \"quoted\" helper.app/Contents/MacOS/solstone-browser-host")
        let fs = NativeHostMemoryFileSystem(home: home, helper: helper)
        let registration = BrowserHostRegistration(contractRoot: nativeHostVendorRoot(), home: home, helperURL: helper, fileSystem: fs)

        let first = registration.repair(mode: .production)
        #expect(first.isComplete)
        #expect(first.changedAny)
        let writeCount = fs.writeCount
        let second = registration.repair(mode: .production)
        #expect(second.isComplete)
        #expect(!second.changedAny)
        #expect(fs.writeCount == writeCount)

        let projection = try nativeHostProjection()
        for outcome in second.outcomes.values {
            let path = try #require(outcome.path)
            let data = try fs.read(URL(fileURLWithPath: path))
            let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(manifest["name"] as? String == projection.prodHosts.host)
            #expect(manifest["path"] as? String == helper.path)
            #expect(String(decoding: data, as: UTF8.self).contains("\\\"quoted\\\""))
        }
    }

    @Test func checkOnlyIsReadOnlyAndMissingDirectoriesAreIncomplete() {
        let home = URL(fileURLWithPath: "/fake-check-home", isDirectory: true)
        let helper = home.appendingPathComponent("Solstone.app/Contents/MacOS/solstone-browser-host")
        let fs = NativeHostMemoryFileSystem(home: home, helper: helper)
        let report = BrowserHostRegistration(contractRoot: nativeHostVendorRoot(), home: home, helperURL: helper, fileSystem: fs).check(mode: .production)
        #expect(report.outcomes.values.allSatisfy { $0.state == .changed && $0.reasonCode == "manifest_missing" })
        #expect(!report.outcomes.values.allSatisfy { $0.state == .ready })
        #expect(fs.writeCount == 0)
        #expect(fs.createCount == 0)
    }

    @Test func developmentRegistrationRequiresAnExplicitDevelopmentBuild() {
        let home = URL(fileURLWithPath: "/fake-development-home", isDirectory: true)
        let helper = home.appendingPathComponent("Solstone.app/Contents/MacOS/solstone-browser-host")
        let fs = NativeHostMemoryFileSystem(home: home, helper: helper)
        let registration = BrowserHostRegistration(contractRoot: nativeHostVendorRoot(), home: home, helperURL: helper, fileSystem: fs)
        let report = registration.repair(mode: .development)
#if SOLSTONE_BROWSER_DEVELOPMENT_HOST
        #expect(report.isComplete)
        #expect(report.changedAny)
        #expect(registration.check(mode: .development).isComplete)
#else
        #expect(!report.isComplete)
        #expect(!report.changedAny)
        #expect(report.outcomes.values.allSatisfy { $0.state == .refused && $0.reasonCode == "development_host_disabled" })
        #expect(registration.check(mode: .development).outcomes.values.allSatisfy { $0.state == .refused })
        #expect(fs.writeCount == 0)
        #expect(fs.createCount == 0)
#endif
    }

    @Test func productionPathAndUnsafeRegistrationParentsAreRefusedWithoutWrites() {
        let home = URL(fileURLWithPath: "/fake-prod-home", isDirectory: true)
        let temporary = home.appendingPathComponent(".build/solstone-browser-host")
        let tempFS = NativeHostMemoryFileSystem(home: home, helper: temporary)
        let tempReport = BrowserHostRegistration(contractRoot: nativeHostVendorRoot(), home: home, helperURL: temporary, fileSystem: tempFS).repair()
        #expect(tempReport.outcomes.values.allSatisfy { $0.reasonCode == "helper_path_not_bundled" })
        #expect(tempFS.writeCount == 0)

        let appHelper = home.appendingPathComponent("Applications/Solstone.app/Contents/MacOS/solstone-browser-host")
        let symlinkFS = NativeHostMemoryFileSystem(home: home, helper: appHelper)
        let edgeParent = home.appendingPathComponent("Library/Application Support/Microsoft Edge", isDirectory: true)
        symlinkFS.addEntry(edgeParent, kind: .symlink, uid: geteuid())
        let report = BrowserHostRegistration(contractRoot: nativeHostVendorRoot(), home: home, helperURL: appHelper, fileSystem: symlinkFS).repair()
        #expect(report.outcomes[.edge]?.state == .refused)
        #expect(report.outcomes[.chrome]?.state == .changed)
        #expect(report.outcomes[.firefox]?.state == .changed)
    }

    @Test func endpointFenceDoubleOnlyRemovesVerifiedStaleSocketAndProtectsSuccessor() {
        let uid = geteuid()
        let original = BrowserHostEndpointIdentity(kind: .socket, uid: uid, device: 7, inode: 11)
        var stale = NativeHostEndpointFenceDouble(first: original, second: original, lockAvailable: true)
        let removedStale = stale.repair(effectiveUID: uid)
        #expect(removedStale)
        #expect(stale.unlinked)

        var live = NativeHostEndpointFenceDouble(first: original, second: original, lockAvailable: false)
        let removedLive = live.repair(effectiveUID: uid)
        #expect(!removedLive)
        #expect(!live.unlinked)

        let foreign = BrowserHostEndpointIdentity(kind: .socket, uid: uid + 1, device: 7, inode: 11)
        var foreignEntry = NativeHostEndpointFenceDouble(first: foreign, second: foreign, lockAvailable: true)
        let removedForeign = foreignEntry.repair(effectiveUID: uid)
        #expect(!removedForeign)
        #expect(!foreignEntry.unlinked)

        let successor = BrowserHostEndpointIdentity(kind: .socket, uid: uid, device: 7, inode: 12)
        #expect(!BrowserHostEndpointRepairPolicy.mayCleanup(
            created: BrowserHostSocketIdentity(device: original.device, inode: original.inode),
            current: successor,
            rootVerified: true,
            effectiveUID: uid
        ))
    }
}

@Suite("NativeHostLifecycle")
struct NativeHostLifecycleTests {
    @Test func staleGenerationCannotCloseReplacementAdmission() {
        let gate = BrowserHostAdmissionGate()
        #expect(gate.prepare(generation: 4))
        gate.install(listenerFD: -1, generation: 4)
        #expect(gate.isOpen(generation: 4))
        #expect(gate.prepare(generation: 5))
        gate.install(listenerFD: -1, generation: 5)
        #expect(!gate.commitClose(reason: .ordinaryQuit, generation: 4))
        #expect(!gate.commitClose(reason: .ordinaryQuit, generation: 5))
        #expect(gate.isOpen(generation: 5))
        #expect(gate.commitClose(reason: .updaterInstall, generation: 6))
        #expect(!gate.isOpen(generation: 5))
        #expect(gate.committedClose(generation: 6)?.0 == .updaterInstall)
    }

    @Test func ownerStatusProjectionPreservesCustodyPresenceAndFailure() {
        let fullStatus: [String: Any] = [
            "capture": "paused",
            "delivery": "failed",
            "failure": "relay_unavailable",
            "custody": ["full": true, "stale": true]
        ]
        let projected = BrowserHostSnapshotProjection.fromOwnerStatus(fullStatus, intakeEnabled: false, listener: .available)
        #expect(projected.capture == "paused")
        #expect(projected.delivery == "failed")
        #expect(projected.failureCode == "relay_unavailable")
        #expect(projected.custodyPresent)
        #expect(projected.custodyFull)
        #expect(projected.custodyStale)

        let omitted = BrowserHostSnapshotProjection.fromOwnerStatus(["capture": "permitted"], intakeEnabled: true)
        #expect(!omitted.custodyPresent)
        #expect(!omitted.custodyFull)
        #expect(!omitted.custodyStale)
    }

    @Test func quitCommitRejectsANewHello() {
        let gate = BrowserHostAdmissionGate()
        #expect(gate.prepare(generation: 1))
        gate.install(listenerFD: -1, generation: 1)
        #expect(gate.isOpen())
        #expect(!gate.commitClose(reason: .ordinaryQuit, generation: 1))
        #expect(gate.isOpen())
        #expect(gate.commitClose(reason: .ordinaryQuit, generation: 2))
        #expect(!gate.isOpen())
    }

    @Test func quiescenceRejectsReopenAndRecoveryKeepsOneListener() {
        var life = BrowserHostLifecycle()
        life.install(generation: 3)
        #expect(life.admitsHello)
        #expect(life.listenerCount == 1)
        #expect(life.timerCount == 0)
        let rejectedUpdate = life.beginClose(reason: .updaterInstall, generation: 3)
        #expect(!rejectedUpdate)
        let beganUpdate = life.beginClose(reason: .updaterInstall, generation: 4)
        #expect(beganUpdate)
        #expect(life.quiescence)
        #expect(!life.admitsHello)
        #expect(life.timerCount == 1)
        let staleClose = life.beginClose(reason: .ordinaryQuit, generation: 2)
        #expect(!staleClose)
        life.prepareRecovery(generation: 4)
        life.install(generation: 4)
        #expect(life.listenerCount == 1)
        #expect(life.timerCount == 0)
        #expect(life.admitsHello)
        let oldCleanup = life.finishQuiescence(generation: 3)
        #expect(!oldCleanup)
        #expect(life.listenerCount == 1)
        var quiet = BrowserHostLifecycle()
        quiet.install(generation: 8)
        let beganQuiet = quiet.beginClose(reason: .updaterInstall, generation: 9)
        let finishedQuiet = quiet.finishQuiescence(generation: 9)
        #expect(beganQuiet)
        #expect(finishedQuiet)
        #expect(quiet.listenerCount == 0)
        #expect(quiet.timerCount == 0)
        #expect(!quiet.admitsHello)
    }

    @Test func preferenceOffClosesPermittedCaptureAndKeepsDelivery() {
        let held: [String: Any] = [
            "capture": "permitted",
            "delivery": "kept_locally",
            "custody": ["full": false, "stale": true]
        ]
        let off = BrowserIntakeOwner.projectingIntake(false, status: held)
        #expect(off["capture"] as? String == "intake_off")
        #expect(off["delivery"] as? String == "kept_locally")
        #expect((off["custody"] as? [String: Bool])?["stale"] == true)
        let unavailable: [String: Any] = ["capture": "unavailable", "delivery": "kept_locally"]
        #expect(BrowserIntakeOwner.projectingIntake(false, status: unavailable)["capture"] as? String == "unavailable")
        let paused: [String: Any] = ["capture": "paused", "delivery": "failed", "failure": "relay_unavailable"]
        let projected = BrowserIntakeOwner.projectingIntake(false, status: paused)
        #expect(projected["capture"] as? String == "intake_off")
        #expect(projected["delivery"] as? String == "failed")
        #expect(projected["failure"] as? String == "relay_unavailable")
        #expect(BrowserIntakeOwner.projectingIntake(true, status: paused)["capture"] as? String == "paused")
    }

    @Test @MainActor func timedPauseDeadlineSurvivesReapply() {
        let scheduled = NativeHostLockedCounter()
        let manager = PauseManager { _, _ in
            scheduled.increment()
            return NativeHostPauseTimer()
        }
        var intakeClosures = 0
        var resumeClosures = 0
        manager.onPauseIntake = { intakeClosures += 1 }
        manager.onResumeIntake = { resumeClosures += 1 }
        manager.pause(for: .seconds(90))
        let deadline = manager.pauseState.expirationDate
        manager.reapply()
        #expect(manager.isPaused)
        #expect(manager.pauseState.expirationDate == deadline)
        #expect(!manager.pauseState.isIndefinite)
        #expect(intakeClosures == 2)
        #expect(resumeClosures == 0)
        #expect(scheduled.value == 1)
    }
}

@Suite("NativeHostSpoolComposition")
struct NativeHostSpoolCompositionTests {
    @Test func acceptedReceiptsAndCustodySurviveOwnerRecreation() async throws {
        let projection = try nativeHostProjection()
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-native-host-spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = NativeHostCompositionClock(Date(timeIntervalSince1970: 1_700_000_100), TimeZone(secondsFromGMT: 0)!)
        let route = BrowserIntakeRouteState()
        let injector = BrowserIntakeIOInjector()
        let makeOwner: () throws -> BrowserIntakeOwner = {
            try BrowserIntakeOwner.start(
                spoolRoot: root,
                projection: projection,
                credentialSnapshot: BrowserCredentialSnapshot(identityToken: "composition-token"),
                clock: clock,
                transport: NativeHostNoopTransport(),
                routeResolver: HomeBaseURLResolver { .url("http://127.0.0.1:5015") },
                syncPaused: { true },
                ioInjector: injector,
                routeState: route
            )
        }
        let owner = try makeOwner()
        await owner.start()
        let hello = Data("{\"type\":\"hello\",\"protocol\":1,\"version\":\"1.2.0\",\"brand\":\"chrome\",\"inst\":\"composition-instance\"}".utf8)
        guard case .message(let helloReply) = await owner.accept(bytes: hello, direction: "extension_to_host") else {
            Issue.record("hello was not answered")
            return
        }
        let helloObject = try #require(try JSONSerialization.jsonObject(with: helloReply) as? [String: Any])
        #expect(helloObject["type"] as? String == "hello_ack")
        _ = try BrowserPayloadDecoder.validatedHostMessage(helloObject, projection: projection)
        let facts = await owner.currentFacts()
        #expect(facts.capture == "permitted")
        #expect(facts.intakeEnabled)

        let generation = try #require(owner.store.getDestinationGeneration())
        let queuedAt = UInt64(clock.wallNow().timeIntervalSince1970 * 1000)
        let snapshotBatch = nativeHostBatch(generation: generation, id: "11111111111111111111111111111111", queuedAtMs: queuedAt, record: "snapshot")
        let accepted = try nativeHostAccepted(try await owner.accept(bytes: snapshotBatch, direction: "extension_to_host"))
        #expect(accepted["result"] as? String == "accepted")
        let duplicate = try nativeHostAccepted(try await owner.accept(bytes: snapshotBatch, direction: "extension_to_host"))
        #expect(duplicate["result"] as? String == "duplicate")
        let periodID = try #require(accepted["period_id"] as? String)

        let liveDelta = nativeHostBatch(generation: generation, id: "55555555555555555555555555555555", queuedAtMs: queuedAt + 1, record: "delta")
        #expect(try nativeHostAccepted(await owner.accept(bytes: liveDelta, direction: "extension_to_host"))["result"] as? String == "accepted")
        clock.advance(seconds: 300)
        owner.authority.poll(now: clock.wallNow())
        let delta = nativeHostBatch(generation: generation, id: "22222222222222222222222222222222", queuedAtMs: queuedAt + 1, record: "delta")
        let deltaResult = try nativeHostAccepted(try await owner.accept(bytes: delta, direction: "extension_to_host"))
        #expect(deltaResult["reason"] as? String == "snapshot_required")
        let savedSnapshot = nativeHostBatch(generation: generation, id: "33333333333333333333333333333333", queuedAtMs: queuedAt + 2, record: "snapshot")
        #expect(try nativeHostAccepted(try await owner.accept(bytes: savedSnapshot, direction: "extension_to_host"))["result"] as? String == "accepted")

        injector.setFailure { point in if point == .commit { throw NativeHostTestError.unexpected } }
        let failed = await owner.accept(bytes: nativeHostBatch(generation: generation, id: "44444444444444444444444444444444", queuedAtMs: queuedAt + 3, record: "snapshot"), direction: "extension_to_host")
        let failedReply = try nativeHostAccepted(failed)
        #expect(failedReply["result"] as? String == "rejected")
        #expect(failedReply["reason"] as? String == "resource_exhausted")
        injector.setFailure(nil)

        await owner.stopAndDrain()
        let restarted = try makeOwner()
        await restarted.start()
        let duplicateAfterRestart = try nativeHostAccepted(try await restarted.accept(bytes: snapshotBatch, direction: "extension_to_host"))
        #expect(duplicateAfterRestart["result"] as? String == "duplicate")
        #expect(duplicateAfterRestart["period_id"] as? String == periodID)
        restarted.stop()
    }

    @Test func custodyDeliveryAndBothBrowsersShareOneOwner() async throws {
        let projection = try nativeHostProjection()
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-native-host-spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = NativeHostCompositionClock(Date(timeIntervalSince1970: 1_700_000_100), TimeZone(secondsFromGMT: 0)!)
        let injector = BrowserIntakeIOInjector()
        let owner = try BrowserIntakeOwner.start(
            spoolRoot: root,
            projection: projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "composition-token"),
            clock: clock,
            transport: NativeHostNoopTransport(),
            routeResolver: HomeBaseURLResolver { .url("http://127.0.0.1:5015") },
            syncPaused: { true },
            ioInjector: injector,
            routeState: BrowserIntakeRouteState()
        )
        await owner.start()
        defer { owner.stop() }

        let chromeHello = Data("{\"type\":\"hello\",\"protocol\":1,\"version\":\"1.2.0\",\"brand\":\"chrome\",\"inst\":\"composition-chrome\"}".utf8)
        let firefoxHello = Data("{\"type\":\"hello\",\"protocol\":1,\"version\":\"1.2.0\",\"brand\":\"firefox\",\"inst\":\"composition-firefox\"}".utf8)
        let opened = try await nativeHostDecodedState(await owner.accept(bytes: chromeHello, direction: "extension_to_host"), projection: projection)
        #expect(opened.capture == "permitted")
        #expect(opened.custodyFull == false)
        #expect(opened.custodyStale == false)
        _ = try await nativeHostDecodedState(await owner.accept(bytes: firefoxHello, direction: "extension_to_host"), projection: projection)

        let generation = try #require(owner.store.getDestinationGeneration())
        let queuedAt = UInt64(clock.wallNow().timeIntervalSince1970 * 1000)
        let chromeBatch = nativeHostBatch(generation: generation, id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", queuedAtMs: queuedAt, inst: "composition-chrome", record: "snapshot")
        let firefoxBatch = nativeHostBatch(generation: generation, id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", queuedAtMs: queuedAt, inst: "composition-firefox", record: "snapshot")
        let chromeAccepted = try nativeHostAccepted(await owner.accept(bytes: chromeBatch, direction: "extension_to_host"))
        let firefoxAccepted = try nativeHostAccepted(await owner.accept(bytes: firefoxBatch, direction: "extension_to_host"))
        let periodID = try #require(chromeAccepted["period_id"] as? String)
        #expect(firefoxAccepted["period_id"] as? String == periodID)
        #expect(chromeAccepted["result"] as? String == "accepted")
        let duplicate = try nativeHostAccepted(await owner.accept(bytes: chromeBatch, direction: "extension_to_host"))
        #expect(duplicate["result"] as? String == "duplicate")
        #expect(duplicate["period_id"] as? String == periodID)
        var held = try await nativeHostDecodedState(await owner.accept(bytes: chromeHello, direction: "extension_to_host"), projection: projection)
        #expect(held.delivery == "kept_locally")

        owner.authority.setPaused(true)
        let paused = try await nativeHostDecodedState(await owner.accept(bytes: chromeHello, direction: "extension_to_host"), projection: projection)
        #expect(paused.capture == "paused")
        #expect(paused.delivery == "kept_locally")
        owner.authority.setPaused(false)

        owner.store.setDeliveryFailure("relay_unavailable")
        let failed = try await nativeHostDecodedState(await owner.accept(bytes: firefoxHello, direction: "extension_to_host"), projection: projection)
        #expect(failed.delivery == "failed")
        #expect(failed.failure == "relay_unavailable")
        #expect(failed.custodyFull == false)
        owner.store.setDeliveryFailure(nil)
        held = try await nativeHostDecodedState(await owner.accept(bytes: chromeHello, direction: "extension_to_host"), projection: projection)
        #expect(held.delivery == "kept_locally")
        #expect(held.failure == nil)

        clock.advance(seconds: 604_801)
        let stale = try await nativeHostDecodedState(await owner.accept(bytes: chromeHello, direction: "extension_to_host"), projection: projection)
        #expect(stale.custodyStale)
        #expect(!stale.custodyFull)
        #expect(stale.capture == "permitted")
        #expect(stale.delivery == "kept_locally")

        let stagingDirectory = owner.store.stagingRootURL().appendingPathComponent("composition-full", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagingFile = stagingDirectory.appendingPathComponent("multipart.body")
        try Data().write(to: stagingFile)
        let injected = NativeHostInjectedSize()
        injector.setSizeOverride { url, actual in url == stagingFile ? injected.value : actual }
        try owner.store.registerStagingDirectory(stagingDirectory, reservedBytes: 0)
        injected.value = projection.policy.spoolBytes
        owner.store.setDeliveryFailure("relay_unavailable")
        let combined = try await nativeHostDecodedState(await owner.accept(bytes: chromeHello, direction: "extension_to_host"), projection: projection)
        #expect(combined.custodyFull)
        #expect(combined.custodyStale)
        #expect(combined.capture == "intake_off")
        #expect(combined.delivery == "failed")
        #expect(combined.failure == "relay_unavailable")
        let duplicateWhileFull = try nativeHostAccepted(await owner.accept(bytes: chromeBatch, direction: "extension_to_host"))
        #expect(duplicateWhileFull["result"] as? String == "duplicate")
        #expect(duplicateWhileFull["period_id"] as? String == periodID)
        let blocked = await owner.accept(bytes: nativeHostBatch(generation: generation, id: "cccccccccccccccccccccccccccccccc", queuedAtMs: queuedAt, inst: "composition-chrome", record: "snapshot"), direction: "extension_to_host")
        if case .message(let bytes) = blocked {
            let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(object["result"] as? String != "accepted")
        }

        owner.store.setDeliveryFailure(nil)
        injected.value = 0
        try owner.store.releaseStagingDirectory(stagingDirectory)
        let staleOnly = try await nativeHostDecodedState(await owner.accept(bytes: firefoxHello, direction: "extension_to_host"), projection: projection)
        #expect(!staleOnly.custodyFull)
        #expect(staleOnly.custodyStale)
        #expect(staleOnly.capture == "permitted")
        #expect(staleOnly.delivery == "kept_locally")

        clock.advance(seconds: 300)
        owner.authority.poll(now: clock.wallNow())
        let boundaryDelta = nativeHostBatch(generation: generation, id: "dddddddddddddddddddddddddddddddd", queuedAtMs: UInt64(clock.wallNow().timeIntervalSince1970 * 1000), inst: "composition-chrome", record: "delta")
        let boundaryResult = try nativeHostAccepted(await owner.accept(bytes: boundaryDelta, direction: "extension_to_host"))
        #expect(boundaryResult["reason"] as? String == "snapshot_required")

        var periodIDs = Set([periodID])
        if let open = owner.store.getOpenPeriodId() { periodIDs.insert(open) }
        for id in periodIDs {
            if owner.store.getPeriod(periodId: id)?.state == "open" {
                try owner.store.finalizePeriod(periodId: id, reason: "composition", civilDate: clock.wallNow(), timeZone: clock.timeZone())
            }
        }
        let beforeReceipt = try await nativeHostDecodedState(await owner.accept(bytes: chromeHello, direction: "extension_to_host"), projection: projection)
        #expect(beforeReceipt.delivery == "kept_locally")
        for id in periodIDs {
            let period = try #require(owner.store.getPeriod(periodId: id))
            guard period.state == "finalized" else { continue }
            let proof = BrowserIngestAck(
                generation: generation,
                periodId: id,
                sha256: period.fileSha256 ?? "",
                size: UInt64(period.committedLength),
                metadata: nil,
                requestedDay: period.requestedDay ?? "",
                requestedSegment: period.requestedSegment ?? "",
                canonicalKey: period.requestedSegment,
                status: .collision
            )
            try owner.store.publishDeliveryAck(proof)
            try owner.store.releaseProven(periodId: id, binding: proof, nowMs: UInt64(clock.wallNow().timeIntervalSince1970 * 1000))
            #expect(owner.store.getPeriod(periodId: id)?.state == "delivered")
        }
        let afterReceipt = try await nativeHostDecodedState(await owner.accept(bytes: chromeHello, direction: "extension_to_host"), projection: projection)
        #expect(afterReceipt.delivery != "kept_locally")
        #expect(!afterReceipt.custodyStale)
        #expect(!afterReceipt.custodyFull)
    }
}

private final class NativeHostLockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date { lock.withLock { stored } }
    func advance(_ seconds: TimeInterval) { lock.withLock { stored = stored.addingTimeInterval(seconds) } }
}

private final class NativeHostLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

private final class NativeHostMemoryFileSystem: BrowserHostRegistrationFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private let home: URL
    private var entries: [String: BrowserHostFileInfo] = [:]
    private var files: [String: Data] = [:]
    private var failedDirectories: Set<String> = []
    private(set) var writeCount = 0
    private(set) var createCount = 0

    init(home: URL, helper: URL) {
        self.home = home.standardizedFileURL
        entries[self.home.path] = BrowserHostFileInfo(kind: .directory, uid: geteuid(), mode: 0o700)
        entries[helper.standardizedFileURL.path] = BrowserHostFileInfo(kind: .regular, uid: geteuid(), mode: 0o700)
    }

    func addEntry(_ url: URL, kind: BrowserHostFileInfo.Kind, uid: uid_t) {
        lock.withLock { entries[url.standardizedFileURL.path] = BrowserHostFileInfo(kind: kind, uid: uid, mode: 0o700) }
    }

    func failCreating(_ url: URL) { lock.withLock { failedDirectories.insert(url.standardizedFileURL.path) } }

    func info(_ url: URL) -> BrowserHostFileInfo? { lock.withLock { entries[url.standardizedFileURL.path] } }

    func read(_ url: URL) throws -> Data {
        if let data = lock.withLock({ files[url.standardizedFileURL.path] }) { return data }
        return try Data(contentsOf: url)
    }

    func createDirectory(_ url: URL) throws {
        try lock.withLock {
            if failedDirectories.contains(url.standardizedFileURL.path) { throw NativeHostTestError.unexpected }
            entries[url.standardizedFileURL.path] = BrowserHostFileInfo(kind: .directory, uid: geteuid(), mode: 0o700)
            createCount += 1
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.withLock {
            files[url.standardizedFileURL.path] = data
            entries[url.standardizedFileURL.path] = BrowserHostFileInfo(kind: .regular, uid: geteuid(), mode: 0o600)
            writeCount += 1
        }
    }

    func resolve(_ url: URL) -> URL { url.standardizedFileURL }
}

private struct NativeHostEndpointFenceDouble {
    let first: BrowserHostEndpointIdentity?
    let second: BrowserHostEndpointIdentity?
    let lockAvailable: Bool
    private(set) var unlinked = false

    mutating func repair(effectiveUID: uid_t) -> Bool {
        guard lockAvailable else { return false }
        guard let first else { return second == nil }
        guard let second, BrowserHostEndpointRepairPolicy.mayRemove(first: first, rechecked: second, rootVerified: true, effectiveUID: effectiveUID) else { return false }
        unlinked = true
        return true
    }
}

private final class NativeHostCompositionClock: BrowserIntakeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private let zone: TimeZone
    init(_ date: Date, _ zone: TimeZone) { self.date = date; self.zone = zone }
    func wallNow() -> Date { lock.withLock { date } }
    func advance(seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    func timeZone() -> TimeZone { zone }
    func now() -> Duration { .zero }
    func sleep(for duration: Duration) async { try? await Task.sleep(for: duration) }
    func sleepUntil(_ date: Date) async throws { try await Task.sleep(for: .seconds(3_600)) }
    func ageStamp() -> BrowserAgeStamp? { BrowserAgeStamp.current() }
}

private struct NativeHostNoopTransport: BrowserUploadTransport {
    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay { throw NativeHostTestError.unexpected }
    func prepareUpload(serverURL: String, day: String, segment: String, mediaFiles: [URL], metadata: [String: IngestJSONValue]?, source: String?, boundary: String, bodyURL: URL, ioInjector: BrowserIntakeIOInjector) throws -> PreparedIngestV3Upload { throw NativeHostTestError.unexpected }
    func uploadStaged(prepared: PreparedIngestV3Upload, lease: BrowserUploadLease) async -> UploadResult { .failure(NativeHostTestError.unexpected) }
}

private final class NativeHostInjectedSize: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class NativeHostPauseTimer: PauseExpiryTimer {
    func invalidate() {}
}

private func nativeHostDecodedState(_ result: BrowserIntakeAcceptResult, projection: BrowserContractProjection) async throws -> BrowserDecodedState {
    guard case .message(let bytes) = result,
          let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          object["custody"] != nil else { throw NativeHostTestError.unexpected }
    let decoded = BrowserPayloadDecoder.decode(bytes: bytes, direction: "host_to_extension", projection: projection)
    guard case .accept(.state(let state)) = decoded else { throw NativeHostTestError.unexpected }
    return state
}

private func nativeHostBatch(generation: String, id: String, queuedAtMs: UInt64, inst: String = "composition-instance", record: String) -> Data {
    let recordObject: String
    if record == "snapshot" {
        recordObject = "\"t\":\"segment_start\",\"ts\":\(queuedAtMs),\"ctx\":\"composition-context\",\"inst\":\"\(inst)\",\"blocks\":[{\"id\":\"block\",\"text\":\"synthetic page\"}]"
    } else {
        recordObject = "\"t\":\"delta\",\"ts\":\(queuedAtMs),\"ctx\":\"composition-context\",\"inst\":\"\(inst)\",\"op\":\"add\",\"block\":{\"id\":\"block\",\"text\":\"synthetic delta\"}"
    }
    return Data("{\"type\":\"batch\",\"destination_generation\":\"\(generation)\",\"inst\":\"\(inst)\",\"batch_id\":\"\(id)\",\"queued_at_ms\":\(queuedAtMs),\"records\":[{\(recordObject)}]}".utf8)
}

private func nativeHostAccepted(_ result: BrowserIntakeAcceptResult) throws -> [String: Any] {
    guard case .message(let bytes) = result,
          let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw NativeHostTestError.unexpected }
    return object
}

@Suite("BrowserHostInputRepresentation")
struct BrowserHostInputRepresentationTests {
    @Test func dataSliceKeepsOffsetAndStrictUTF8Semantics() throws {
        let projection = try nativeHostProjection()
        let hello = Data("{\"type\":\"hello\",\"protocol\":1,\"version\":\"1.2.0\",\"brand\":\"chrome\",\"inst\":\"slice-instance\"}".utf8)
        var prefixed = Data([0, 0, 0, 0]); prefixed.append(hello)
        let slice = prefixed[4...]
        #expect(slice.startIndex == 4)
        #expect(BrowserPayloadDecoder.decode(bytes: slice, direction: "extension_to_host", projection: projection)
                == BrowserPayloadDecoder.decode(bytes: hello, direction: "extension_to_host", projection: projection))
        for bytes: [UInt8] in [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]] {
            #expect(!NativeHostUTF8.isValid(Data(bytes)))
        }
        #expect(NativeHostUTF8.isValid(Data("text 👋".utf8)))
    }

    @Test func everyContractDeltaFitsTheRecordRangeCollector() throws {
        let projection = try nativeHostProjection()
        let record = "{\"t\":\"delta\",\"ts\":1,\"ctx\":\"c\",\"inst\":\"i\",\"op\":\"add\",\"block\":{\"id\":\"b\",\"text\":\"synthetic\"}}"
        let records = Array(repeating: record, count: projection.caps.deltaRecords).joined(separator: ",")
        let body = Data("{\"type\":\"batch\",\"destination_generation\":\"g\",\"inst\":\"i\",\"batch_id\":\"ffffffffffffffffffffffffffffffff\",\"queued_at_ms\":1,\"records\":[\(records)]}".utf8)
        guard case .accept(.batch(let batch)) = BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection) else {
            Issue.record("canonical maximum-record batch was refused"); return
        }
        #expect(batch.records.count == projection.caps.deltaRecords)
        #expect(batch.records.allSatisfy { !$0.rawSlice.isEmpty })
    }

    @Test func denseInputRefusesBeforeContainerReservation() throws {
        let projection = try nativeHostProjection()
        var body = Data("{\"type\":\"batch\",\"records\":[".utf8)
        for _ in 0..<600_000 { body.append(contentsOf: [48, 44]) }
        body.append(contentsOf: [48, 93, 125])
        var reserved = false
        let result = BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection,
            reserveWorkingMemory: { _ in reserved = true; return true })
        #expect(result == .refuse(BrowserRefusal(code: "resource_exhausted")))
        #expect(!reserved)
    }

    @Test func oversizedControlUsesFinalEscapedRootTypeBeforeTreeReservation() throws {
        let projection = try nativeHostProjection()
        let prefix = "{\"type\":\"batch\",\"\\u0074ype\":\"hello\",\"padding\":\""
        var body = Data(prefix.utf8)
        body.append(Data(repeating: 120, count: projection.caps.control))
        body.append(Data("\"}".utf8))
        var reserved = false
        let result = BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection,
            reserveWorkingMemory: { _ in reserved = true; return true })
        #expect(result == .refuse(BrowserRefusal(code: "oversize")))
        #expect(!reserved)
    }

    @Test func maximumDepthControlStillRefusesBeforeMaterialization() throws {
        let projection = try nativeHostProjection()
        let depth = projection.caps.jsonMaxDepth - 1
        let nested = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
        let body = Data(("{\"type\":\"hello\",\"ignored\":" + nested + ",\"padding\":\"" +
            String(repeating: "x", count: projection.caps.control) + "\"}").utf8)
        var reserved = false
        #expect(BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection,
            reserveWorkingMemory: { _ in reserved = true; return true }) == .refuse(BrowserRefusal(code: "oversize")))
        #expect(!reserved)
    }

    @Test func nearFrameCeilingFitsChargedInputAndDenialIsFailClosed() throws {
        let projection = try nativeHostProjection()
        var body = Data("{\"type\":\"batch\",\"destination_generation\":\"g\",\"inst\":\"i\",\"batch_id\":\"ffffffffffffffffffffffffffffffff\",\"queued_at_ms\":1,\"records\":[{\"t\":\"segment_start\",\"ts\":1,\"ctx\":\"c\",\"blocks\":[{\"id\":\"b\",\"text\":\"synthetic page\"}],\"padding\":\"".utf8)
        let suffix = Data("\"}]}".utf8)
        body.append(Data(repeating: 120, count: projection.caps.extensionToHost - body.count - suffix.count - 1))
        body.append(suffix)
        var working = 0
        let decoded = BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection,
            reserveWorkingMemory: { amount in working = amount; return true })
        guard case .accept(.batch(let batch)) = decoded else { Issue.record("near-ceiling valid batch refused"); return }
        #expect(batch.records.count == 1)
        #expect(working >= body.count * 2)
        #expect(working + body.count <= 128 * 1024 * 1024)
        #expect(BrowserPayloadDecoder.decode(bytes: body, direction: "extension_to_host", projection: projection,
            reserveWorkingMemory: { _ in false }) == .refuse(BrowserRefusal(code: "resource_exhausted")))
    }
}

#endif
