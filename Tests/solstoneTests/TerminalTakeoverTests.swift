// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("takeover-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let sameJournal = TerminalJournalIdentity(journalID: "j1", instanceID: "x", caFingerprint: "aa")
private let otherJournal = TerminalJournalIdentity(journalID: "j2", instanceID: "x", caFingerprint: "aa")

private func journal(_ id: TerminalJournalIdentity = sameJournal, device: String) -> TerminalContinuityPlan.Legacy {
    TerminalContinuityPlan.Legacy(deviceID: device, journal: id)
}

private func app(_ id: TerminalJournalIdentity = sameJournal, device: String = "sha256:app", confirmed: Bool = true) -> TerminalContinuityPlan.AppPairing {
    TerminalContinuityPlan.AppPairing(deviceID: device, journal: id, confirmed: confirmed)
}

private final class FakeLaunchctl: @unchecked Sendable {
    let lock = NSLock()
    var calls: [[String]] = []
    var stuck = false
    var loaded = true

    func run(_ arguments: [String]) -> Bool {
        lock.withLock {
            calls.append(arguments)
            switch arguments.first {
            case "print": return loaded && stuck
            default: return true
            }
        }
    }
}

private struct Install {
    let home: URL
    let launchctl = FakeLaunchctl()
    let root: URL
    let plist: URL

    init() throws {
        home = try tempRoot()
        root = home.appendingPathComponent("Library/Application Support/solstone-tmux", isDirectory: true)
        plist = home.appendingPathComponent("Library/LaunchAgents/com.solstone.tmux.plist")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("captures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func writePlist(label: String = "com.solstone.tmux", program: String = "/usr/local/bin/solstone-tmux", tmpdir: String? = nil) throws {
        var plist: [String: Any] = ["Label": label, "ProgramArguments": [program, "run"]]
        if let tmpdir { plist["EnvironmentVariables"] = ["TMUX_TMPDIR": tmpdir] }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: self.plist)
    }

    var host: TerminalTakeoverHost {
        let launchctl = launchctl
        return TerminalTakeoverHost(root: root, plistURL: plist, launchctl: { launchctl.run($0) }, uid: 501)
    }
}

private final class FakeMigration: TerminalMigrationTransport, @unchecked Sendable {
    let lock = NSLock()
    var answers: [(Int, String?)] = []
    var bodies: [String] = []

    func sendMigration(serverURL: String, body: String) async -> (status: Int, reason: String?)? {
        lock.withLock {
            bodies.append(body)
            guard !answers.isEmpty else { return nil }
            let answer = answers.removeFirst()
            return (answer.0, answer.1)
        }
    }
}

private final class EmptyTransport: TerminalUploadTransport {
    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay {
        IngestProtocolV3.SegmentsDay(total: 0, items: [])
    }
    func prepareTerminalUpload(serverURL: String, segment: TerminalSpoolSegment, bodyURL: URL) throws -> PreparedIngestV3Upload {
        throw URLError(.cancelled)
    }
    func uploadStaged(prepared: PreparedIngestV3Upload) async -> UploadResult { .failure(URLError(.cancelled)) }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class PairingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TerminalContinuityPlan.AppPairing?

    init(_ value: TerminalContinuityPlan.AppPairing? = nil) { stored = value }

