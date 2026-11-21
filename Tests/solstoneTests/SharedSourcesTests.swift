// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import MacTestSupport
import Testing
@testable import solstone

@MainActor
private final class SourceJournalFixture: SharedSourceTransport {
    var capabilities = ["shared_sources"]
    var revision = "one"
    var reads = 0
    var probes = 0
    var declarations: [[SourceDeclaration]] = []
    var putStatus = 204
    var getStatus = 200
    var duringPut: (() -> Void)?
    var duringGet: (() async throws -> Void)?

    func systemStatus(serverURL: String) async throws -> JournalSystemStatus {
        probes += 1
        return .init(capabilities: capabilities, sources_rev: revision)
    }

    func declareSources(_ sources: [SourceDeclaration], serverURL: String) async throws {
        declarations.append(sources)
        duringPut?()
        guard putStatus == 204 else { throw UploadError.serverError(.init(statusCode: putStatus)) }
    }

    func knownSources(serverURL: String) async throws -> SharedSourceSnapshot {
        reads += 1
        let code = getStatus
        let snapshotRevision = revision
        try await duringGet?()
        guard code == 200 else { throw UploadError.serverError(.init(statusCode: code)) }
        let rows: [SharedSourceSnapshot.Source] = [
            .init(source: "obsidian", detail: "Field", state: "paused", origin: "declared",
                  declared_at: "2026-11-20T11:00:00Z", last_synced_at: nil),
            .init(source: "obsidian", detail: "Archive", state: nil, origin: "observed",
                  declared_at: nil, last_synced_at: "2026-11-19T11:00:00Z")
        ]
        return .init(self_cid: "self", sources_rev: snapshotRevision, devices: [
            .init(cid: "self", display_label: "Desk", device_type: "desktop", device_last_seen_at: nil, sources: rows),
            .init(cid: "other", display_label: "Desk", device_type: "desktop", device_last_seen_at: "2026-11-20T12:00:00.123Z", sources: rows),
            .init(cid: "legacy", display_label: "Older", device_type: nil, device_last_seen_at: "2026-11-21T12:00:00Z", sources: [rows[1]])
        ])
    }
}

@MainActor
private final class SourceRig {
    let suite = "mac.shared-source-test.\(UUID())"
    let journal = SourceJournalFixture()
    lazy var defaults = UserDefaults(suiteName: suite)!
    var now = Date(timeIntervalSince1970: 1_795_176_000)
    lazy var shared = SharedSources(defaults: defaults, transport: journal, now: { [unowned self] in now })
    var route: SharedSourceRoute? = .init(identity: "first credential", port: 7654, incarnation: 1)
    var identity: String? { route?.identity }
    let vault = SourceDeclaration(source: "obsidian", state: "on", detail: "Notes")

    func update(_ sources: [SourceDeclaration]) {
        shared.currentRoute = { [weak self] in self?.route }
        shared.update(identity: route?.identity, route: route, sources: sources)
    }
    func clean() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
@Suite("Shared sources")
struct SharedSourcesTests {
    @Test func sharedSourceHTTPRequestsMatchTheJournal() async throws {
        let store = ObserverURLProtocolStore()
        store.registerRoute(path: "/api/system/status", method: "GET",
                            body: #"{"capabilities":["shared_sources"],"sources_rev":"1d9038"}"#)
        store.registerRoute(path: "/app/network/api/clients/self/sources", method: "PUT", statusCode: 204)
        store.registerRoute(path: "/app/network/api/sources", method: "GET",
                            body: #"{"devices":[],"self_cid":"me","sources_rev":"1d9038"}"#)
        let client = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))
        let base = "http://127.0.0.1:7654"
        #expect(try await client.systemStatus(serverURL: base).sources_rev == "1d9038")
        let sources = [SourceDeclaration(source: "obsidian", state: "on", detail: "Notes")]
        try await client.declareSources(sources, serverURL: base)
        try await client.declareSources([], serverURL: base)
        #expect(try await client.knownSources(serverURL: base).self_cid == "me")
        let sent = try store.requestBodyData.compactMap { body in
            try body.map { try JSONDecoder().decode([SourceDeclaration].self, from: $0) }
        }
        #expect(sent == [sources, []])
    }

