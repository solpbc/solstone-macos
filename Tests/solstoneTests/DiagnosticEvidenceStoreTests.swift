// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
@testable import solstone

private let sevenDays: TimeInterval = 7 * 86_400

final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private enum DiagnosticEvidenceInjectedFailure: CaseIterable, Equatable {
    case encode
    case stage
    case stagedRead
    case stagedReadReturnsMismatchedBytes
    case rename
}

private enum DiagnosticEvidenceCanonicalStartingState: CaseIterable {
    case existingValid
    case absent
    case corrupt
    case expiredPlusEligible
}

private struct DiagnosticEvidenceFileFixture {
    let directory: URL
    let canonicalURL: URL
    let canonicalBytes: Data?
    let orphanURL: URL
    let orphanBytes: Data
}

private final class DecoratingDiagnosticEvidenceBytesStore: DiagnosticEvidenceBytesStoring, @unchecked Sendable {
    let base: FileDiagnosticEvidenceBytesStore
    var injectedFailure: DiagnosticEvidenceInjectedFailure?
    var encodedBytesOverride: Data?
    var mismatchedStagedBytes: Data?
    var stagedReadOverride: DiagnosticEvidenceBytesRead?
    var failIfCanonicalReadAfterCommit = false
    var failIfStagingRemoval = false
    private(set) var canonicalReadAfterCommitCount = 0
    private(set) var stagingRemovalCount = 0
    private(set) var unexpectedCanonicalReadAfterCommit = false
    private(set) var unexpectedStagingRemoval = false
    private(set) var didMakeCanonicalDirectoryReadOnly = false
    private(set) var stagedBytesByToken: [String: Data] = [:]
    private(set) var stagingTokens: [String] = []
    private var didCommit = false

    init(base: FileDiagnosticEvidenceBytesStore) {
        self.base = base
    }

    func readCanonical() -> DiagnosticEvidenceBytesRead {
        if didCommit, failIfCanonicalReadAfterCommit {
            canonicalReadAfterCommitCount += 1
            unexpectedCanonicalReadAfterCommit = true
            return .failed
        }
        return base.readCanonical()
    }

    func encode(_ envelope: DiagnosticEvidenceEnvelope) -> DiagnosticEvidenceEncodingResult {
        if injectedFailure == .some(.encode) {
            return .failed
        }
        if let encodedBytesOverride {
            return .encoded(encodedBytesOverride)
        }
        return base.encode(envelope)
    }

    func stage(_ data: Data) -> DiagnosticEvidenceStagingResult {
        if injectedFailure == .some(.stage) {
            return .failed
        }
        let result = base.stage(data)
        if case .staged(let staging) = result {
            stagedBytesByToken[staging.token] = data
            stagingTokens.append(staging.token)
        }
        return result
    }

    func readStaged(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceBytesRead {
        if let stagedReadOverride {
            return stagedReadOverride
        }
        switch injectedFailure {
        case .some(.stagedRead):
            return .failed
        case .some(.stagedReadReturnsMismatchedBytes):
            guard let mismatchedStagedBytes else {
                return .failed
            }
            return .bytes(mismatchedStagedBytes)
        case nil, .some(.encode), .some(.stage), .some(.rename):
            return base.readStaged(staging)
        }
    }

    func commit(_ staging: DiagnosticEvidenceStagingHandle) -> DiagnosticEvidenceCommitResult {
        if injectedFailure == .some(.rename) {
            if Darwin.chmod(base.fileURL.deletingLastPathComponent().path, 0o500) != 0 {
                return .failed
            }
            didMakeCanonicalDirectoryReadOnly = true
        }
        let result = base.commit(staging)
        if result == .committed {
            didCommit = true
        }
        return result
    }

    func removeStaging(_ staging: DiagnosticEvidenceStagingHandle) {
        stagingRemovalCount += 1
        if failIfStagingRemoval {
            unexpectedStagingRemoval = true
        }
        base.removeStaging(staging)
    }
}

@Suite("Diagnostic evidence store")
struct DiagnosticEvidenceStoreTests {
    @Test("maximally populated schema-1 envelope round-trips with order and key allow-list")
    func maximallyPopulatedEnvelopeRoundTrips() async throws {
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

    }

