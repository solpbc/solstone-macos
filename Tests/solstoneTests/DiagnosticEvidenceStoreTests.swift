// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

private let inspectURL = URL(fileURLWithPath: "/var/tmp/solstone-diagnostic-evidence-inspect.json")
private let sevenDays: TimeInterval = 7 * 86_400

final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@Suite("Diagnostic evidence store")
struct DiagnosticEvidenceStoreTests {
    @Test("AC1 maximally populated schema-1 envelope round-trips with order and key allow-list")
    func ac1_maximallyPopulatedEnvelopeRoundTrips() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let codes = DiagnosticEvidenceCode.allCases
        var entries: [DiagnosticEvidenceEntry] = []
        entries.reserveCapacity(DiagnosticEvidenceEnvelope.maxEntries)
        for index in 0..<DiagnosticEvidenceEnvelope.maxEntries {
            let code = codes[index % codes.count]
            let firstAt = Date(timeIntervalSince1970: 999_000 + Double(index))
            let (lastAt, repeatCount): (Date, Int)
            switch index % 3 {
            case 0:
                lastAt = firstAt
                repeatCount = 1
            case 1:
                lastAt = firstAt.addingTimeInterval(5)
                repeatCount = 2
            default:
                lastAt = firstAt.addingTimeInterval(9)
                repeatCount = 999
            }
            entries.append(
                DiagnosticEvidenceEntry(
                    code: code,
                    firstAt: firstAt,
                    lastAt: lastAt,
                    repeatCount: repeatCount
                )
            )
        }
        let envelope = DiagnosticEvidenceEnvelope(schemaVersion: 1, entries: entries)
        let encoded = try envelope.encoded()
        let decoded = try DiagnosticEvidenceEnvelope.decoded(from: encoded, now: now)
        #expect(decoded == envelope)
        try assertExactKeyAllowList(encoded)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileStore = FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: directory)
        #expect(fileStore.write(encoded) == .confirmed)
        let expectedURL = directory
            .appendingPathComponent("Solstone", isDirectory: true)
            .appendingPathComponent("diagnostic-evidence.json")
        #expect(fileStore.fileURL == expectedURL)
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))

        let clock = TestClock(now)
        let store = DiagnosticEvidenceStore(bytesStore: fileStore, now: { clock.now })
        guard case .available(let readBack) = await store.read() else {
            Issue.record("AC1 file-store read should be available")
            return
        }
        #expect(readBack == envelope)

        try encoded.write(to: inspectURL, options: .atomic)
    }

    @Test("AC2 rejection matrix leaves planted bytes identical")
    func ac2_rejectionMatrixLeavesBytesUnchanged() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(now)
        let cases: [(name: String, json: String)] = [
            ("missing schemaVersion", #"{"entries":[]}"#),
            ("unknown schemaVersion", #"{"schemaVersion":0,"entries":[]}"#),
            ("future schemaVersion", #"{"schemaVersion":2,"entries":[]}"#),
            ("unknown code string", #"{"schemaVersion":1,"entries":[{"code":"not.a.code","firstAt":1,"lastAt":1,"repeatCount":1}]}"#),
            ("unknown envelope key", #"{"schemaVersion":1,"entries":[],"hint":"x"}"#),
            (
                "unknown entry key",
                #"{"schemaVersion":1,"entries":[{"code":"app.launch","firstAt":1,"lastAt":1,"repeatCount":1,"extra":true}]}"#
            ),
            ("malformed JSON", "not-json"),
            (
                "wrong field types",
                #"{"schemaVersion":1,"entries":[{"code":1,"firstAt":"now","lastAt":1,"repeatCount":1}]}"#
            ),
            (
                "negative timestamp",
                #"{"schemaVersion":1,"entries":[{"code":"app.launch","firstAt":-1,"lastAt":1,"repeatCount":1}]}"#
            ),
            (
                "future timestamp",
                #"{"schemaVersion":1,"entries":[{"code":"app.launch","firstAt":2000,"lastAt":2000,"repeatCount":1}]}"#
            ),
            (
                "firstAt greater than lastAt",
                #"{"schemaVersion":1,"entries":[{"code":"app.launch","firstAt":50,"lastAt":10,"repeatCount":1}]}"#
            ),
            (
                "non-integer repeatCount",
                #"{"schemaVersion":1,"entries":[{"code":"app.launch","firstAt":1,"lastAt":1,"repeatCount":1.5}]}"#
            ),
            (
                "repeatCount of 0",
                #"{"schemaVersion":1,"entries":[{"code":"app.launch","firstAt":1,"lastAt":1,"repeatCount":0}]}"#
            ),
            (
                "repeatCount of 1000",
                #"{"schemaVersion":1,"entries":[{"code":"app.launch","firstAt":1,"lastAt":1,"repeatCount":1000}]}"#
            )
        ]

        for item in cases {
            let bytes = InMemoryDiagnosticEvidenceBytesStore()
            let planted = Data(item.json.utf8)
            bytes.stored = planted
            let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
            let result = await store.read()
            #expect(result == .unavailable, "\(item.name) should be unavailable")
            #expect(bytes.stored == planted, "\(item.name) must leave planted bytes identical")
        }
    }

    @Test("AC3 missing and empty are available; malformed and unreadable are unavailable")
    func ac3_fourWayMissingEmptyMalformedUnreadable() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)

        let missingBytes = InMemoryDiagnosticEvidenceBytesStore()
        let missingStore = DiagnosticEvidenceStore(bytesStore: missingBytes, now: { clock.now })
        guard case .available(let missingEnvelope) = await missingStore.read() else {
            Issue.record("missing storage should be available")
            return
        }
        #expect(missingEnvelope.entries.isEmpty)

        let emptyBytes = InMemoryDiagnosticEvidenceBytesStore()
        emptyBytes.stored = try DiagnosticEvidenceEnvelope(schemaVersion: 1, entries: []).encoded()
        let emptyStore = DiagnosticEvidenceStore(bytesStore: emptyBytes, now: { clock.now })
        guard case .available(let emptyEnvelope) = await emptyStore.read() else {
            Issue.record("valid empty envelope should be available")
            return
        }
        #expect(emptyEnvelope.entries.isEmpty)
        #expect(emptyEnvelope.schemaVersion == 1)

        let malformedBytes = InMemoryDiagnosticEvidenceBytesStore()
        let malformedPlanted = Data("not-json".utf8)
        malformedBytes.stored = malformedPlanted
        let malformedStore = DiagnosticEvidenceStore(bytesStore: malformedBytes, now: { clock.now })
        #expect(await malformedStore.read() == .unavailable)
        #expect(malformedBytes.stored == malformedPlanted)

        let unreadableBytes = InMemoryDiagnosticEvidenceBytesStore()
        let priorGood = try DiagnosticEvidenceEnvelope(schemaVersion: 1, entries: []).encoded()
        unreadableBytes.stored = priorGood
        unreadableBytes.readOverride = .failed
        let unreadableStore = DiagnosticEvidenceStore(bytesStore: unreadableBytes, now: { clock.now })
        #expect(await unreadableStore.read() == .unavailable)
        #expect(unreadableBytes.stored == priorGood)
    }

    @Test("AC4 129 non-coalescing records preserve commit order and evict the first; an older 130th lands at the tail")
    func ac4_capPreservesCommitOrderAndEvictsOldest() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let codes = DiagnosticEvidenceCode.allCases
        let start: TimeInterval = 999_000
        for index in 0..<129 {
            let time = Date(timeIntervalSince1970: start + Double(index))
            #expect(await store.record(codes[index % codes.count], at: time) == .recorded)
        }

        guard case .available(let afterCap) = await store.read() else {
            Issue.record("AC4 read after 129 records should be available")
            return
        }
        #expect(afterCap.entries.count == 128)
        let firstAtsAfter129 = (1...128).map { Date(timeIntervalSince1970: start + Double($0)) }
        #expect(afterCap.entries.map(\.firstAt) == firstAtsAfter129)
        #expect(afterCap.entries.map(\.code) == (1...128).map { codes[$0 % codes.count] })

        let older = Date(timeIntervalSince1970: 998_000)
        #expect(await store.record(.appLaunch, at: older) == .recorded)
        guard case .available(let afterOlder) = await store.read() else {
            Issue.record("AC4 read after older record should be available")
            return
        }
        #expect(afterOlder.entries.count == 128)
        let firstAtsAfter130 = (2...128).map { Date(timeIntervalSince1970: start + Double($0)) } + [older]
        #expect(afterOlder.entries.map(\.firstAt) == firstAtsAfter130)
        #expect(afterOlder.entries.last?.code == .appLaunch)
        #expect(afterOlder.entries.last?.firstAt == older)
        #expect(afterOlder.entries.first?.firstAt == Date(timeIntervalSince1970: start + 2))
    }

    @Test("AC5 retention keeps exactly seven-day lastAt and drops older")
    func ac5_retentionKeepsExactlySevenDaysAndDropsOlder() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let exact = now.addingTimeInterval(-sevenDays)
        let older = now.addingTimeInterval(-(sevenDays + 1))
        let planted = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(code: .captureOn, firstAt: older, lastAt: older, repeatCount: 1),
                DiagnosticEvidenceEntry(code: .captureOff, firstAt: exact, lastAt: exact, repeatCount: 1)
            ]
        )
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.stored = try planted.encoded()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        guard case .available(let envelope) = await store.read() else {
            Issue.record("AC5 retention read should be available")
            return
        }
        #expect(envelope.entries.count == 1)
        #expect(envelope.entries[0].code == .captureOff)
        #expect(envelope.entries[0].lastAt == exact)
    }

    @Test("AC5 compaction write failure returns unavailable and does not change stored bytes")
    func ac5_compactionWriteFailureLeavesBytesIdentical() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let stale = now.addingTimeInterval(-(sevenDays + 1))
        let fresh = now.addingTimeInterval(-10)
        let planted = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(code: .captureOn, firstAt: stale, lastAt: stale, repeatCount: 1),
                DiagnosticEvidenceEntry(code: .captureOff, firstAt: fresh, lastAt: fresh, repeatCount: 1)
            ]
        )
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        let before = try planted.encoded()
        bytes.stored = before
        bytes.writeResult = .failed
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        #expect(await store.read() == .unavailable)
        #expect(bytes.stored == before)
        bytes.writeResult = .confirmed
        #expect(await store.read() == .unavailable)
        #expect(bytes.stored == before)
    }

    @Test("AC6 coalesce consecutive codes, saturate, and start a new run after retention")
    func ac6_coalesceSaturateAndNewRunAfterRetention() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let t0 = Date(timeIntervalSince1970: 999_000)
        #expect(await store.record(.captureOn, at: t0) == .recorded)
        #expect(await store.record(.captureOn, at: t0.addingTimeInterval(1)) == .recorded)
        #expect(await store.record(.captureOff, at: t0.addingTimeInterval(2)) == .recorded)
        #expect(await store.record(.captureOn, at: t0.addingTimeInterval(3)) == .recorded)

        guard case .available(let coalesced) = await store.read() else {
            Issue.record("AC6 coalesced read should be available")
            return
        }
        #expect(coalesced.entries.count == 3)
        #expect(coalesced.entries[0].code == .captureOn)
        #expect(coalesced.entries[0].repeatCount == 2)
        #expect(coalesced.entries[0].firstAt == t0)
        #expect(coalesced.entries[0].lastAt == t0.addingTimeInterval(1))
        #expect(coalesced.entries[1].code == .captureOff)
        #expect(coalesced.entries[1].repeatCount == 1)
        #expect(coalesced.entries[2].code == .captureOn)
        #expect(coalesced.entries[2].repeatCount == 1)

        let saturated = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(
                    code: .capturePaused,
                    firstAt: t0,
                    lastAt: t0,
                    repeatCount: 999
                )
            ]
        )
        let saturateBytes = InMemoryDiagnosticEvidenceBytesStore()
        saturateBytes.stored = try saturated.encoded()
        let saturateStore = DiagnosticEvidenceStore(bytesStore: saturateBytes, now: { clock.now })
        let later = t0.addingTimeInterval(25)
        #expect(await saturateStore.record(.capturePaused, at: later) == .recorded)
        guard case .available(let afterSaturate) = await saturateStore.read() else {
            Issue.record("AC6 saturate read should be available")
            return
        }
        #expect(afterSaturate.entries.count == 1)
        #expect(afterSaturate.entries[0].repeatCount == 999)
        #expect(afterSaturate.entries[0].firstAt == t0)
        #expect(afterSaturate.entries[0].lastAt == later)

        let staleTail = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(
                    code: .captureOn,
                    firstAt: now.addingTimeInterval(-(sevenDays + 50)),
                    lastAt: now.addingTimeInterval(-(sevenDays + 1)),
                    repeatCount: 4
                )
            ]
        )
        let staleBytes = InMemoryDiagnosticEvidenceBytesStore()
        staleBytes.stored = try staleTail.encoded()
        let staleStore = DiagnosticEvidenceStore(bytesStore: staleBytes, now: { clock.now })
        let freshTime = now.addingTimeInterval(-10)
        #expect(await staleStore.record(.captureOn, at: freshTime) == .recorded)
        guard case .available(let afterStale) = await staleStore.read() else {
            Issue.record("AC6 stale-tail read should be available")
            return
        }
        #expect(afterStale.entries.count == 1)
        #expect(afterStale.entries[0].code == .captureOn)
        #expect(afterStale.entries[0].repeatCount == 1)
        #expect(afterStale.entries[0].firstAt == freshTime)
        #expect(afterStale.entries[0].lastAt == freshTime)
    }

    @Test("AC7 record on corrupt bytes replaces with a one-event envelope")
    func ac7_recordOnCorruptBytesReplacesWithOneEventEnvelope() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.stored = Data("not-json".utf8)
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let time = Date(timeIntervalSince1970: 999_500)
        #expect(await store.record(.microphoneGranted, at: time) == .recorded)
        guard case .available(let envelope) = await store.read() else {
            Issue.record("AC7 read after corrupt replace should be available")
            return
        }
        #expect(envelope.entries.count == 1)
        #expect(envelope.entries[0].code == .microphoneGranted)
        #expect(envelope.entries[0].firstAt == time)
        #expect(envelope.entries[0].lastAt == time)
        #expect(envelope.entries[0].repeatCount == 1)
        let stored = try #require(bytes.stored)
        #expect(stored != Data("not-json".utf8))
        let decoded = try DiagnosticEvidenceEnvelope.decoded(from: stored, now: now)
        #expect(decoded == envelope)
    }

    @Test("AC8 record on unreadable store leaves bytes unchanged and stays unavailable")
    func ac8_recordOnUnreadableStoreLeavesBytesUnchanged() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let prior = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(
                    code: .captureOn,
                    firstAt: Date(timeIntervalSince1970: 999_000),
                    lastAt: Date(timeIntervalSince1970: 999_000),
                    repeatCount: 1
                )
            ]
        )
        let priorBytes = try prior.encoded()
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.stored = priorBytes
        bytes.readOverride = .failed
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        #expect(await store.record(.appLaunch, at: Date(timeIntervalSince1970: 999_500)) == .unavailable)
        #expect(bytes.stored == priorBytes)
        #expect(await store.read() == .unavailable)
    }

    @Test("AC9 write failure latches; a later confirmed record restores history without the failed event")
    func ac9_confirmedRecordAfterFailurePreservesEligibleHistory() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let older = [
            DiagnosticEvidenceEntry(
                code: .captureOn,
                firstAt: Date(timeIntervalSince1970: 999_100),
                lastAt: Date(timeIntervalSince1970: 999_100),
                repeatCount: 1
            ),
            DiagnosticEvidenceEntry(
                code: .capturePaused,
                firstAt: Date(timeIntervalSince1970: 999_200),
                lastAt: Date(timeIntervalSince1970: 999_200),
                repeatCount: 2
            ),
            DiagnosticEvidenceEntry(
                code: .captureOff,
                firstAt: Date(timeIntervalSince1970: 999_300),
                lastAt: Date(timeIntervalSince1970: 999_300),
                repeatCount: 1
            )
        ]
        let planted = DiagnosticEvidenceEnvelope(schemaVersion: 1, entries: older)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        let plantedBytes = try planted.encoded()
        bytes.stored = plantedBytes
        bytes.writeResult = .failed
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let failedAt = Date(timeIntervalSince1970: 999_400)
        #expect(await store.record(.appLaunch, at: failedAt) == .unavailable)
        #expect(bytes.stored == plantedBytes)

        bytes.writeResult = .confirmed
        let recoveredAt = Date(timeIntervalSince1970: 999_500)
        #expect(await store.record(.terminationCommitted, at: recoveredAt) == .recorded)
        guard case .available(let envelope) = await store.read() else {
            Issue.record("AC9 recovered read should be available")
            return
        }
        #expect(envelope.entries.count == 4)
        #expect(envelope.entries[0].code == .captureOn)
        #expect(envelope.entries[1].code == .capturePaused)
        #expect(envelope.entries[2].code == .captureOff)
        #expect(envelope.entries[3].code == .terminationCommitted)
        #expect(envelope.entries[3].firstAt == recoveredAt)
        #expect(!envelope.entries.contains { $0.code == .appLaunch })
    }

    @Test("AC9 read-back failure after write latches without rolling back")
    func ac9_readBackFailureAfterWriteLatchesWithoutRollback() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.failReadsAfterSuccessfulWrite = true
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let time = Date(timeIntervalSince1970: 999_000)
        #expect(await store.record(.captureOn, at: time) == .unavailable)
        let storedAfterWrite = try #require(bytes.stored)
        let decoded = try DiagnosticEvidenceEnvelope.decoded(from: storedAfterWrite, now: now)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].code == .captureOn)
        bytes.failReadsAfterSuccessfulWrite = false
        #expect(await store.read() == .unavailable)
        #expect(bytes.stored == storedAfterWrite)
    }

    @Test("AC10 concurrent distinct records preserve membership and a valid order")
    func ac10_concurrentDistinctRecordsPreserveMembershipAndValidOrder() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let time = Date(timeIntervalSince1970: 999_000)
        let codes = DiagnosticEvidenceCode.allCases
        await withTaskGroup(of: Void.self) { group in
            for code in codes {
                group.addTask {
                    _ = await store.record(code, at: time)
                }
            }
            group.addTask {
                _ = await store.read()
            }
        }

        guard case .available(let envelope) = await store.read() else {
            Issue.record("AC10 concurrent final read should be available")
            return
        }
        #expect(Set(envelope.entries.map(\.code)) == Set(codes))
        #expect(envelope.entries.count == codes.count)
        #expect(envelope.entries.allSatisfy { $0.repeatCount == 1 })
        let firstAts = envelope.entries.map(\.firstAt)
        #expect(firstAts == firstAts.sorted())
        for entry in envelope.entries {
            #expect(entry.firstAt <= entry.lastAt)
            #expect(entry.lastAt <= now)
        }
    }

    @Test("AC11 persisted envelope contains only schema keys and the 17 codes")
    func ac11_persistedEnvelopeContainsOnlySchemaKeysAndCodes() async throws {
        let keyToken = "sk-test-key"
        let filenameToken = "120000_audio_system.m4a"
        let deviceToken = "MacBook Pro Microphone"
        let unreachableMarkers = [
            "https://journal.example",
            "/Users/example/journal",
            "141500.failed",
            "Safari",
            "Inbox — Private Browsing",
            "SCShareableContent failed: denied"
        ]
        let leaf = "ac11-\(keyToken)_\(filenameToken)_\(deviceToken)_\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(leaf, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let store = DiagnosticEvidenceStore(
            applicationSupportBaseURL: directory,
            now: { clock.now }
        )
        for (index, code) in DiagnosticEvidenceCode.allCases.enumerated() {
            let time = Date(timeIntervalSince1970: 999_000 + Double(index))
            #expect(await store.record(code, at: time) == .recorded)
        }
        let fileURL = FileDiagnosticEvidenceBytesStore.fileURL(applicationSupportBaseURL: directory)
        let raw = try Data(contentsOf: fileURL)
        let utf8 = try #require(String(data: raw, encoding: .utf8))
        #expect(!utf8.contains(directory.path), "store path leaked into persisted bytes")
        for token in [keyToken, filenameToken, deviceToken] {
            #expect(directory.path.contains(token), "fixture path must embed \(token)")
            #expect(!utf8.contains(token), "embedded token leaked: \(token)")
        }
        for marker in unreachableMarkers {
            #expect(!utf8.contains(marker), "forbidden marker leaked: \(marker)")
        }
        try assertExactKeyAllowList(raw)
        let object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        let allowedCodes = Set(DiagnosticEvidenceCode.allCases.map(\.rawValue))
        #expect(entries.count == DiagnosticEvidenceCode.allCases.count)
        for entry in entries {
            let code = try #require(entry["code"] as? String)
            #expect(allowedCodes.contains(code))
            #expect(entry["firstAt"] is NSNumber)
            #expect(entry["lastAt"] is NSNumber)
            #expect(entry["repeatCount"] is NSNumber)
        }
    }

    private func assertExactKeyAllowList(_ data: Data) throws {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "entries"])
        let entries = try #require(object["entries"] as? [[String: Any]])
        for entry in entries {
            #expect(Set(entry.keys) == ["code", "firstAt", "lastAt", "repeatCount"])
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-diagnostic-evidence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