    @Test func configurationAndTheEmptyArrayMatchTheWireContract() throws {
        var deck = DeckInputs()
        deck.screenOn = false
        deck.microphoneOn = false
        deck.terminalOn = false
        deck.browsersOn = true
        deck.browserState = .running(connected: [])
        deck.obsidianState = .on
        deck.obsidianVaultName = "Notes"
        deck.screenshot.state = .needsAttention
        func rows(_ confirmed: Bool) -> [SourceDeclaration] {
            deck.declarations(vaultConfirmed: confirmed, browserConfigured: false, permissionsChecked: true)
        }
        #expect(String(decoding: try JSONEncoder().encode(rows(false)), as: UTF8.self) == "[]")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(rows(true)), as: UTF8.self) ==
                #"[{"detail":"Notes","source":"obsidian","state":"on"}]"#)
        deck.obsidianVaultName = "\n"
        #expect(rows(true).first?.detail == nil)
        deck.screenOn = true
        deck.microphoneOn = true
        deck.terminalOn = true
        deck.terminalState = .paused
        deck.screenshot.configuredForDeclaration = true
        let all = deck.declarations(vaultConfirmed: true, browserConfigured: true, permissionsChecked: true)
        #expect(Set(all.map(\.source)) == Set(DeckSource.allCases.map(\.rawValue)))
        #expect(all.first { $0.source == "terminal" }?.state == "paused")
        #expect(all.first { $0.source == "screenshots" }?.state == "needs_attention")
    }