    @Test("lossy timestamps preserve the trusted staged bytes")
    func lossyTimestampsPreserveTrustedStagedBytes() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 809_271_856)
        let captured = DiagnosticEvidenceDateWitnesses.downward
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { now })
        let intended = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(code: .appLaunch, firstAt: captured, lastAt: captured, repeatCount: 1)
            ]
        )
        let trustedBytes = try intended.encoded()
        #expect(await store.record(.appLaunch, at: captured) == .recorded)
        let storedBytes = try #require(bytes.stored)
        let storedObject = try #require(
            (try? JSONSerialization.jsonObject(with: storedBytes)) as? [String: Any]
        )
        let normalizedStored = try #require(
            try? JSONSerialization.data(withJSONObject: storedObject, options: [.sortedKeys])
        )
        let trustedObject = try #require(
            (try? JSONSerialization.jsonObject(with: trustedBytes)) as? [String: Any]
        )
        let normalizedTrusted = try #require(
            try? JSONSerialization.data(withJSONObject: trustedObject, options: [.sortedKeys])
        )
        // Foundation's `JSONEncoder` does not guarantee key order across independent encodes, so key order — and only key order — is normalized on both sides.
        #expect(normalizedStored == normalizedTrusted)

        guard case .available(let envelope) = await store.read() else {
            Issue.record("lossy evidence should remain strictly readable")
            return
        }
        let entry = try #require(envelope.entries.first)
        #expect(entry.code == .appLaunch)
        #expect(entry.firstAt.timeIntervalSince1970 >= 0)
        #expect(entry.firstAt <= now)
        #expect(entry.firstAt != captured)
    }

    @Test("staged encoder output must remain strictly readable before commit")
    func stagedEncoderOutputMustRemainStrictlyReadableBeforeCommit() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFileFixture(starting: .existingValid, now: now)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let future = now.addingTimeInterval(1)
        let futureBytes = try DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(code: .appLaunch, firstAt: future, lastAt: future, repeatCount: 1)
            ]
        ).encoded()
        #expect((try? DiagnosticEvidenceEnvelope.decoded(from: futureBytes, now: now)) == nil)

        let decorated = DecoratingDiagnosticEvidenceBytesStore(
            base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
        )
        decorated.encodedBytesOverride = futureBytes
        let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })

        #expect(await store.record(.terminationCommitted, at: now.addingTimeInterval(-1)) == .unavailable)
        let token = try #require(decorated.stagingTokens.last)
        #expect(decorated.stagedBytesByToken[token] == futureBytes)
        #expect(decorated.stagingRemovalCount == 1)
        #expect(!FileManager.default.fileExists(atPath: token))
        #expect(decorated.canonicalReadAfterCommitCount == 0)
        #expect(!decorated.unexpectedCanonicalReadAfterCommit)
        #expect(!decorated.unexpectedStagingRemoval)
        try assertFixtureUnchanged(fixture)
    }

    @Test("file-backed recorder preserves lossy producer timestamps in order")
    @MainActor
    func fileBackedRecorderPreservesLossyProducerTimestampsInOrder() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 809_271_856)
        let witnesses: [(Date, TimeInterval)] = [
            (DiagnosticEvidenceDateWitnesses.downward, -1.1920928955078125e-07),
            (DiagnosticEvidenceDateWitnesses.exact, 0),
            (DiagnosticEvidenceDateWitnesses.upward, 1.1920928955078125e-07)
        ]
        for (timestamp, expectedDelta) in witnesses {
            let probe = DiagnosticEvidenceEnvelope(
                schemaVersion: 1,
                entries: [DiagnosticEvidenceEntry(code: .appLaunch, firstAt: timestamp, lastAt: timestamp, repeatCount: 1)]
            )
            let decoded = try DiagnosticEvidenceEnvelope.decoded(from: probe.encoded(), now: now)
            let delta = decoded.entries[0].firstAt.timeIntervalSinceReferenceDate - timestamp.timeIntervalSinceReferenceDate
            #expect(delta == expectedDelta)
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytesStore = FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: directory)
        let sequence = DiagnosticEvidenceDateSequence(witnesses.map(\.0))
        let store = DiagnosticEvidenceStore(bytesStore: bytesStore, now: { now })
        let recorder = DiagnosticEvidenceRecorder(store: store, now: { sequence.next() })

        recorder.enqueue(.appLaunch)
        recorder.enqueue(.terminationAppKitBegan)
        recorder.enqueue(.terminationCommitted)
        await recorder.drain()

        guard case .available(let envelope) = await store.read() else {
            Issue.record("file-backed lossy evidence should be available")
            return
        }
        #expect(envelope.entries.map(\.code) == [.appLaunch, .terminationAppKitBegan, .terminationCommitted])

        let canonicalURL = FileDiagnosticEvidenceBytesStore.fileURL(applicationSupportBaseURL: directory)
        let files = try FileManager.default.contentsOfDirectory(
            at: canonicalURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(FileManager.default.fileExists(atPath: canonicalURL.path))
        #expect(files.map(\.lastPathComponent) == [canonicalURL.lastPathComponent])
        #expect(!files.contains { $0.lastPathComponent.contains(".tmp") })
    }

    // The different-valid-envelope and staged-read-failed AC-3 shapes remain covered by `.stagedReadReturnsMismatchedBytes` and `.stagedRead` in the existing failure matrices.
    @Test("staged byte substitutes never commit")
    func stagedByteSubstitutesNeverCommit() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recordedAt = now.addingTimeInterval(-1)
        let intended = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(
                    code: .terminationCommitted,
                    firstAt: recordedAt,
                    lastAt: recordedAt,
                    repeatCount: 1
                )
            ]
        )
        let encoded = try intended.encoded()
        let encodedText = try #require(String(data: encoded, encoding: .utf8))

        let representationOnly = Data("\n\t".utf8) + encoded + Data("\r\n".utf8)
        #expect(representationOnly != encoded)
        #expect(try DiagnosticEvidenceEnvelope.decoded(from: representationOnly, now: now) == intended)

        let repeatToken = #""repeatCount":1"#
        let changedRepeatToken = #""repeatCount":2"#
        #expect(encodedText.components(separatedBy: repeatToken).count == 2)
        let oneByteChanged = Data(encodedText.replacingOccurrences(of: repeatToken, with: changedRepeatToken).utf8)
        #expect(oneByteChanged.count == encoded.count)
        #expect(zip(encoded, oneByteChanged).filter { $0 != $1 }.count == 1)
        #expect(try DiagnosticEvidenceEnvelope.decoded(from: oneByteChanged, now: now) != intended)

        let widenedKey = Data(encodedText.replacingOccurrences(
            of: #""schemaVersion":1"#,
            with: #""schemaVersion":1,"extra":true"#
        ).utf8)
        let widenedCode = Data(encodedText.replacingOccurrences(
            of: "termination.committed",
            with: "not.a.code"
        ).utf8)
        #expect(encodedText.components(separatedBy: "999999").count == 3)
        let futureTimestamp = Data(encodedText.replacingOccurrences(of: "999999", with: "1000001").utf8)

        let rows: [(name: String, substitute: DiagnosticEvidenceBytesRead, strictlyReadable: Bool?)] = [
            ("representation-only", .bytes(representationOnly), true),
            ("one-byte different envelope", .bytes(oneByteChanged), true),
            ("truncated", .bytes(Data(encoded.dropLast())), false),
            ("widened key", .bytes(widenedKey), false),
            ("widened code", .bytes(widenedCode), false),
            ("future timestamp", .bytes(futureTimestamp), false),
            ("absent", .absent, nil)
        ]

        for row in rows {
            do {
                if case .bytes(let data) = row.substitute,
                   let strictlyReadable = row.strictlyReadable {
                    #expect(((try? DiagnosticEvidenceEnvelope.decoded(from: data, now: now)) != nil) == strictlyReadable)
                }

                let fixture = try makeFileFixture(starting: .absent, now: now)
                defer { try? FileManager.default.removeItem(at: fixture.directory) }
                let decorated = DecoratingDiagnosticEvidenceBytesStore(
                    base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
                )
                decorated.stagedReadOverride = row.substitute
                let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })

                #expect(await store.record(.terminationCommitted, at: recordedAt) == .unavailable, "\(row.name)")
                let token = try #require(decorated.stagingTokens.last)
                #expect(decorated.stagingRemovalCount == 1, "\(row.name)")
                #expect(!FileManager.default.fileExists(atPath: token), "\(row.name)")
                #expect(decorated.canonicalReadAfterCommitCount == 0, "\(row.name)")
                #expect(!decorated.unexpectedCanonicalReadAfterCommit, "\(row.name)")
                #expect(!decorated.unexpectedStagingRemoval, "\(row.name)")
                try assertFixtureUnchanged(fixture)
            }
        }
    }

    @Test("rejection matrix leaves planted bytes identical")
    func rejectionMatrixLeavesBytesUnchanged() async throws {
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

    @Test("missing and empty are available; malformed and unreadable are unavailable")
    func fourWayMissingEmptyMalformedUnreadable() async throws {
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

    @Test("129 non-coalescing records preserve commit order and evict the first; an older 130th lands at the tail")
    func capPreservesCommitOrderAndEvictsOldest() async throws {
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
            Issue.record("read after 129 records should be available")
            return
        }
        #expect(afterCap.entries.count == 128)
        let firstAtsAfter129 = (1...128).map { Date(timeIntervalSince1970: start + Double($0)) }
        #expect(afterCap.entries.map(\.firstAt) == firstAtsAfter129)
        #expect(afterCap.entries.map(\.code) == (1...128).map { codes[$0 % codes.count] })

        let older = Date(timeIntervalSince1970: 998_000)
        #expect(await store.record(.appLaunch, at: older) == .recorded)
        guard case .available(let afterOlder) = await store.read() else {
            Issue.record("read after older record should be available")
            return
        }
        #expect(afterOlder.entries.count == 128)
        let firstAtsAfter130 = (2...128).map { Date(timeIntervalSince1970: start + Double($0)) } + [older]
        #expect(afterOlder.entries.map(\.firstAt) == firstAtsAfter130)
        #expect(afterOlder.entries.last?.code == .appLaunch)
        #expect(afterOlder.entries.last?.firstAt == older)
        #expect(afterOlder.entries.first?.firstAt == Date(timeIntervalSince1970: start + 2))
    }

    @Test("retention keeps exactly seven-day lastAt and drops older")
    func retentionKeepsExactlySevenDaysAndDropsOlder() async throws {
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
            Issue.record("retention read should be available")
            return
        }
        #expect(envelope.entries.count == 1)
        #expect(envelope.entries[0].code == .captureOff)
        #expect(envelope.entries[0].lastAt == exact)
        let persisted = try DiagnosticEvidenceEnvelope.decoded(
            from: try #require(bytes.stored),
            now: now
        )
        #expect(persisted == envelope)
        #expect(!persisted.entries.contains { $0.code == .captureOn })
    }

    @Test("record pre-commit failures preserve canonical bytes")
    func recordPrecommitFailuresPreserveCanonicalBytes() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let mismatchedStagedBytes = try DiagnosticEvidenceEnvelope(schemaVersion: 1, entries: []).encoded()

        for starting in DiagnosticEvidenceCanonicalStartingState.allCases {
            for failure in DiagnosticEvidenceInjectedFailure.allCases {
                do {
                    let fixture = try makeFileFixture(starting: starting, now: now)
                    defer { try? FileManager.default.removeItem(at: fixture.directory) }
                    let parent = fixture.canonicalURL.deletingLastPathComponent()
                    let needsPermissionRestore = failure == .rename
                    defer {
                        if needsPermissionRestore {
                            _ = Darwin.chmod(parent.path, 0o700)
                        }
                    }

                    let decorated = DecoratingDiagnosticEvidenceBytesStore(
                        base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
                    )
                    decorated.injectedFailure = failure
                    decorated.mismatchedStagedBytes = mismatchedStagedBytes
                    let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })

                    #expect(await store.record(.terminationCommitted, at: now.addingTimeInterval(-1)) == .unavailable)
                    #expect(await store.read() == .unavailable)
                    try assertFixtureUnchanged(fixture)

                    switch failure {
                    case .encode, .stage:
                        #expect(decorated.stagingTokens.isEmpty)
                        #expect(decorated.stagingRemovalCount == 0)
                    case .stagedRead, .stagedReadReturnsMismatchedBytes:
                        let token = try #require(decorated.stagingTokens.last)
                        #expect(decorated.stagingRemovalCount == 1)
                        #expect(!FileManager.default.fileExists(atPath: token))
                    case .rename:
                        let token = try #require(decorated.stagingTokens.last)
                        let expectedStagedBytes = try #require(decorated.stagedBytesByToken[token])
                        #expect(decorated.didMakeCanonicalDirectoryReadOnly)
                        #expect(decorated.stagingRemovalCount == 1)
                        #expect(try Data(contentsOf: URL(fileURLWithPath: token)) == expectedStagedBytes)
                    }
                }
            }
        }
    }

    @Test("every pre-commit failure recovers explicitly without resurrecting the failed event")
    func everyPrecommitFailureRecoversWithoutResurrection() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let mismatchedStagedBytes = try DiagnosticEvidenceEnvelope(schemaVersion: 1, entries: []).encoded()
        let failedCode = DiagnosticEvidenceCode.appLaunch
        let recoveredCode = DiagnosticEvidenceCode.terminationCommitted
        let recoveredAt = now.addingTimeInterval(-1)

        for starting in DiagnosticEvidenceCanonicalStartingState.allCases {
            for failure in DiagnosticEvidenceInjectedFailure.allCases {
                do {
                    let fixture = try makeFileFixture(starting: starting, now: now)
                    defer { try? FileManager.default.removeItem(at: fixture.directory) }
                    let parent = fixture.canonicalURL.deletingLastPathComponent()
                    defer { _ = Darwin.chmod(parent.path, 0o700) }

                    let decorated = DecoratingDiagnosticEvidenceBytesStore(
                        base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
                    )
                    decorated.injectedFailure = failure
                    decorated.mismatchedStagedBytes = mismatchedStagedBytes
                    let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })

                    #expect(await store.record(failedCode, at: now.addingTimeInterval(-5)) == .unavailable)
                    try assertFixtureUnchanged(fixture)

                    if failure == .rename {
                        #expect(Darwin.chmod(parent.path, 0o700) == 0)
                    }
                    decorated.injectedFailure = nil

                    #expect(await store.record(recoveredCode, at: recoveredAt) == .recorded)
                    guard case .available(let recovered) = await store.read() else {
                        Issue.record("recovery should be available for \(starting) after \(failure)")
                        continue
                    }

                    let expectedEntries: [DiagnosticEvidenceEntry]
                    switch starting {
                    case .existingValid:
                        expectedEntries = [
                            DiagnosticEvidenceEntry(
                                code: .captureOn,
                                firstAt: now.addingTimeInterval(-20),
                                lastAt: now.addingTimeInterval(-20),
                                repeatCount: 1
                            ),
                            DiagnosticEvidenceEntry(
                                code: recoveredCode,
                                firstAt: recoveredAt,
                                lastAt: recoveredAt,
                                repeatCount: 1
                            )
                        ]
                    case .absent, .corrupt:
                        expectedEntries = [
                            DiagnosticEvidenceEntry(
                                code: recoveredCode,
                                firstAt: recoveredAt,
                                lastAt: recoveredAt,
                                repeatCount: 1
                            )
                        ]
                    case .expiredPlusEligible:
                        expectedEntries = [
                            DiagnosticEvidenceEntry(
                                code: .captureOff,
                                firstAt: now.addingTimeInterval(-10),
                                lastAt: now.addingTimeInterval(-10),
                                repeatCount: 1
                            ),
                            DiagnosticEvidenceEntry(
                                code: recoveredCode,
                                firstAt: recoveredAt,
                                lastAt: recoveredAt,
                                repeatCount: 1
                            )
                        ]
                    }
                    #expect(recovered == DiagnosticEvidenceEnvelope(schemaVersion: 1, entries: expectedEntries))
                    #expect(!recovered.entries.contains { $0.code == failedCode })
                    try assertOrphanUnchanged(in: fixture)
                }
            }
        }
    }

    @Test("read-triggered compaction failures preserve canonical bytes")
    func readTriggeredCompactionFailuresPreserveCanonicalBytes() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let mismatchedStagedBytes = try DiagnosticEvidenceEnvelope(schemaVersion: 1, entries: []).encoded()

        for failure in DiagnosticEvidenceInjectedFailure.allCases {
            do {
                let fixture = try makeFileFixture(starting: .expiredPlusEligible, now: now)
                defer { try? FileManager.default.removeItem(at: fixture.directory) }
                let parent = fixture.canonicalURL.deletingLastPathComponent()
                let needsPermissionRestore = failure == .rename
                defer {
                    if needsPermissionRestore {
                        _ = Darwin.chmod(parent.path, 0o700)
                    }
                }

                let decorated = DecoratingDiagnosticEvidenceBytesStore(
                    base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
                )
                decorated.injectedFailure = failure
                decorated.mismatchedStagedBytes = mismatchedStagedBytes
                let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })

                #expect(await store.read() == .unavailable)
                try assertFixtureUnchanged(fixture)

                switch failure {
                case .encode, .stage:
                    #expect(decorated.stagingTokens.isEmpty)
                    #expect(decorated.stagingRemovalCount == 0)
                case .stagedRead, .stagedReadReturnsMismatchedBytes:
                    let token = try #require(decorated.stagingTokens.last)
                    #expect(decorated.stagingRemovalCount == 1)
                    #expect(!FileManager.default.fileExists(atPath: token))
                case .rename:
                    let token = try #require(decorated.stagingTokens.last)
                    let expectedStagedBytes = try #require(decorated.stagedBytesByToken[token])
                    #expect(decorated.didMakeCanonicalDirectoryReadOnly)
                    #expect(decorated.stagingRemovalCount == 1)
                    #expect(try Data(contentsOf: URL(fileURLWithPath: token)) == expectedStagedBytes)
                }
            }
        }
    }

    @Test("record commit creates canonical bytes without post-commit work")
    func recordCommitCreatesCanonicalBytesWithoutPostCommitWork() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFileFixture(starting: .absent, now: now)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let decorated = DecoratingDiagnosticEvidenceBytesStore(
            base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
        )
        decorated.failIfCanonicalReadAfterCommit = true
        decorated.failIfStagingRemoval = true
        let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })
        let recordedAt = now.addingTimeInterval(-1)
        let intended = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [DiagnosticEvidenceEntry(code: .captureOn, firstAt: recordedAt, lastAt: recordedAt, repeatCount: 1)]
        )

        #expect(await store.record(.captureOn, at: recordedAt) == .recorded)
        let persisted = try DiagnosticEvidenceEnvelope.decoded(from: Data(contentsOf: fixture.canonicalURL), now: now)
        #expect(persisted == intended)
        let token = try #require(decorated.stagingTokens.last)
        let stagedBytes = try #require(decorated.stagedBytesByToken[token])
        #expect(try Data(contentsOf: fixture.canonicalURL) == stagedBytes)
        #expect(!FileManager.default.fileExists(atPath: token))
        #expect(decorated.canonicalReadAfterCommitCount == 0)
        #expect(decorated.stagingRemovalCount == 0)
        #expect(!decorated.unexpectedCanonicalReadAfterCommit)
        #expect(!decorated.unexpectedStagingRemoval)
        try assertOrphanUnchanged(in: fixture)

        decorated.failIfCanonicalReadAfterCommit = false
        #expect(await store.read() == .available(intended))
    }

    @Test("read-triggered compaction replaces canonical bytes without post-commit work")
    func readTriggeredCompactionReplacesCanonicalBytesWithoutPostCommitWork() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFileFixture(starting: .expiredPlusEligible, now: now)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let decorated = DecoratingDiagnosticEvidenceBytesStore(
            base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
        )
        decorated.failIfCanonicalReadAfterCommit = true
        decorated.failIfStagingRemoval = true
        let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })
        let expected = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(
                    code: .captureOff,
                    firstAt: now.addingTimeInterval(-10),
                    lastAt: now.addingTimeInterval(-10),
                    repeatCount: 1
                )
            ]
        )

        #expect(await store.read() == .available(expected))
        let persisted = try DiagnosticEvidenceEnvelope.decoded(from: Data(contentsOf: fixture.canonicalURL), now: now)
        #expect(persisted == expected)
        let token = try #require(decorated.stagingTokens.last)
        let stagedBytes = try #require(decorated.stagedBytesByToken[token])
        #expect(try Data(contentsOf: fixture.canonicalURL) == stagedBytes)
        #expect(!FileManager.default.fileExists(atPath: token))
        #expect(decorated.canonicalReadAfterCommitCount == 0)
        #expect(decorated.stagingRemovalCount == 0)
        #expect(!decorated.unexpectedCanonicalReadAfterCommit)
        #expect(!decorated.unexpectedStagingRemoval)
        try assertOrphanUnchanged(in: fixture)

        decorated.failIfCanonicalReadAfterCommit = false
        #expect(await store.read() == .available(expected))
    }

    @Test("coalesce consecutive codes, saturate, and start a new run after retention")
    func coalesceSaturateAndNewRunAfterRetention() async throws {
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
            Issue.record("coalesced read should be available")
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
            Issue.record("saturate read should be available")
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
            Issue.record("stale-tail read should be available")
            return
        }
        #expect(afterStale.entries.count == 1)
        #expect(afterStale.entries[0].code == .captureOn)
        #expect(afterStale.entries[0].repeatCount == 1)
        #expect(afterStale.entries[0].firstAt == freshTime)
        #expect(afterStale.entries[0].lastAt == freshTime)
    }

    @Test("record on corrupt bytes replaces with a one-event envelope")
    func recordOnCorruptBytesReplacesWithOneEventEnvelope() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.stored = Data("not-json".utf8)
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let time = Date(timeIntervalSince1970: 999_500)
        #expect(await store.record(.microphoneGranted, at: time) == .recorded)
        guard case .available(let envelope) = await store.read() else {
            Issue.record("read after corrupt replace should be available")
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

    @Test("record on unreadable store leaves bytes unchanged and stays unavailable")
    func recordOnUnreadableStoreLeavesBytesUnchanged() async throws {
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

    @Test("later record after failed rename preserves eligible history without resurrection")
    func laterRecordAfterFailedRenamePreservesEligibleHistoryWithoutResurrection() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFileFixture(starting: .expiredPlusEligible, now: now)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parent = fixture.canonicalURL.deletingLastPathComponent()
        defer { _ = Darwin.chmod(parent.path, 0o700) }

        let decorated = DecoratingDiagnosticEvidenceBytesStore(
            base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
        )
        decorated.injectedFailure = .rename
        let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })

        #expect(await store.record(.appLaunch, at: now.addingTimeInterval(-5)) == .unavailable)
        #expect(decorated.didMakeCanonicalDirectoryReadOnly)
        try assertFixtureUnchanged(fixture)
        let failedStagingToken = try #require(decorated.stagingTokens.last)
        let failedStagedBytes = try #require(decorated.stagedBytesByToken[failedStagingToken])
        #expect(Darwin.chmod(parent.path, 0o700) == 0)
        #expect(FileManager.default.fileExists(atPath: failedStagingToken))
        #expect(try Data(contentsOf: URL(fileURLWithPath: failedStagingToken)) == failedStagedBytes)
        decorated.injectedFailure = nil

        let recoveredAt = now.addingTimeInterval(-1)
        #expect(await store.record(.terminationCommitted, at: recoveredAt) == .recorded)
        let expected = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(
                    code: .captureOff,
                    firstAt: now.addingTimeInterval(-10),
                    lastAt: now.addingTimeInterval(-10),
                    repeatCount: 1
                ),
                DiagnosticEvidenceEntry(
                    code: .terminationCommitted,
                    firstAt: recoveredAt,
                    lastAt: recoveredAt,
                    repeatCount: 1
                )
            ]
        )
        #expect(await store.read() == .available(expected))
        #expect(!expected.entries.contains { $0.code == .captureOn })
        #expect(!expected.entries.contains { $0.code == .appLaunch })
        try assertOrphanUnchanged(in: fixture)
        #expect(FileManager.default.fileExists(atPath: failedStagingToken))
        #expect(try Data(contentsOf: URL(fileURLWithPath: failedStagingToken)) == failedStagedBytes)
    }

    @Test("later record after failed rename replaces corrupt canonical without resurrection")
    func laterRecordAfterFailedRenameReplacesCorruptCanonicalWithoutResurrection() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fixture = try makeFileFixture(starting: .corrupt, now: now)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parent = fixture.canonicalURL.deletingLastPathComponent()
        defer { _ = Darwin.chmod(parent.path, 0o700) }

        let decorated = DecoratingDiagnosticEvidenceBytesStore(
            base: FileDiagnosticEvidenceBytesStore(applicationSupportBaseURL: fixture.directory)
        )
        decorated.injectedFailure = .rename
        let store = DiagnosticEvidenceStore(bytesStore: decorated, now: { now })

        #expect(await store.record(.appLaunch, at: now.addingTimeInterval(-5)) == .unavailable)
        #expect(decorated.didMakeCanonicalDirectoryReadOnly)
        try assertFixtureUnchanged(fixture)
        let failedStagingToken = try #require(decorated.stagingTokens.last)
        let failedStagedBytes = try #require(decorated.stagedBytesByToken[failedStagingToken])
        #expect(Darwin.chmod(parent.path, 0o700) == 0)
        #expect(FileManager.default.fileExists(atPath: failedStagingToken))
        #expect(try Data(contentsOf: URL(fileURLWithPath: failedStagingToken)) == failedStagedBytes)
        decorated.injectedFailure = nil

        let recoveredAt = now.addingTimeInterval(-1)
        #expect(await store.record(.terminationCommitted, at: recoveredAt) == .recorded)
        let expected = DiagnosticEvidenceEnvelope(
            schemaVersion: 1,
            entries: [
                DiagnosticEvidenceEntry(
                    code: .terminationCommitted,
                    firstAt: recoveredAt,
                    lastAt: recoveredAt,
                    repeatCount: 1
                )
            ]
        )
        #expect(await store.read() == .available(expected))
        try assertOrphanUnchanged(in: fixture)
        #expect(FileManager.default.fileExists(atPath: failedStagingToken))
        #expect(try Data(contentsOf: URL(fileURLWithPath: failedStagingToken)) == failedStagedBytes)
    }

    @Test("concurrent distinct records preserve membership and a valid order")
    func concurrentDistinctRecordsPreserveMembershipAndValidOrder() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clock = TestClock(now)
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let codes = DiagnosticEvidenceCode.allCases
        let injectedTimes = Dictionary(
            uniqueKeysWithValues: codes.enumerated().map { index, code in
                (code, Date(timeIntervalSince1970: 999_000 + Double(index)))
            }
        )
        await withTaskGroup(of: Void.self) { group in
            for code in codes {
                group.addTask {
                    _ = await store.record(code, at: injectedTimes[code]!)
                }
            }
            group.addTask {
                _ = await store.read()
            }
        }

        guard case .available(let envelope) = await store.read() else {
            Issue.record("concurrent final read should be available")
            return
        }
        #expect(Set(envelope.entries.map(\.code)) == Set(codes))
        #expect(envelope.entries.count == codes.count)
        #expect(envelope.entries.allSatisfy { $0.repeatCount == 1 })
        let firstAts = Set(envelope.entries.map(\.firstAt))
        #expect(firstAts == Set(injectedTimes.values))
        for entry in envelope.entries {
            #expect(entry.firstAt <= entry.lastAt)
            #expect(entry.lastAt <= now)
        }
    }

    @Test("persisted envelope contains only schema keys and the 17 codes")
    func persistedEnvelopeContainsOnlySchemaKeysAndCodes() async throws {
        let keyToken = "sk-test-key"
        let filenameToken = "120000_audio_system.m4a"
        let deviceToken = "MacBook Pro Microphone"
        // Path tokens are reachable through applicationSupportBaseURL; the rest document the covenant.
        let unreachableMarkers = [
            "https://journal.example",
            "/Users/example/journal",
            "141500.failed",
            "Safari",
            "Inbox — Private Browsing",
            "SCShareableContent failed: denied"
        ]
        let leaf = "diagnostic-evidence-\(keyToken)_\(filenameToken)_\(deviceToken)_\(UUID().uuidString)"
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

    private func makeFileFixture(
        starting state: DiagnosticEvidenceCanonicalStartingState,
        now: Date
    ) throws -> DiagnosticEvidenceFileFixture {
        let directory = try makeTemporaryDirectory()
        let canonicalURL = FileDiagnosticEvidenceBytesStore.fileURL(applicationSupportBaseURL: directory)
        let parent = canonicalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let orphanURL = parent.appendingPathComponent("unrelated-orphan-\(UUID().uuidString)")
        let orphanBytes = Data("unrelated orphan bytes".utf8)
        try orphanBytes.write(to: orphanURL)

        let canonicalBytes: Data?
        switch state {
        case .existingValid:
            canonicalBytes = try DiagnosticEvidenceEnvelope(
                schemaVersion: 1,
                entries: [
                    DiagnosticEvidenceEntry(
                        code: .captureOn,
                        firstAt: now.addingTimeInterval(-20),
                        lastAt: now.addingTimeInterval(-20),
                        repeatCount: 1
                    )
                ]
            ).encoded()
        case .absent:
            canonicalBytes = nil
        case .corrupt:
            canonicalBytes = Data("not-json".utf8)
        case .expiredPlusEligible:
            canonicalBytes = try DiagnosticEvidenceEnvelope(
                schemaVersion: 1,
                entries: [
                    DiagnosticEvidenceEntry(
                        code: .captureOn,
                        firstAt: now.addingTimeInterval(-(sevenDays + 1)),
                        lastAt: now.addingTimeInterval(-(sevenDays + 1)),
                        repeatCount: 1
                    ),
                    DiagnosticEvidenceEntry(
                        code: .captureOff,
                        firstAt: now.addingTimeInterval(-10),
                        lastAt: now.addingTimeInterval(-10),
                        repeatCount: 1
                    )
                ]
            ).encoded()
        }

        if let canonicalBytes {
            try canonicalBytes.write(to: canonicalURL)
        }

        return DiagnosticEvidenceFileFixture(
            directory: directory,
            canonicalURL: canonicalURL,
            canonicalBytes: canonicalBytes,
            orphanURL: orphanURL,
            orphanBytes: orphanBytes
        )
    }

    private func assertFixtureUnchanged(_ fixture: DiagnosticEvidenceFileFixture) throws {
        let actualCanonicalBytes: Data?
        if FileManager.default.fileExists(atPath: fixture.canonicalURL.path) {
            actualCanonicalBytes = try Data(contentsOf: fixture.canonicalURL)
        } else {
            actualCanonicalBytes = nil
        }
        #expect(actualCanonicalBytes == fixture.canonicalBytes)
        try assertOrphanUnchanged(in: fixture)
    }

    private func assertOrphanUnchanged(in fixture: DiagnosticEvidenceFileFixture) throws {
        #expect(try Data(contentsOf: fixture.orphanURL) == fixture.orphanBytes)
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