    var value: TerminalContinuityPlan.AppPairing? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite("Terminal takeover")
struct TerminalTakeoverTests {
    private func makeDriver(
        install: Install,
        store: TerminalTakeoverStore,
        pairing: TerminalContinuityPlan.AppPairing? = nil,
        pairingBox: PairingBox? = nil,
        migration: FakeMigration = FakeMigration(),
        listing: TerminalLegacyListing = .listed(segments: [], held: 0, problems: []),
        turnedOn: Flag = Flag(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> TerminalTakeoverDriver {
        let box = pairingBox ?? PairingBox(pairing)
        let spool = try tempRoot()
        let planner = TerminalUploadPlanner(
            root: spool,
            transport: EmptyTransport(),
            serverURL: { "http://127.0.0.1" },
            isHeld: { false },
            uploadsGated: { store.load().uploadsGated },
            listLegacy: { listing }
        )
        return TerminalTakeoverDriver(
            store: store,
            host: install.host,
            planner: planner,
            settingsURL: spool.appendingPathComponent("settings.json"),
            transport: migration,
            serverURL: { "http://127.0.0.1" },
            appPairing: { box.value },
            turnTerminalOn: { turnedOn.set() },
            now: now
        )
    }

    private func writeLegacyCredential(_ install: Install) throws {
        let body = """
        {"client_key_pem":"k","client_cert_pem":"\(Self.certificate)","ca_chain_pem":["\(Self.certificate)"],"ca_fp_prefix":[1,2],"instance_id":"x","home_label":"h","endpoints":[]}
        """
        try Data(body.utf8).write(to: install.root.appendingPathComponent("credentials.json"))
    }

    // A self-signed test certificate, escaped for embedding in JSON.
    private static let certificate = "-----BEGIN CERTIFICATE-----\\nMIIBeDCCAR+gAwIBAgIUTeO3+NUPtIiTaUweLHPoxNwOqlkwCgYIKoZIzj0EAwIw\\nEjEQMA4GA1UEAwwHdGVzdC1jYTAeFw0yNjExMDkwMzM1MTlaFw0zNjExMDYwMzM1\\nMTlaMBIxEDAOBgNVBAMMB3Rlc3QtY2EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC\\nAAQCcKKqQkWn/9woSpA47LxxP03batImFg22tjNFpRl1MZvwiP6tdyI1gAtMm4+q\\n/OFT1w8LJXYVU3F1yFwSuHFLo1MwUTAdBgNVHQ4EFgQUhs82DnEBqzJBuKPRYUdJ\\nK/xy5B8wHwYDVR0jBBgwFoAUhs82DnEBqzJBuKPRYUdJK/xy5B8wDwYDVR0TAQH/\\nBAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiATSGMTRl/sQ1Iaa3KjUGjWlRAb7FGz\\nfoneY2IJdOArUQIgJ8L/HBfST0kpWiw1bHVj12+4cgoB32sn9xMhaQoP9qo=\\n-----END CERTIFICATE-----\\n"

    // MARK: - the record

    @Test func aCorruptRecordIsAHardStopThatGatesUploads() throws {
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try Data("{\"phase\"".utf8).write(to: store.fileURL)
        #expect(store.load() == .unusable(store.fileURL))
        #expect(store.load().uploadsGated)
    }

    @Test func noRecordGatesNothing() throws {
        let store = TerminalTakeoverStore(directory: try tempRoot())
        #expect(store.load() == .absent)
        #expect(!store.load().uploadsGated)
    }

    @Test func aWriteFaultedAtAnyStageLeavesAReadableRecord() throws {
        for stage in TerminalDurableStage.allCases {
            let store = TerminalTakeoverStore(directory: try tempRoot())
            let old = TerminalTakeoverRecord()
            try store.save(old)
            var new = old
            new.phase = .listed
            store.fault = { $0 == stage }
            try? store.save(new)
            store.fault = nil
            let read = try #require(store.load().record, "\(stage)")
            #expect(read == old || read == new, "\(stage)")
        }
    }

    // MARK: - continuity

    @Test func journalsCompareOnTheCAWhenBothAreReadable() {
        let rewritten = TerminalJournalIdentity(journalID: "j1", instanceID: "rewritten", caFingerprint: "bb")
        #expect(sameJournal.isSameJournal(as: rewritten))
        #expect(!sameJournal.isSameJournal(as: otherJournal))
        let prefixOnly = TerminalJournalIdentity(journalID: nil, instanceID: "x", caFingerprint: "aabb")
        #expect(prefixOnly.isSameJournal(as: TerminalJournalIdentity(journalID: nil, instanceID: "x", caFingerprint: "aa")))
        #expect(!prefixOnly.isSameJournal(as: TerminalJournalIdentity(journalID: nil, instanceID: "y", caFingerprint: "aa")))
    }

    @Test func continuityDecisions() {
        #expect(TerminalContinuityPlan.decide(legacy: nil, app: app()) == .settle(.newStream(reason: "no_old_pairing", needsAttention: false)))
        #expect(TerminalContinuityPlan.decide(legacy: journal(device: "sha256:old"), app: nil) == .wait)
        #expect(TerminalContinuityPlan.decide(legacy: journal(otherJournal, device: "sha256:old"), app: app()) == .settle(.newStream(reason: "different_journal", needsAttention: false)))
        #expect(TerminalContinuityPlan.decide(legacy: journal(device: "sha256:old"), app: app(confirmed: false)) == .wait)
        #expect(TerminalContinuityPlan.decide(legacy: journal(device: "sha256:old"), app: app()) == .migrate(replaces: "sha256:old", callerID: "sha256:app"))
    }

    @Test func everyJournalAnswerSettlesOrRetries() {
        #expect(TerminalMigrationAnswer.classify(status: 200, reason: nil) == .settled(.continued))
        for (status, reason) in [
            (404, "paired_device_not_found"), (409, "migration_target_conflict"), (400, "migration_protocol_unsupported"),
            (403, "migration_forbidden"), (400, "migration_request_invalid"), (403, "migration_replay_forbidden"),
            (409, "migration_self_replacement"),
        ] {
            #expect(TerminalMigrationAnswer.classify(status: status, reason: reason) == .settled(.newStream(reason: reason, needsAttention: false)))
        }
        #expect(TerminalMigrationAnswer.classify(status: 409, reason: "migration_operation_conflict") == .settled(.newStream(reason: "migration_operation_conflict", needsAttention: true)))
        #expect(TerminalMigrationAnswer.classify(status: 404, reason: nil) == .settled(.newStream(reason: "journal_too_old", needsAttention: false)))
        #expect(TerminalMigrationAnswer.classify(status: 503, reason: "migration_state_unavailable") == .retry("migration_state_unavailable"))
        #expect(TerminalMigrationAnswer.classify(status: 500, reason: nil) == .retry("status 500"))
    }

    @Test func aRetryKeepsItsBytesAndANewCallerGetsANewOperation() {
        var record = TerminalTakeoverRecord()
        let first = TerminalContinuityPlan.storedOrNew(&record, replaces: "sha256:old", callerID: "a")
        #expect(TerminalContinuityPlan.storedOrNew(&record, replaces: "sha256:old", callerID: "a") == first)
        let repaired = TerminalContinuityPlan.storedOrNew(&record, replaces: "sha256:old", callerID: "b")
        #expect(repaired.operationID != first.operationID)
        #expect(record.migration == repaired)
    }

    // MARK: - stop for good

    @Test func stoppingBootsOutDisablesAndRemovesItsFiles() throws {
        let install = try Install()
        try install.writePlist()
        let observer = install.root.appendingPathComponent("local-observer.json")
        try Data("{}".utf8).write(to: observer)
        try TerminalTakeoverSteps.stopForGood(install.host)
        #expect(install.launchctl.calls.contains(["bootout", "gui/501/com.solstone.tmux"]))
        #expect(install.launchctl.calls.contains(["disable", "gui/501/com.solstone.tmux"]))
        #expect(!FileManager.default.fileExists(atPath: install.plist.path))
        #expect(!FileManager.default.fileExists(atPath: observer.path))
    }

    @Test func aPlistThatIsNotOursIsNeverBootedOut() throws {
        for (label, program) in [("com.someone.else", "/usr/local/bin/solstone-tmux"), ("com.solstone.tmux", "/usr/local/bin/other")] {
            let install = try Install()
            try install.writePlist(label: label, program: program)
            #expect(throws: TerminalStepError.self) { try TerminalTakeoverSteps.stopForGood(install.host) }
            #expect(!install.launchctl.calls.contains { $0.first == "bootout" })
            #expect(FileManager.default.fileExists(atPath: install.plist.path))
        }
    }

    @Test func aServiceThatWillNotStopKeepsItsPlistAndIsTemporary() throws {
        let install = try Install()
        try install.writePlist()
        install.launchctl.stuck = true
        #expect(throws: TerminalStepError.temporary(UICopy.Terminal.oldAppStillRunning)) {
            try TerminalTakeoverSteps.stopForGood(install.host)
        }
        #expect(FileManager.default.fileExists(atPath: install.plist.path))
    }

    @Test func detailsAreReadBeforeAnythingChangesAndFindIsReadOnly() throws {
        let install = try Install()
        try install.writePlist(tmpdir: "/tmp/mux")
        let observer = install.root.appendingPathComponent("local-observer.json")
        try Data(#"{"tmux_path":"/opt/tmux"}"#.utf8).write(to: observer)
        #expect(TerminalTakeoverSteps.isInstalled(install.host))
        let record = try TerminalTakeoverSteps.prepare(install.host)
        #expect(record.tmuxTmpdir == "/tmp/mux")
        #expect(record.tmuxPath == "/opt/tmux")
        #expect(FileManager.default.fileExists(atPath: install.plist.path))
        #expect(FileManager.default.fileExists(atPath: observer.path))
        #expect(!install.launchctl.calls.contains { $0.first == "bootout" || $0.first == "disable" })
    }

    @Test func aBadValueLeavesThatKeyAtItsDefault() throws {
        let install = try Install()
        try Data(#"{"stream":null,"segment_interval":0,"capture_interval":5,"output_sessions":[""],"pane_title":false,"future":1}"#.utf8)
            .write(to: install.root.appendingPathComponent("config.json"))
        let data = try #require(TerminalTakeoverSteps.carriedSettings(install.host))
        let carried = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(carried["capture_interval"] as? Int == 5)
        #expect(carried["pane_title"] as? Bool == false)
        #expect(carried["segment_interval"] == nil)
        #expect(carried["output_sessions"] == nil)
        #expect(carried["future"] == nil)
    }

    // MARK: - the listing

    @Test func onlyADoneLineCountsAsListed() {
        #expect(TerminalLegacyListing.parse(status: 75, output: Data()) == .locked)
        if case .failed = TerminalLegacyListing.parse(status: 1, output: Data()) {} else { Issue.record("exit 1") }
        if case .failed = TerminalLegacyListing.parse(status: 0, output: Data(#"{"event":"held"}"#.utf8)) {} else { Issue.record("no done") }
        let lines = #"""
        {"event":"segment","day":"20260101","segment":"101500_300","dir":"/x/101500_300","files":["a.jsonl"],"zone":{"utc_offset_seconds":19800}}
        {"event":"held","day":"20260101","segment":"x","dir":"/x/x","reason":"failed"}
        {"event":"problem","path":"/x/y","reason":"r"}
        {"event":"done","segments":1,"held":1,"problems":1}
        """#
        guard case .listed(let segments, let held, let problems) = TerminalLegacyListing.parse(status: 0, output: Data(lines.utf8)) else {
            Issue.record("listing")
            return
        }
        #expect(segments.count == 1)
        #expect(segments[0].zone?["utc_offset_seconds"] == .integer(19800))
        #expect(held == 1)
        #expect(problems == ["/x/y"])
    }

    // MARK: - the driver

    @Test func nothingIsHandedOverUntilTheOldServiceIsGone() async throws {
        let install = try Install()
        try install.writePlist()
        install.launchctl.stuck = true
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let migration = FakeMigration()
        let turnedOn = Flag()
        let driver = try makeDriver(install: install, store: store, pairing: app(), migration: migration, turnedOn: turnedOn)
        await driver.advance()
        #expect(migration.bodies.isEmpty)
        #expect(!turnedOn.isSet)
        #expect(store.load().record?.phase == .consented)
        #expect(store.load().record?.lastAnswer != nil)
    }

    @Test func aHeldLockStopsAfterTheStopAndWaits() async throws {
        let install = try Install()
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let turnedOn = Flag()
        let driver = try makeDriver(install: install, store: store, listing: .locked, turnedOn: turnedOn)
        await driver.advance()
        #expect(store.load().record?.phase == .stopped)
        #expect(!turnedOn.isSet)
    }

    @Test func anUnreadableSpoolDoesNotHoldTerminalBackAndKeepsRetrying() async throws {
        let install = try Install()
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let turnedOn = Flag()
        let driver = try makeDriver(install: install, store: store, listing: .failed("x"), turnedOn: turnedOn)
        await driver.advance()
        let record = try #require(store.load().record)
        #expect(turnedOn.isSet)
        #expect(record.needsListing)
        #expect(record.problems == ["x"])
    }

    @Test func withNoOldPairingItFinishes() async throws {
        let install = try Install()
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let driver = try makeDriver(install: install, store: store)
        await driver.advance()
        let record = try #require(store.load().record)
        #expect(record.phase == .done)
        #expect(record.continuity == .newStream(reason: "no_old_pairing", needsAttention: false))
        #expect(!record.uploadsGated)
    }

    private var legacyDevice: TerminalLegacyCredential {
        get throws {
            let body = #"{"client_cert_pem":"\#(Self.certificate)","ca_chain_pem":["\#(Self.certificate)"],"ca_fp_prefix":[1,2],"instance_id":"x"}"#
            return try JSONDecoder().decode(TerminalLegacyCredential.self, from: Data(body.utf8))
        }
    }

    private func pairedApp(same: Bool = true, confirmed: Bool = true) throws -> TerminalContinuityPlan.AppPairing {
        let identity = same ? try legacyDevice.journal : TerminalJournalIdentity(journalID: "another", instanceID: "y", caFingerprint: "ff")
        return TerminalContinuityPlan.AppPairing(deviceID: "sha256:app", journal: identity, confirmed: confirmed)
    }

    @Test func aRealCredentialYieldsAPrefixedDeviceID() throws {
        let id = try #require(try legacyDevice.deviceID)
        #expect(id.hasPrefix("sha256:"))
        #expect(id.count == 71)
    }

    @Test func theHandoverIsSentAndTheOldCredentialGoesOnlyAfterIt() async throws {
        let install = try Install()
        try writeLegacyCredential(install)
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let migration = FakeMigration()
        migration.answers = [(200, nil)]
        let driver = try makeDriver(install: install, store: store, pairing: try pairedApp(), migration: migration)
        await driver.advance()
        let record = try #require(store.load().record)
        #expect(migration.bodies.count == 1)
        #expect(migration.bodies[0].contains("replace_device"))
        #expect(record.continuity == .continued)
        #expect(record.phase == .done)
        #expect(!FileManager.default.fileExists(atPath: install.root.appendingPathComponent("credentials.json").path))
    }

    @Test func aRetryResendsTheSameBytesAndUploadsStayGated() async throws {
        let install = try Install()
        try writeLegacyCredential(install)
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let migration = FakeMigration()
        migration.answers = [(503, "migration_state_unavailable"), (200, nil)]
        let clock = StepClock()
        let driver = try makeDriver(install: install, store: store, pairing: try pairedApp(), migration: migration, now: { clock.now })
        await driver.advance()
        #expect(store.load().uploadsGated)
        #expect(store.load().record?.lastAnswer == "migration_state_unavailable")
        clock.advance(10)
        await driver.advance()
        #expect(migration.bodies.count == 2)
        #expect(migration.bodies[0] == migration.bodies[1])
        #expect(store.load().record?.continuity == .continued)
    }

    @Test func aStoredMigrationIsDrivenToItsEndAfterTheOldCredentialGoes() async throws {
        let install = try Install()
        try writeLegacyCredential(install)
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let migration = FakeMigration()
        migration.answers = [(503, "migration_state_unavailable"), (200, nil)]
        let clock = StepClock()
        let driver = try makeDriver(install: install, store: store, pairing: try pairedApp(), migration: migration, now: { clock.now })
        await driver.advance()
        try FileManager.default.removeItem(at: install.root.appendingPathComponent("credentials.json"))
        clock.advance(10)
        await driver.advance()
        #expect(migration.bodies.count == 2)
        #expect(store.load().record?.continuity == .continued)
    }

    @Test func unpairedWaitsWithTerminalOnThenHandsOverOncePaired() async throws {
        let install = try Install()
        try writeLegacyCredential(install)
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let migration = FakeMigration()
        migration.answers = [(200, nil)]
        let turnedOn = Flag()
        let pairing = PairingBox()
        let driver = try makeDriver(install: install, store: store, pairingBox: pairing, migration: migration, turnedOn: turnedOn)
        await driver.advance()
        #expect(turnedOn.isSet, "new sessions are taken in while it waits")
        #expect(migration.bodies.isEmpty)
        #expect(store.load().uploadsGated)
        pairing.value = try pairedApp()
        await driver.advance()
        #expect(migration.bodies.count == 1)
        #expect(store.load().record?.continuity == .continued)
    }

    @Test func anotherJournalGetsNoCallAndKeepsTheOldCredential() async throws {
        let install = try Install()
        try writeLegacyCredential(install)
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let migration = FakeMigration()
        let driver = try makeDriver(install: install, store: store, pairing: try pairedApp(same: false), migration: migration)
        await driver.advance()
        #expect(migration.bodies.isEmpty)
        #expect(store.load().record?.continuity == .newStream(reason: "different_journal", needsAttention: false))
        #expect(FileManager.default.fileExists(atPath: install.root.appendingPathComponent("credentials.json").path))
    }

    @Test func aRepairToAnotherJournalNeverReceivesTheStoredRequest() async throws {
        let install = try Install()
        try writeLegacyCredential(install)
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let migration = FakeMigration()
        migration.answers = [(503, "migration_state_unavailable")]
        let clock = StepClock()
        let pairing = PairingBox()
        pairing.value = try pairedApp()
        let driver = try makeDriver(install: install, store: store, pairingBox: pairing, migration: migration, now: { clock.now })
        await driver.advance()
        #expect(migration.bodies.count == 1)
        pairing.value = try pairedApp(same: false)
        clock.advance(10)
        await driver.advance()
        #expect(migration.bodies.count == 1)
        #expect(store.load().record?.continuity == .newStream(reason: "different_journal", needsAttention: false))
    }

    @Test func aFinishedMoveStaysFinishedOnLaterRuns() async throws {
        let install = try Install()
        let store = TerminalTakeoverStore(directory: try tempRoot())
        try store.save(TerminalTakeoverRecord())
        let turnedOn = Flag()
        let driver = try makeDriver(install: install, store: store, turnedOn: turnedOn)
        await driver.advance()
        let first = try #require(store.load().record)
        #expect(first.phase == .done)
        await driver.advance()
        #expect(store.load().record == first)
    }

    @Test func anOwnerWhoTurnedItOffStaysOff() async throws {
        let install = try Install()
        let store = TerminalTakeoverStore(directory: try tempRoot())
        var record = TerminalTakeoverRecord()
        record.ownerTurnedOff = true
        try store.save(record)
        let turnedOn = Flag()
        let driver = try makeDriver(install: install, store: store, turnedOn: turnedOn)
        await driver.advance()
        #expect(!turnedOn.isSet)
        #expect(store.load().record?.terminalSettled == true)
    }
}