    @Test func latestArrayWinsAndReadsAreEventDriven() async throws {
        let rig = SourceRig()
        defer { rig.clean() }
        rig.journal.duringPut = {
            rig.journal.duringPut = nil
            rig.update([])
        }
        rig.update([rig.vault])
        await rig.shared.waitForPendingWork()
        #expect(rig.journal.declarations == [[rig.vault], []])
        #expect(rig.journal.reads == 1)
        rig.shared.opened(detail: false)
        await rig.shared.waitForPendingWork()
        #expect(rig.journal.reads == 1)
        rig.now.addTimeInterval(301)
        rig.shared.opened(detail: false)
        await rig.shared.waitForPendingWork()
        #expect(rig.journal.reads == 2)
        rig.shared.opened(detail: true)
        await rig.shared.waitForPendingWork()
        #expect(rig.journal.reads == 3)
        rig.journal.revision = "renamed"
        _ = try await rig.shared.folderCapabilities(serverURL: try #require(rig.route).base)
        await rig.shared.waitForPendingWork()
        #expect(rig.journal.reads == 4)
        #expect(rig.journal.probes == 5)
    }

    @Test func offlineFactsAgeFromRawTimeAndStayWithTheirPairing() async throws {
        let rig = SourceRig()
        defer { rig.clean() }
        rig.update([])
        await rig.shared.waitForPendingWork()
        rig.route = nil
        rig.update([rig.vault])
        let reopened = SharedSources(defaults: rig.defaults, transport: rig.journal)
        let devices = reopened.devices(for: "first credential")
        #expect(devices.map(\.id) == ["other", "legacy"])
        let desk = try #require(devices.first)
        #expect(desk.rows.map(\.detail) == ["Field", "Archive"])
        let time = try #require(desk.rows.first?.time)
        #expect(desk.summary(at: time.addingTimeInterval(240)) == "Desk · paused · 4 min ago")
        #expect(desk.summary(at: time.addingTimeInterval(720)) == "Desk · paused · 12 min ago")
        #expect(desk.rows[1].line(at: time)?.hasPrefix("Archive · ") == true)
        #expect(MacStrings.macos_shared_sa12(devices.count) == "from 2 other devices")
        #expect(MacStrings.macos_shared_sa12(1) == "from another device")
        #expect(reopened.devices(for: nil).isEmpty)
        reopened.update(identity: "same journal new credential", route: nil, sources: [])
        #expect(reopened.devices(for: "first credential").isEmpty)
        #expect(SharedSources(defaults: rig.defaults, transport: rig.journal).devices(for: "first credential").isEmpty)
        #expect(rig.journal.declarations == [[]])
        rig.route = .init(identity: "first credential", port: 7654, incarnation: 2)
        rig.update([rig.vault])
        await rig.shared.waitForPendingWork()
        #expect(rig.journal.declarations == [[], [rig.vault]])
        rig.shared.wipe()
        #expect(SharedSources(defaults: rig.defaults, transport: rig.journal).devices(for: "first credential").isEmpty)
    }

    @Test func drawnLinesBreakOnlyAfterASeparator() throws {
        let now = Date()
        let row = SharedSourceDetail(detail: "field notes", state: "needs_attention", time: now.addingTimeInterval(-240))
        let device = SharedSourceDevice(id: "a", name: "the work laptop in the downstairs office", type: "laptop", rows: [row])
        let tile = device.tileLine(at: now)
        let fact = device.factLine(at: now)
        let state = DeckStateWord.needsAttention.word.replacingOccurrences(of: " ", with: "\u{a0}")
        for line in [tile, fact, try #require(row.drawnLine(at: now))] {
            #expect(!line.contains(" \u{b7}"))
            #expect(line.contains(state))
        }
        // The tile shortens a long name and keeps every part whole; the page keeps the full name.
        let tileName = try #require(tile.components(separatedBy: "\u{a0}\u{b7}").first)
        #expect(tileName.count <= SharedSourceDevice.tileNameLimit)
        #expect(tile.indices.filter { tile[$0] == " " }.allSatisfy { tile[tile.index(before: $0)] == "\u{b7}" })
        #expect(fact.replacingOccurrences(of: "\u{a0}", with: " ") == device.summary(at: now))
    }

    @Test func cachedPeersStayHiddenUntilTheOwnerAnswersTheJournalMark() async {
        let rig = SourceRig()
        defer { rig.clean() }
        let credential = pairing()
        let revision = PairingCredentialRevision(from: credential).revision
        rig.route = .init(identity: revision, port: 7654, incarnation: 1)
        rig.update([])
        await rig.shared.waitForPendingWork()
        let state = AppState.forSnapshot(
            initialTunnelPairing: credential,
            journalMarkConfirmationStore: InMemoryJournalMarkConfirmationStore(settled: true)
        )
        state.sharedSources = rig.shared
        #expect(!rig.shared.devices(for: revision).isEmpty)
        #expect(state.otherObsidianDevices.isEmpty)
        #expect(state.sharedSourceRoute == nil)
        state.recordJournalMarkConfirmed()
        #expect(!state.otherObsidianDevices.isEmpty)
        state.clearJournalMarkConfirmation()
        #expect(state.otherObsidianDevices.isEmpty)
        #expect(SharedSources(defaults: rig.defaults, transport: rig.journal).devices(for: revision).isEmpty)
    }

    @Test func transientErrorsRetryBadDeclarationsWaitAndRevocationPersists() async {
        let rig = SourceRig()
        defer { rig.clean() }
        rig.update([])
        await rig.shared.waitForPendingWork()
        rig.journal.putStatus = 503
        rig.update([rig.vault])
        await rig.shared.waitForPendingWork()
        #expect(!rig.shared.devices(for: rig.identity).isEmpty)
        rig.journal.putStatus = 400
        rig.shared.opened(detail: false)
        await rig.shared.waitForPendingWork()
        rig.shared.opened(detail: true)
        await rig.shared.waitForPendingWork()
        #expect(rig.journal.declarations == [[], [rig.vault], [rig.vault]])
        rig.journal.getStatus = 403
        rig.shared.opened(detail: true)
        await rig.shared.waitForPendingWork()
        #expect(rig.shared.devices(for: rig.identity).isEmpty)
        let reopened = SharedSources(defaults: rig.defaults, transport: rig.journal)
        reopened.currentRoute = { rig.route }
        let before = rig.journal.probes
        reopened.update(identity: rig.identity, route: rig.route, sources: [])
        await reopened.waitForPendingWork()
        #expect(rig.journal.probes == before)
    }

    @Test(arguments: [true, false])
    func newerFolderStatusWinsDuringRegistryRead(supported: Bool) async throws {
        let rig = SourceRig()
        defer { rig.clean() }
        rig.journal.duringGet = {
            rig.journal.duringGet = nil
            rig.journal.revision = "after rename"
            rig.journal.capabilities = supported ? ["shared_sources"] : []
            _ = try await rig.shared.folderCapabilities(serverURL: try #require(rig.route).base)
        }
        rig.update([])
        await rig.shared.waitForPendingWork()
        #expect(rig.journal.reads == (supported ? 2 : 1))
        #expect(rig.shared.devices(for: rig.identity).isEmpty == !supported)
    }

    @Test(arguments: [200, 403])
    func oldResponseCannotReachRepairedJournal(status: Int) async {
        let rig = SourceRig()
        defer { rig.clean() }
        rig.journal.getStatus = status
        rig.journal.duringGet = {
            rig.journal.duringGet = nil
            rig.shared.wipe()
            rig.route = .init(identity: "replacement", port: 7654, incarnation: 2)
            rig.journal.getStatus = 200
            rig.update([])
        }
        rig.update([])
        await rig.shared.waitForPendingWork()
        #expect(rig.shared.devices(for: "first credential").isEmpty)
        #expect(!rig.shared.devices(for: "replacement").isEmpty)
        rig.journal.capabilities = []
        rig.shared.opened(detail: true)
        await rig.shared.waitForPendingWork()
        #expect(rig.shared.devices(for: "replacement").isEmpty)
    }
}
